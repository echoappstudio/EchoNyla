"""Check the macOS build stamp (LC_BUILD_VERSION) of a Mach-O program.

Usage: build-version.py <program> <expected minimum macOS> <expected SDK>
Prints minos and sdk for every architecture and fails unless all match.
"""
import struct
import sys

LC_BUILD_VERSION = 0x32
PLATFORM_MACOS = 1


def version_text(value):
    major, minor, patch = value >> 16, (value >> 8) & 0xFF, value & 0xFF
    return f"{major}.{minor}" + (f".{patch}" if patch else "")


def slices(data):
    magic = struct.unpack(">I", data[:4])[0]
    if magic == 0xCAFEBABE:  # universal binary
        count = struct.unpack(">I", data[4:8])[0]
        return [struct.unpack(">5I", data[8 + 20 * i:28 + 20 * i])[2] for i in range(count)]
    return [0]


def build_versions(data):
    found = []
    for offset in slices(data):
        magic = struct.unpack("<I", data[offset:offset + 4])[0]
        if magic != 0xFEEDFACF:
            raise SystemExit(f"error: not a 64-bit Mach-O slice at offset {offset}")
        ncmds = struct.unpack("<I", data[offset + 16:offset + 20])[0]
        cursor = offset + 32
        for _ in range(ncmds):
            cmd, size = struct.unpack("<II", data[cursor:cursor + 8])
            if cmd == LC_BUILD_VERSION:
                platform, minos, sdk = struct.unpack("<III", data[cursor + 8:cursor + 20])
                found.append((platform, version_text(minos), version_text(sdk)))
            cursor += size
    return found


def main():
    path, want_min, want_sdk = sys.argv[1:4]
    with open(path, "rb") as handle:
        found = build_versions(handle.read())
    if not found:
        raise SystemExit(f"error: {path} has no LC_BUILD_VERSION")
    for platform, minos, sdk in found:
        print(f"Build stamp: platform {platform}, minimum macOS {minos}, SDK {sdk}")
        if platform != PLATFORM_MACOS or minos != want_min or sdk != want_sdk:
            raise SystemExit(f"error: expected macOS minimum {want_min} and SDK {want_sdk}")


if __name__ == "__main__":
    main()
