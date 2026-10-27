#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

APP="dist/EchoNyla.app"
ICONSET="dist/AppIcon.iconset"
ICON_OUT="dist/AppIcon-compiled"
VERIFY_DIR="dist/verify-extracted"
ZIP="dist/EchoNyla-3.0.1.zip"
SIGNING_REPORT="dist/signing.txt"
SIGN_MODE="${SIGN_MODE:-adhoc}"
export SIGN_MODE

swift build -c release --product EchoNyla
rm -rf "$APP" "$ICONSET" "$ICON_OUT" "$VERIFY_DIR" "$ZIP" "$ZIP.sha256" "$SIGNING_REPORT" "dist/notarize"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks" dist
cp .build/release/EchoNyla "$APP/Contents/MacOS/EchoNyla"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Acknowledgements.txt "$APP/Contents/Resources/Acknowledgements.txt"
# The Apple Intelligence mark's loops, drawn in the skin's colours in the sidebar card.
cp Resources/IntelligenceLoops.png "$APP/Contents/Resources/IntelligenceLoops.png"
# The file-type icons (vscode-icons, CC BY-SA 4.0; see Resources/FileTypes/LICENSE.txt).
ditto Resources/FileTypes "$APP/Contents/Resources/FileTypes"
file_types="$(ls "$APP/Contents/Resources/FileTypes" | grep -c '\.png$' || true)"
if [ "$file_types" -lt 60 ]; then
    echo "error: expected at least 60 file-type icons in the app, found $file_types" >&2
    exit 1
fi
# One Dock icon per skin; the app swaps to the one for the skin in use.
mkdir -p "$APP/Contents/Resources/SkinIcons"
cp Resources/SkinIcons/icon-*.png "$APP/Contents/Resources/SkinIcons/"
skin_icons="$(ls "$APP/Contents/Resources/SkinIcons" | wc -l | tr -d ' ')"
if [ "$skin_icons" != "5" ]; then
    echo "error: expected 5 skin icons (every skin but Signature), found $skin_icons" >&2
    exit 1
fi

# Sparkle comes from the exact version SwiftPM resolved and checksummed.
SPARKLE_FRAMEWORKS=()
while IFS= read -r framework; do
    SPARKLE_FRAMEWORKS+=("$framework")
done < <(find .build/artifacts -type d -path '*/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework' -prune)
if [[ "${#SPARKLE_FRAMEWORKS[@]}" -ne 1 ]]; then
    printf 'Expected one Sparkle.framework in .build/artifacts, found %s.\n' "${#SPARKLE_FRAMEWORKS[@]}" >&2
    exit 1
fi
ditto "${SPARKLE_FRAMEWORKS[0]}" "$APP/Contents/Frameworks/Sparkle.framework"
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Frameworks/Sparkle.framework/Resources/Info.plist" | grep -Fx '2.10.0'
test -x "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
test -x "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater"
otool -L "$APP/Contents/MacOS/EchoNyla" | grep -F '@rpath/Sparkle.framework/Versions/B/Sparkle'
otool -l "$APP/Contents/MacOS/EchoNyla" | grep -F 'path @executable_path/../Frameworks'
grep -F 'Sparkle 2.10.0' "$APP/Contents/Resources/Acknowledgements.txt"

# The on-device model's engine (llama.cpp), from the exact release SwiftPM resolved and checksummed.
# Only the Apple Silicon half is kept; EchoNyla runs on Apple Silicon only.
LLAMA_FRAMEWORKS=()
while IFS= read -r framework; do
    LLAMA_FRAMEWORKS+=("$framework")
done < <(find .build/artifacts -type d -path '*/llama.xcframework/macos-arm64_x86_64/llama.framework' -prune)
if [[ "${#LLAMA_FRAMEWORKS[@]}" -ne 1 ]]; then
    printf 'Expected one llama.framework in .build/artifacts, found %s.\n' "${#LLAMA_FRAMEWORKS[@]}" >&2
    exit 1
fi
ditto --arch arm64 "${LLAMA_FRAMEWORKS[0]}" "$APP/Contents/Frameworks/llama.framework"
test -s "$APP/Contents/Frameworks/llama.framework/Versions/A/llama"
otool -L "$APP/Contents/MacOS/EchoNyla" | grep -F '@rpath/llama.framework/Versions/A/llama'
grep -F 'llama.cpp b11800' "$APP/Contents/Resources/Acknowledgements.txt"

swift Scripts/GenerateIcon.swift "$ICONSET" "Resources/AppIcon-1024.png"
iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" "$ICONSET"
cp Resources/AppIcon-1024.png "$APP/Contents/Resources/AppIcon-1024.png"
python3 Scripts/test_icon_package.py "$ROOT_DIR/Resources/AppIcon-1024.png" "$ROOT_DIR/$APP"

# The macOS 26+ icon: compile the Icon Composer file (Resources/AppIcon.icon) into Assets.car.
# Without it, newer macOS versions show the classic .icns shrunk onto a grey plate in the Dock.
# actool can exit 0 even when it skips the icon, so the output is checked, not the exit code.
mkdir -p "$ICON_OUT"
xcrun actool Resources/AppIcon.icon \
    --compile "$ICON_OUT" \
    --platform macosx \
    --target-device mac \
    --minimum-deployment-target 26.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$ICON_OUT/partial.plist" \
    --output-format human-readable-text \
    --errors --warnings --notices || { echo "error: actool couldn't compile Resources/AppIcon.icon" >&2; exit 1; }
ls -l "$ICON_OUT"
if [ ! -s "$ICON_OUT/Assets.car" ]; then
    echo "error: actool didn't produce Assets.car from Resources/AppIcon.icon" >&2
    exit 1
fi
icon_name="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIconName" "$ICON_OUT/partial.plist" 2>/dev/null || true)"
echo "actool partial Info.plist CFBundleIconName: ${icon_name:-<none>}"
if [ "$icon_name" != "AppIcon" ]; then
    car_info="$(xcrun assetutil --info "$ICON_OUT/Assets.car" 2>&1 || true)"
    case "$car_info" in
        *'"AppIcon"'*) echo "Assets.car lists AppIcon." ;;
        *) printf '%s\n' "$car_info" >&2; echo "error: Assets.car doesn't contain an app icon named AppIcon" >&2; exit 1 ;;
    esac
fi
# Only Assets.car is copied; the classic AppIcon.icns above stays as the fallback.
cp "$ICON_OUT/Assets.car" "$APP/Contents/Resources/Assets.car"
chmod 755 "$APP/Contents/MacOS/EchoNyla"

# Each check names the key that doesn't match, so a failure is never silent.
expect_plist() {
    local actual
    actual="$(/usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist")"
    if [ "$actual" != "$2" ]; then
        echo "error: Info.plist $1 is '$actual', expected '$2'" >&2
        exit 1
    fi
}

plutil -lint "$APP/Contents/Info.plist"
expect_plist LSUIElement true
expect_plist LSMinimumSystemVersion 26.0
expect_plist CFBundleShortVersionString 3.0.1
expect_plist CFBundleVersion 17
expect_plist CFBundleIconFile AppIcon
expect_plist CFBundleIconName AppIcon
expect_plist SUFeedURL "https://github.com/echoappstudio/EchoNyla/releases/latest/download/appcast.xml"
test -s "$APP/Contents/Resources/AppIcon.icns"
test -s "$APP/Contents/Resources/Assets.car"
test -s "$APP/Contents/Resources/SkinIcons/icon-sky.png"
test -s "$APP/Contents/Resources/IntelligenceLoops.png"
test -s "$APP/Contents/Resources/FileTypes/word.png"
test -s "$APP/Contents/Resources/FileTypes/LICENSE.txt"

# Signing is the last change to the app; everything after only zips, checks and hashes it.
bash Scripts/sign-app.sh "$APP"

NOTARIZED="no"
if [[ "$SIGN_MODE" == "developer-id" ]]; then
    bash Scripts/notarize.sh "$APP"
    NOTARIZED="yes"
fi

# Verify the exact ZIP intended for download, including executable mode.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
mkdir -p "$VERIFY_DIR"
ditto -x -k "$ZIP" "$VERIFY_DIR"
EXTRACTED_APP="$VERIFY_DIR/EchoNyla.app"
test -x "$EXTRACTED_APP/Contents/MacOS/EchoNyla"
python3 Scripts/test_icon_package.py "$ROOT_DIR/Resources/AppIcon-1024.png" "$ROOT_DIR/$EXTRACTED_APP"
if [ ! -s "$EXTRACTED_APP/Contents/Resources/Assets.car" ]; then
    echo "error: Assets.car (the macOS 26+ icon) is missing inside the ZIP" >&2
    exit 1
fi
test -s "$EXTRACTED_APP/Contents/Resources/SkinIcons/icon-wisteria.png"
test -s "$EXTRACTED_APP/Contents/Resources/IntelligenceLoops.png"
test -s "$EXTRACTED_APP/Contents/Resources/FileTypes/pdf.png"
test -x "$EXTRACTED_APP/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
test -s "$EXTRACTED_APP/Contents/Frameworks/llama.framework/Versions/A/llama"
test -L "$EXTRACTED_APP/Contents/Frameworks/llama.framework/Versions/Current"
test -L "$EXTRACTED_APP/Contents/Frameworks/Sparkle.framework/Versions/Current"
expect_plist_in() {
    local actual
    actual="$(/usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist")"
    if [ "$actual" != "$3" ]; then
        echo "error: Info.plist $2 inside the ZIP is '$actual', expected '$3'" >&2
        exit 1
    fi
}
expect_plist_in "$EXTRACTED_APP" CFBundleShortVersionString 3.0.1
expect_plist_in "$EXTRACTED_APP" CFBundleVersion 17
expect_plist_in "$EXTRACTED_APP" CFBundleIconName AppIcon
expect_plist_in "$EXTRACTED_APP" SUFeedURL "https://github.com/echoappstudio/EchoNyla/releases/latest/download/appcast.xml"
plutil -lint "$EXTRACTED_APP/Contents/Info.plist"
codesign --verify --deep --strict "$EXTRACTED_APP"
if [[ "$NOTARIZED" == "yes" ]]; then
    xcrun stapler validate "$EXTRACTED_APP"
    spctl --assess --type execute --verbose=2 "$EXTRACTED_APP"
fi
file "$EXTRACTED_APP/Contents/MacOS/EchoNyla"
bash Scripts/write-checksum-sidecar.sh "$ZIP"
{
    printf 'mode=%s\n' "$SIGN_MODE"
    printf 'notarized=%s\n' "$NOTARIZED"
    codesign --display --requirements - "$EXTRACTED_APP" 2>/dev/null | sed -n 's/^designated => /requirement=/p'
} > "$SIGNING_REPORT"
cat "$SIGNING_REPORT"
printf 'Verified package: %s\n' "$ZIP"
