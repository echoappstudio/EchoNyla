#!/usr/bin/env bash
# Updates an older EchoNyla to a newer one through Sparkle, using a test feed on this Mac:
#   1. with automatic checks turned off in EchoNyla's saved settings, it doesn't check;
#   2. an update whose signature doesn't match is downloaded but never installed;
#   3. a correctly signed update is installed and EchoNyla relaunches as the new version,
#      with its settings kept and (for a real signing identity) the same code identity.
# The two test copies are the packaged app with a test feed address, a throwaway signing key and
# their own version numbers, re-signed by the same script as the release. Needs OpenSSL 3.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_APP="$ROOT_DIR/dist/EchoNyla.app"
RELEASE_TOOL=(python3 -I "$ROOT_DIR/Scripts/release/sparkle_release.py")
DOMAIN="com.echoapps.echonyla"
PORT=8765
FEED_URL="http://127.0.0.1:$PORT/appcast.xml"
SIGN_MODE="${SIGN_MODE:-adhoc}"
export SIGN_MODE

test -d "$SOURCE_APP"
if [[ -z "${SPARKLE_OPENSSL:-}" ]]; then
    SPARKLE_OPENSSL="$(brew --prefix openssl@3 2>/dev/null)/bin/openssl"
fi
export SPARKLE_OPENSSL
"$SPARKLE_OPENSSL" version | grep -q '^OpenSSL 3'

WORK_DIR="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/echonyla-update.XXXXXX")"
FEED_DIR="$WORK_DIR/feed"
INSTALL_DIR="$WORK_DIR/Applications"
INSTALLED_APP="$INSTALL_DIR/EchoNyla.app"
SERVER_LOG="$WORK_DIR/server.log"
mkdir -p "$FEED_DIR" "$INSTALL_DIR" "$WORK_DIR/old" "$WORK_DIR/new"
SERVER_PID=""

cleanup() {
    status=$?
    trap - EXIT
    pkill -x EchoNyla >/dev/null 2>&1 || true
    if [[ -n "$SERVER_PID" ]]; then
        kill "$SERVER_PID" >/dev/null 2>&1 || true
    fi
    defaults delete "$DOMAIN" EchoNyla.updateTestMarker >/dev/null 2>&1 || true
    for key in skin.v1 finderIconShown.v1; do
        defaults delete "$DOMAIN" "EchoNyla.appearance.$key" >/dev/null 2>&1 || true
    done
    rm -rf "$WORK_DIR"
    exit "$status"
}
trap cleanup EXIT

# A throwaway key: the real one only ever reaches the Linux release job.
TEST_SPARKLE_KEY="$(head -c 32 /dev/urandom | base64)"
export TEST_SPARKLE_KEY
PUBLIC_KEY="$("${RELEASE_TOOL[@]}" public-key --seed-env TEST_SPARKLE_KEY)"

BASE_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SOURCE_APP/Contents/Info.plist")"
BASE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE_APP/Contents/Info.plist")"
OLD_BUILD="$BASE_BUILD"
NEW_BUILD="$((BASE_BUILD + 1))"
NEW_VERSION="$BASE_VERSION.1"

make_copy() {
    local destination="$1" build="$2" version="$3"
    local plist="$destination/Contents/Info.plist"
    ditto "$SOURCE_APP" "$destination"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build" "$plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$plist"
    /usr/libexec/PlistBuddy -c "Set :SUFeedURL $FEED_URL" "$plist"
    /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $PUBLIC_KEY" "$plist"
    # Only the test copies may fetch a feed over plain HTTP from this Mac.
    /usr/libexec/PlistBuddy -c 'Add :NSAppTransportSecurity dict' "$plist"
    /usr/libexec/PlistBuddy -c 'Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true' "$plist"
    bash "$ROOT_DIR/Scripts/sign-app.sh" "$destination"
}

make_copy "$WORK_DIR/old/EchoNyla.app" "$OLD_BUILD" "$BASE_VERSION"
make_copy "$WORK_DIR/new/EchoNyla.app" "$NEW_BUILD" "$NEW_VERSION"
OLD_REQUIREMENT="$(codesign --display --requirements - "$WORK_DIR/old/EchoNyla.app" 2>/dev/null | sed -n 's/^designated => //p')"
NEW_REQUIREMENT="$(codesign --display --requirements - "$WORK_DIR/new/EchoNyla.app" 2>/dev/null | sed -n 's/^designated => //p')"
test -n "$OLD_REQUIREMENT"

ARCHIVE="$FEED_DIR/EchoNyla-$NEW_VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$WORK_DIR/new/EchoNyla.app" "$ARCHIVE"
GOOD_SIGNATURE="$("${RELEASE_TOOL[@]}" sign --seed-env TEST_SPARKLE_KEY "$ARCHIVE")"
"${RELEASE_TOOL[@]}" verify --public-key "$PUBLIC_KEY" "$ARCHIVE" "$GOOD_SIGNATURE"
printf 'not the update' > "$WORK_DIR/other.bin"
WRONG_SIGNATURE="$("${RELEASE_TOOL[@]}" sign --seed-env TEST_SPARKLE_KEY "$WORK_DIR/other.bin")"

printf -- '- Test update.\n' > "$WORK_DIR/notes.md"
write_feed() {
    local signature="$1" output="$2"
    # The feed must say https; the test copies only reach it through 127.0.0.1.
    "${RELEASE_TOOL[@]}" feed --app-name "EchoNyla" --version "$NEW_VERSION" --build "$NEW_BUILD" \
        --url "https://placeholder.invalid/EchoNyla.zip" --archive "$ARCHIVE" --signature "$signature" \
        --minimum-system 26.0 --notes "$WORK_DIR/notes.md" --output "$output"
    sed -i '' "s|https://placeholder.invalid/EchoNyla.zip|http://127.0.0.1:$PORT/$(basename "$ARCHIVE")|" "$output"
    "${RELEASE_TOOL[@]}" sign-feed --seed-env TEST_SPARKLE_KEY "$output"
    "${RELEASE_TOOL[@]}" verify-feed --public-key "$PUBLIC_KEY" "$output"
}
write_feed "$GOOD_SIGNATURE" "$WORK_DIR/appcast-good.xml"
write_feed "$WRONG_SIGNATURE" "$WORK_DIR/appcast-wrong-signature.xml"

# Sparkle's own tool must agree with the release tool's signatures.
SIGN_UPDATE="$(find "$ROOT_DIR/.build/artifacts" -type f -path '*/bin/sign_update' | head -n 1)"
if [[ -x "$SIGN_UPDATE" ]]; then
    printf '%s' "$TEST_SPARKLE_KEY" | "$SIGN_UPDATE" --verify --ed-key-file - "$ARCHIVE" "$GOOD_SIGNATURE"
    printf '%s' "$TEST_SPARKLE_KEY" | "$SIGN_UPDATE" --verify --ed-key-file - "$WORK_DIR/appcast-good.xml"
    echo "Sparkle's sign_update accepts the archive and feed signatures."
else
    echo "Sparkle's sign_update wasn't found in .build/artifacts; the app's own check below still applies."
fi

python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$FEED_DIR" > "$SERVER_LOG" 2>&1 &
SERVER_PID=$!
for _ in {1..20}; do
    if curl -fsS -o /dev/null "http://127.0.0.1:$PORT/"; then break; fi
    sleep 0.5
done

installed_build() {
    /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INSTALLED_APP/Contents/Info.plist"
}

feed_requests() {
    grep -c 'GET /appcast.xml' "$SERVER_LOG" || true
}

archive_requests() {
    grep -c "GET /$(basename "$ARCHIVE")" "$SERVER_LOG" || true
}

launch_installed() {
    open -n -g "$INSTALLED_APP"
    for _ in {1..20}; do
        if pgrep -x EchoNyla >/dev/null 2>&1; then return 0; fi
        sleep 0.5
    done
    printf 'EchoNyla did not start.\n' >&2
    return 1
}

quit_app() {
    pkill -x EchoNyla >/dev/null 2>&1 || true
    for _ in {1..20}; do
        if ! pgrep -x EchoNyla >/dev/null 2>&1; then return 0; fi
        sleep 0.5
    done
    pkill -9 -x EchoNyla >/dev/null 2>&1 || true
}

ditto "$WORK_DIR/old/EchoNyla.app" "$INSTALLED_APP"
MARKER="kept-$(date +%s)"
defaults write "$DOMAIN" EchoNyla.updateTestMarker -string "$MARKER"
# One skin other than Signature, the app's own icon, so the installed copy wears the Sky icon in
# Finder throughout: the update must install over it, and the relaunched app must put it back.
defaults write "$DOMAIN" EchoNyla.appearance.skin.v1 -string sky
defaults write "$DOMAIN" SUAutomaticallyUpdate -bool true
# A check just happened as far as the hourly schedule knows, so only the launch check can find
# the update quickly.
defaults write "$DOMAIN" SULastCheckTime -date "$(date -u '+%Y-%m-%d %H:%M:%S +0000')"
defaults delete "$DOMAIN" SUSkippedVersion >/dev/null 2>&1 || true

echo "1. Automatic checks off: EchoNyla must not check."
cp "$WORK_DIR/appcast-good.xml" "$FEED_DIR/appcast.xml"
defaults write "$DOMAIN" SUEnableAutomaticChecks -bool false
launch_installed
sleep 20
quit_app
test "$(feed_requests)" -eq 0
test "$(installed_build)" = "$OLD_BUILD"
echo "   No check was made."

echo "2. An update with the wrong signature must not install."
cp "$WORK_DIR/appcast-wrong-signature.xml" "$FEED_DIR/appcast.xml"
defaults write "$DOMAIN" SUEnableAutomaticChecks -bool true
launch_installed
for _ in {1..60}; do
    if [[ "$(archive_requests)" -gt 0 ]]; then break; fi
    sleep 1
done
test "$(feed_requests)" -ge 1
test "$(archive_requests)" -ge 1
sleep 20
test "$(installed_build)" = "$OLD_BUILD"
quit_app
test "$(installed_build)" = "$OLD_BUILD"
echo "   The update was downloaded and refused."

# The earlier launches put the Sky icon on the installed copy.
if [[ ! -f "$INSTALLED_APP/Icon"$'\r' ]]; then
    echo "The installed copy should be wearing its skin icon in Finder by now." >&2
    exit 1
fi
echo "   The installed copy wears its skin icon in Finder."

echo "3. A signed update installs and EchoNyla relaunches."
cp "$WORK_DIR/appcast-good.xml" "$FEED_DIR/appcast.xml"
defaults write "$DOMAIN" SULastCheckTime -date "$(date -u '+%Y-%m-%d %H:%M:%S +0000')"
REQUESTS_BEFORE="$(feed_requests)"
launch_installed
OLD_PID="$(pgrep -x EchoNyla | head -n 1)"
NEW_PID=""
for _ in {1..180}; do
    if [[ "$(installed_build)" == "$NEW_BUILD" ]]; then
        NEW_PID="$(pgrep -x EchoNyla | grep -vx "$OLD_PID" | head -n 1 || true)"
        if [[ -n "$NEW_PID" ]]; then break; fi
    fi
    sleep 1
done
test "$(feed_requests)" -gt "$REQUESTS_BEFORE"
if [[ "$(installed_build)" != "$NEW_BUILD" ]]; then
    printf 'The update was not installed (installed build %s).\n' "$(installed_build)" >&2
    exit 1
fi
if [[ -z "$NEW_PID" ]]; then
    printf 'The update was installed but EchoNyla did not relaunch.\n' >&2
    exit 1
fi
RUNNING_PATH="$(ps -o comm= -p "$NEW_PID")"
if [[ "$(realpath "$RUNNING_PATH")" != "$(realpath "$INSTALLED_APP/Contents/MacOS/EchoNyla")" ]]; then
    printf 'The relaunched EchoNyla runs from %s, not the updated app.\n' "$RUNNING_PATH" >&2
    exit 1
fi
for _ in {1..20}; do
    if [[ -f "$INSTALLED_APP/Icon"$'\r' ]]; then break; fi
    sleep 0.5
done
if [[ ! -f "$INSTALLED_APP/Icon"$'\r' ]]; then
    echo "The updated app didn't put its skin icon back in Finder." >&2
    exit 1
fi
# The Finder icon sits outside what the signature covers, so check the update without it.
VERIFY_APP="$WORK_DIR/verify/EchoNyla.app"
mkdir -p "$WORK_DIR/verify"
ditto "$INSTALLED_APP" "$VERIFY_APP"
rm -f "$VERIFY_APP/Icon"$'\r'
xattr -c "$VERIFY_APP"
codesign --verify --deep --strict "$VERIFY_APP"
test "$(defaults read "$DOMAIN" EchoNyla.updateTestMarker)" = "$MARKER"
echo "   Installed build $NEW_BUILD, relaunched (process $NEW_PID), settings kept, skin icon back."

echo "Code identity (what macOS privacy permissions are tied to):"
echo "   old: $OLD_REQUIREMENT"
echo "   new: $NEW_REQUIREMENT"
if codesign --verify -R="$OLD_REQUIREMENT" "$VERIFY_APP" >/dev/null 2>&1; then
    IDENTITY_KEPT="yes"
else
    IDENTITY_KEPT="no"
fi
echo "   The updated app meets the old app's requirement: $IDENTITY_KEPT"
if [[ "$SIGN_MODE" != "adhoc" && "$IDENTITY_KEPT" != "yes" ]]; then
    printf 'A %s-signed update should keep the same code identity.\n' "$SIGN_MODE" >&2
    exit 1
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
        echo "### Sparkle update test ($SIGN_MODE signing)"
        echo "- Automatic checks off: no check made"
        echo "- Wrong signature: downloaded, refused"
        echo "- Signed update: build $OLD_BUILD → $NEW_BUILD installed over a copy wearing a skin icon, relaunched, settings kept, skin icon back"
        echo "- Old requirement: \`$OLD_REQUIREMENT\`"
        echo "- New requirement: \`$NEW_REQUIREMENT\`"
        echo "- Update meets the old app's requirement (permissions can carry over): **$IDENTITY_KEPT**"
    } >> "$GITHUB_STEP_SUMMARY"
fi
echo "Sparkle update test passed."
