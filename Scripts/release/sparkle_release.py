#!/usr/bin/env python3
"""Sparkle release helpers for EchoNyla's CI.

Signs update archives and the update feed (appcast) with Ed25519 through OpenSSL 3, writes the
feed, and refuses a feed that would go back to an older build. Private keys are read from an
environment variable, kept in a private temporary file only while OpenSSL runs, and never printed.
"""

import argparse
import base64
import email.utils
import html
import os
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

# DER headers that turn raw Ed25519 key bytes into the formats OpenSSL reads (RFC 8410).
PKCS8_PREFIX = bytes.fromhex("302e020100300506032b657004220420")
SPKI_PREFIX = bytes.fromhex("302a300506032b6570032100")

# Sparkle's signed-feed block, exactly as its sign_update tool writes it.
SIGNING_PREFIX = b"<!-- sparkle-signatures:\n"
SIGNING_SUFFIX = b"-->"
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"


class ReleaseError(Exception):
    pass


def openssl_path():
    return os.environ.get("SPARKLE_OPENSSL", "openssl")


def check_openssl():
    result = subprocess.run([openssl_path(), "version"], capture_output=True, text=True)
    if result.returncode != 0 or not result.stdout.startswith("OpenSSL 3"):
        raise ReleaseError("Ed25519 signing needs OpenSSL 3; set SPARKLE_OPENSSL to its path.")


def _run(args):
    result = subprocess.run(args, capture_output=True)
    if result.returncode != 0:
        # OpenSSL's messages never contain key material.
        raise ReleaseError("OpenSSL failed: " + result.stderr.decode(errors="replace").strip())
    return result.stdout


def _private_file(directory, name, data):
    path = os.path.join(directory, name)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as handle:
        handle.write(data)
    return path


def seed_from_env(name):
    value = os.environ.get(name, "").strip()
    if not value:
        raise ReleaseError(f"{name} is not set.")
    try:
        seed = base64.b64decode(value, validate=True)
    except ValueError:
        raise ReleaseError(f"{name} is not valid base64.") from None
    if len(seed) != 32:
        raise ReleaseError(f"{name} must be the base64 of a 32-byte Ed25519 seed.")
    return seed


def public_key(seed):
    check_openssl()
    with tempfile.TemporaryDirectory() as directory:
        key = _private_file(directory, "key.der", PKCS8_PREFIX + seed)
        spki = _run([openssl_path(), "pkey", "-inform", "DER", "-in", key, "-pubout", "-outform", "DER"])
    if len(spki) != len(SPKI_PREFIX) + 32 or not spki.startswith(SPKI_PREFIX):
        raise ReleaseError("Unexpected public key from OpenSSL.")
    return spki[len(SPKI_PREFIX):]


def sign(seed, data):
    if not data:
        raise ReleaseError("Nothing to sign.")
    check_openssl()
    with tempfile.TemporaryDirectory() as directory:
        key = _private_file(directory, "key.der", PKCS8_PREFIX + seed)
        message = _private_file(directory, "message", data)
        signature = _run([openssl_path(), "pkeyutl", "-sign", "-rawin", "-keyform", "DER", "-inkey", key, "-in", message])
    if len(signature) != 64:
        raise ReleaseError("Unexpected signature length from OpenSSL.")
    return signature


def verify(public, data, signature):
    check_openssl()
    if len(public) != 32 or len(signature) != 64:
        return False
    with tempfile.TemporaryDirectory() as directory:
        key = _private_file(directory, "public.der", SPKI_PREFIX + public)
        message = _private_file(directory, "message", data)
        sig = _private_file(directory, "signature", signature)
        result = subprocess.run(
            [openssl_path(), "pkeyutl", "-verify", "-rawin", "-pubin", "-keyform", "DER", "-inkey", key, "-in", message, "-sigfile", sig],
            capture_output=True,
        )
    return result.returncode == 0


def sign_feed(seed, content):
    if SIGNING_PREFIX in content:
        raise ReleaseError("The feed is already signed.")
    signature = base64.b64encode(sign(seed, content)).decode()
    block = f"<!-- sparkle-signatures:\nedSignature: {signature}\nlength: {len(content)}\n-->\n"
    return content + block.encode()


def extract_feed(data):
    """Splits a signed feed like Sparkle's SPUExtractAppcastContent: (content, signature, length)."""
    start = data.rfind(SIGNING_PREFIX)
    if start < 0:
        return data, None, None
    end = data.find(SIGNING_SUFFIX, start + len(SIGNING_PREFIX))
    if end < 0:
        return data, None, None
    signature, length = None, None
    for line in data[start + len(SIGNING_PREFIX):end].decode().splitlines():
        if line.startswith("edSignature:"):
            signature = line[len("edSignature:"):].strip()
        elif line.startswith("length:"):
            length = int(line[len("length:"):].strip())
    return data[:start], signature, length


def verify_feed(public, data):
    content, signature, length = extract_feed(data)
    if signature is None or length != len(content):
        return False
    try:
        raw = base64.b64decode(signature, validate=True)
    except ValueError:
        return False
    return verify(public, content, raw)


def feed_builds(data):
    content, _, _ = extract_feed(data)
    root = ET.fromstring(content)
    builds = []
    for item in root.iter("item"):
        value = item.findtext(f"{{{SPARKLE_NS}}}version")
        if value is None:
            enclosure = item.find("enclosure")
            value = None if enclosure is None else enclosure.get(f"{{{SPARKLE_NS}}}version")
        if value is None or not re.fullmatch(r"[0-9]+", value.strip()):
            raise ReleaseError(f"Feed item has no whole-number build: {value!r}")
        builds.append(int(value.strip()))
    if not builds:
        raise ReleaseError("The feed has no items.")
    return builds


def require_newer(build, current_feed):
    """A new feed must advertise a later build than the one already published."""
    if current_feed is None:
        return
    newest = max(feed_builds(current_feed))
    if build <= newest:
        raise ReleaseError(f"Build {build} is not newer than build {newest}, which the published feed already offers.")


def make_feed(app_name, version, build, url, length, signature, minimum_system, notes, pub_date=None):
    if not re.fullmatch(r"[0-9]+", str(build)):
        raise ReleaseError("The build must be a whole number.")
    if not url.startswith("https://"):
        raise ReleaseError("Downloads must use HTTPS.")
    if "]]>" in notes:
        raise ReleaseError("Release notes can't contain ']]>'.")
    pub_date = pub_date or email.utils.formatdate(usegmt=True)
    attr = lambda value: html.escape(str(value), quote=True)
    text = lambda value: html.escape(str(value), quote=False)
    feed = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="{SPARKLE_NS}">
  <channel>
    <title>{text(app_name)}</title>
    <item>
      <title>{text(app_name)} {text(version)}</title>
      <pubDate>{text(pub_date)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{text(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{text(minimum_system)}</sparkle:minimumSystemVersion>
      <description sparkle:format="markdown"><![CDATA[{notes.strip()}
]]></description>
      <enclosure url="{attr(url)}" length="{int(length)}" type="application/octet-stream" sparkle:edSignature="{attr(signature)}"/>
    </item>
  </channel>
</rss>
"""
    ET.fromstring(feed)
    return feed.encode()


def _read(path):
    with open(path, "rb") as handle:
        return handle.read()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    command = commands.add_parser("public-key", help="Print the base64 public key for a private seed.")
    command.add_argument("--seed-env", required=True)

    command = commands.add_parser("sign", help="Print the base64 Ed25519 signature of a file.")
    command.add_argument("--seed-env", required=True)
    command.add_argument("file")

    command = commands.add_parser("verify", help="Check a file's base64 signature.")
    command.add_argument("--public-key", required=True)
    command.add_argument("file")
    command.add_argument("signature")

    command = commands.add_parser("feed", help="Write an unsigned feed for one update.")
    for name in ("--app-name", "--version", "--build", "--url", "--archive", "--signature", "--minimum-system", "--notes", "--output"):
        command.add_argument(name, required=True)

    command = commands.add_parser("sign-feed", help="Sign a feed in place, as Sparkle's sign_update does.")
    command.add_argument("--seed-env", required=True)
    command.add_argument("file")

    command = commands.add_parser("verify-feed", help="Check a signed feed.")
    command.add_argument("--public-key", required=True)
    command.add_argument("file")

    command = commands.add_parser("feed-build", help="Print the newest build a feed offers.")
    command.add_argument("file")

    command = commands.add_parser("require-newer", help="Fail unless a build is newer than a published feed's.")
    command.add_argument("--build", required=True, type=int)
    command.add_argument("--current-feed", help="The published feed; leave out when there is none yet.")

    args = parser.parse_args(argv)
    try:
        if args.command == "public-key":
            print(base64.b64encode(public_key(seed_from_env(args.seed_env))).decode())
        elif args.command == "sign":
            print(base64.b64encode(sign(seed_from_env(args.seed_env), _read(args.file))).decode())
        elif args.command == "verify":
            public = base64.b64decode(args.public_key, validate=True)
            signature = base64.b64decode(args.signature, validate=True)
            if not verify(public, _read(args.file), signature):
                raise ReleaseError(f"The signature of {args.file} doesn't match.")
            print(f"Signature of {args.file} verified.")
        elif args.command == "feed":
            notes = _read(args.notes).decode()
            feed = make_feed(args.app_name, args.version, args.build, args.url, os.path.getsize(args.archive),
                             args.signature, args.minimum_system, notes)
            with open(args.output, "wb") as handle:
                handle.write(feed)
        elif args.command == "sign-feed":
            signed = sign_feed(seed_from_env(args.seed_env), _read(args.file))
            with open(args.file, "wb") as handle:
                handle.write(signed)
        elif args.command == "verify-feed":
            if not verify_feed(base64.b64decode(args.public_key, validate=True), _read(args.file)):
                raise ReleaseError(f"The feed {args.file} isn't signed with this key.")
            print(f"Feed {args.file} verified.")
        elif args.command == "feed-build":
            print(max(feed_builds(_read(args.file))))
        elif args.command == "require-newer":
            require_newer(args.build, _read(args.current_feed) if args.current_feed else None)
            print(f"Build {args.build} is newer than the published feed.")
    except ReleaseError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
