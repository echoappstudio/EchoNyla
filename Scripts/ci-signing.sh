#!/usr/bin/env bash
# Sets up the code-signing identity for a CI build, or removes it again ("cleanup").
#
# Developer ID wins when its secrets are present; then the persistent self-signed certificate;
# otherwise the build is ad-hoc signed. The certificate goes into a temporary keychain that only
# this job uses. Writes SIGN_MODE, SIGN_IDENTITY, SIGN_KEYCHAIN (and the notary key path) to
# $GITHUB_ENV. Never prints a secret.
#
# Secrets read from the environment:
#   DEVELOPER_ID_P12_BASE64, DEVELOPER_ID_P12_PASSWORD     (later, with Apple's program)
#   NOTARY_API_KEY_P8_BASE64, NOTARY_API_KEY_ID, NOTARY_API_ISSUER_ID
#   SELF_SIGN_P12_BASE64, SELF_SIGN_P12_PASSWORD           (the self-signed trial)
set -euo pipefail

KEYCHAIN="${RUNNER_TEMP:?}/echonyla-signing.keychain-db"
SECRETS_DIR="$RUNNER_TEMP/echonyla-signing-secrets"

if [[ "${1:-}" == "cleanup" ]]; then
    security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
    rm -rf "$SECRETS_DIR"
    exit 0
fi

write_env() {
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_ENV"
}

if [[ -n "${DEVELOPER_ID_P12_BASE64:-}" ]]; then
    MODE="developer-id"
    P12_BASE64="$DEVELOPER_ID_P12_BASE64"
    P12_PASSWORD="${DEVELOPER_ID_P12_PASSWORD:?DEVELOPER_ID_P12_PASSWORD is missing}"
elif [[ -n "${SELF_SIGN_P12_BASE64:-}" ]]; then
    MODE="self-signed"
    P12_BASE64="$SELF_SIGN_P12_BASE64"
    P12_PASSWORD="${SELF_SIGN_P12_PASSWORD:?SELF_SIGN_P12_PASSWORD is missing}"
else
    echo "No signing certificate in this repository's secrets; this build is ad-hoc signed."
    write_env SIGN_MODE adhoc
    exit 0
fi

mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"
P12_PATH="$SECRETS_DIR/identity.p12"
printf '%s' "$P12_BASE64" | base64 --decode > "$P12_PATH"
chmod 600 "$P12_PATH"

KEYCHAIN_PASSWORD="$(head -c 24 /dev/urandom | base64)"
echo "::add-mask::$KEYCHAIN_PASSWORD"
security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$P12_PATH" -k "$KEYCHAIN" -P "$P12_PASSWORD" -f pkcs12 -T /usr/bin/codesign >/dev/null
rm -f "$P12_PATH"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
# codesign finds the certificate's chain through the search list.
existing=()
while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%\"}"
    line="${line#\"}"
    [[ -n "$line" ]] && existing+=("$line")
done < <(security list-keychains -d user)
security list-keychains -d user -s "$KEYCHAIN" "${existing[@]}"

# Without -v so a self-signed certificate (valid for signing, not trusted by macOS) is listed too.
IDENTITY="$(security find-identity -p codesigning "$KEYCHAIN" | sed -nE 's/^ *1\) ([0-9A-F]{40}) .*/\1/p' | sed -n 1p)"
if [[ -z "$IDENTITY" ]]; then
    echo "The certificate in the secrets has no code-signing identity." >&2
    exit 1
fi
NAME="$(security find-identity -p codesigning "$KEYCHAIN" | sed -nE 's/^ *1\) [0-9A-F]{40} "([^"]*)".*/\1/p' | sed -n 1p)"
[[ -n "$NAME" ]] && echo "::add-mask::$NAME"
if [[ "$MODE" == "developer-id" && "$NAME" != "Developer ID Application:"* ]]; then
    echo "The Developer ID secret does not hold a Developer ID Application certificate." >&2
    exit 1
fi
echo "Signing ($MODE), certificate SHA-1 $IDENTITY."

write_env SIGN_MODE "$MODE"
write_env SIGN_IDENTITY "$IDENTITY"
write_env SIGN_KEYCHAIN "$KEYCHAIN"

if [[ "$MODE" == "developer-id" ]]; then
    for name in NOTARY_API_KEY_P8_BASE64 NOTARY_API_KEY_ID NOTARY_API_ISSUER_ID; do
        if [[ -z "${!name:-}" ]]; then
            echo "Developer ID builds must be notarized, but the $name secret is missing." >&2
            exit 1
        fi
    done
    NOTARY_KEY_PATH="$SECRETS_DIR/notary-key.p8"
    printf '%s' "$NOTARY_API_KEY_P8_BASE64" | base64 --decode > "$NOTARY_KEY_PATH"
    chmod 600 "$NOTARY_KEY_PATH"
    write_env NOTARY_KEY_PATH "$NOTARY_KEY_PATH"
    write_env NOTARY_KEY_ID "$NOTARY_API_KEY_ID"
    write_env NOTARY_ISSUER_ID "$NOTARY_API_ISSUER_ID"
fi
