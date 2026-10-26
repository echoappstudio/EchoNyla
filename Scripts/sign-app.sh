#!/usr/bin/env bash
# Signs EchoNyla.app from the inside out: Sparkle's helpers, then Sparkle, then the app itself.
# SIGN_MODE is adhoc (the default), self-signed or developer-id; SIGN_IDENTITY is the
# certificate's SHA-1 for the last two. Developer ID adds the hardened runtime and a timestamp,
# which notarization needs.
set -euo pipefail

APP="${1:?usage: sign-app.sh <path to EchoNyla.app>}"
MODE="${SIGN_MODE:-adhoc}"
IDENTITY="${SIGN_IDENTITY:--}"

args=(--force --sign "$IDENTITY")
case "$MODE" in
    adhoc)
        if [[ "$IDENTITY" != "-" ]]; then
            printf 'Ad-hoc signing takes no identity.\n' >&2
            exit 1
        fi
        ;;
    self-signed)
        args+=(--timestamp=none)
        ;;
    developer-id)
        args+=(--options runtime --timestamp)
        ;;
    *)
        printf 'Unknown SIGN_MODE: %s\n' "$MODE" >&2
        exit 1
        ;;
esac
if [[ "$MODE" != "adhoc" && "$IDENTITY" == "-" ]]; then
    printf 'SIGN_MODE=%s needs SIGN_IDENTITY.\n' "$MODE" >&2
    exit 1
fi
if [[ -n "${SIGN_KEYCHAIN:-}" ]]; then
    args+=(--keychain "$SIGN_KEYCHAIN")
fi

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
SPARKLE_VERSION_DIR="$SPARKLE/Versions/B"
for part in \
    "$SPARKLE_VERSION_DIR/XPCServices/Installer.xpc" \
    "$SPARKLE_VERSION_DIR/XPCServices/Downloader.xpc" \
    "$SPARKLE_VERSION_DIR/Autoupdate" \
    "$SPARKLE_VERSION_DIR/Updater.app"; do
    test -e "$part"
done

codesign "${args[@]}" "$SPARKLE_VERSION_DIR/XPCServices/Installer.xpc"
# The downloader service keeps the entitlements Sparkle built it with.
codesign "${args[@]}" --preserve-metadata=entitlements "$SPARKLE_VERSION_DIR/XPCServices/Downloader.xpc"
codesign "${args[@]}" "$SPARKLE_VERSION_DIR/Autoupdate"
codesign "${args[@]}" "$SPARKLE_VERSION_DIR/Updater.app"
codesign "${args[@]}" "$SPARKLE"
codesign "${args[@]}" "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
printf 'Signed %s (%s)\n' "$APP" "$MODE"
codesign --display --requirements - "$APP" 2>/dev/null | sed -n 's/^designated => /Designated requirement: /p'
