#!/usr/bin/env bash
# Sends a Developer ID-signed EchoNyla.app to Apple's notary service and staples the ticket.
# Any answer but "Accepted" stops the build, so nothing unnotarized is published this way.
# Needs NOTARY_KEY_PATH (an App Store Connect API key, .p8), NOTARY_KEY_ID and NOTARY_ISSUER_ID.
set -euo pipefail

APP="${1:?usage: notarize.sh <path to EchoNyla.app>}"
for name in NOTARY_KEY_PATH NOTARY_KEY_ID NOTARY_ISSUER_ID; do
    if [[ -z "${!name:-}" ]]; then
        printf 'Developer ID builds must be notarized, but %s is not set.\n' "$name" >&2
        exit 1
    fi
done
test -s "$NOTARY_KEY_PATH"

WORK_DIR="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/echonyla-notarize.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
SUBMISSION="$WORK_DIR/$(basename "$APP" .app)-notarize.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$SUBMISSION"

xcrun notarytool submit "$SUBMISSION" \
    --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" \
    --wait --timeout 3h --output-format plist > "$WORK_DIR/result.plist"
STATUS="$(/usr/libexec/PlistBuddy -c 'Print :status' "$WORK_DIR/result.plist")"
SUBMISSION_ID="$(/usr/libexec/PlistBuddy -c 'Print :id' "$WORK_DIR/result.plist")"
printf 'Notarization %s: %s\n' "$SUBMISSION_ID" "$STATUS"
if [[ "$STATUS" != "Accepted" ]]; then
    xcrun notarytool log "$SUBMISSION_ID" \
        --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" || true
    exit 1
fi

xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
