#!/usr/bin/env bash
# Siri, Shortcuts and Spotlight find EchoNyla's actions (Sources/EchoNylaApp/NylaActions.swift) in
# the app's Contents/Resources/Metadata.appintents. Xcode writes that folder itself; `swift build`
# doesn't, so this script does the two steps Xcode does:
# (Made for Verbyn 0.8.0, where it was proven on Xcode 27.)
#   bash Scripts/app-intents.sh build-flags   the extra `swift build` flags (one per line): the compiler
#                                             writes what it knows about the App Intents types
#   bash Scripts/app-intents.sh extract APP   runs Xcode's appintentsmetadataprocessor on the built app
#                                             and checks every action is in the result
# Any problem stops the build: an app whose actions silently went missing must not ship.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

MODULE="EchoNylaApp"
# The build names the app's folder after the product (Package.swift: .executable(name: "EchoNyla")),
# not after the module, so the compiler's files are in …/Release/EchoNyla-p.build/….
PRODUCT="EchoNyla"
WORK=".build/app-intents"
PROTOCOLS="$WORK/protocols.json"
# The action types the app defines; each must be in the metadata.
EXPECTED_ACTIONS=(SortFilesIntent DescribeFileIntent FindFilesIntent OpenInFilesIntent CleanUpDownloadsIntent)

toolchain_dir() {
    dirname "$(dirname "$(dirname "$(xcrun --find swift)")")"
}

write_protocols() {
    mkdir -p "$WORK"
    local listed fresh="$PROTOCOLS.new"
    listed="$(toolchain_dir)/usr/share/swift/SwiftConstantValues/AppIntents.json"
    if [[ -f "$listed" ]] && plutil -extract constValueProtocols json -o "$fresh" "$listed" 2>/dev/null; then
        :
    else
        # The toolchain's own list is missing: the protocols App Intents reads, from Apple's documentation.
        printf '%s' '["AppIntent","EntityQuery","AppEntity","TransientEntity","AppEnum","AppShortcutProviding","AppShortcutsProvider","AnyResolverProviding","AppIntentsPackage","DynamicOptionsProvider","IntentValueQuery","Resolver","_IntentValueRepresentable"]' > "$fresh"
    fi
    # Rewrite the file only when it changes, so swift build doesn't rebuild everything each time.
    if cmp -s "$fresh" "$PROTOCOLS"; then rm "$fresh"; else mv "$fresh" "$PROTOCOLS"; fi
}

case "${1:-}" in
    build-flags)
        write_protocols
        printf '%s\n' -Xswiftc -emit-const-values \
            -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file \
            -Xswiftc -Xfrontend -Xswiftc "$ROOT_DIR/$PROTOCOLS"
        ;;
    extract)
        APP="${2:?usage: app-intents.sh extract path/to/EchoNyla.app}"
        xcrun --find appintentsmetadataprocessor >/dev/null || { echo "error: appintentsmetadataprocessor not found (it comes with Xcode)" >&2; exit 1; }
        mkdir -p "$WORK"
        # The newest constant values the release build wrote for the app (Xcode 27's build system keeps
        # them in .build/out/Intermediates.noindex/…/Release/EchoNyla-p.build/…).
        found=()
        while IFS= read -r file; do found+=("$file"); done < <(
            find .build -name '*.swiftconstvalues' -path "*/${PRODUCT}-p.build/*" -ipath '*release*' ! -path '*Tests*' -print)
        consts=()
        if ((${#found[@]} > 0)); then
            while IFS= read -r file; do consts+=("$file"); done < <(ls -t "${found[@]}")
        fi
        if ((${#consts[@]} == 0)); then
            echo "error: the build wrote no App Intents constant values (*.swiftconstvalues) for $MODULE" >&2
            find .build -name '*.swiftconstvalues' -print >&2 || true
            exit 1
        fi
        newest_dir="$(dirname "${consts[0]}")"
        find "$ROOT_DIR/$newest_dir" -maxdepth 1 -name '*.swiftconstvalues' > "$WORK/const-values.txt"
        # The module the compiler named the actions' types with ("EchoNylaApp.SortFilesIntent").
        named="$(grep -ohE '"[A-Za-z0-9_]+\.SortFilesIntent"' $(cat "$WORK/const-values.txt") 2>/dev/null | head -n 1 | tr -d '"' || true)"
        if [[ -n "$named" ]]; then
            MODULE="${named%%.*}"
        else
            echo "warning: SortFilesIntent isn't named in the constant values; using module $MODULE" >&2
        fi
        printf 'Module: %s\n' "$MODULE"
        find "$ROOT_DIR/Sources/EchoNylaApp" -name '*.swift' > "$WORK/sources.txt"
        printf 'Constant values: %s file(s) in %s\n' "$(wc -l < "$WORK/const-values.txt" | tr -d ' ')" "$newest_dir"
        bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
        deployment="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
        executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
        xcode_build="$(xcodebuild -version | awk '/Build version/ { print $3 }')"
        rm -rf "$APP/Contents/Resources/Metadata.appintents"
        if ! xcrun appintentsmetadataprocessor \
            --output "$APP/Contents/Resources" \
            --toolchain-dir "$(toolchain_dir)" \
            --module-name "$MODULE" \
            --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
            --xcode-version "$xcode_build" \
            --platform-family macOS \
            --deployment-target "$deployment" \
            --target-triple "arm64-apple-macos$deployment" \
            --bundle-identifier "$bundle_id" \
            --binary-file "$APP/Contents/MacOS/$executable" \
            --source-file-list "$WORK/sources.txt" \
            --swift-const-vals-list "$WORK/const-values.txt" > "$WORK/processor.log" 2>&1; then
            cat "$WORK/processor.log" >&2
            echo "error: appintentsmetadataprocessor failed" >&2
            exit 1
        fi
        data="$APP/Contents/Resources/Metadata.appintents/extract.actionsdata"
        if [[ ! -s "$data" ]]; then
            cat "$WORK/processor.log" >&2
            echo "error: Metadata.appintents wasn't written, so Shortcuts wouldn't see EchoNyla's actions" >&2
            exit 1
        fi
        for action in "${EXPECTED_ACTIONS[@]}"; do
            grep -q "$action" "$data" || { echo "error: $action is missing from Metadata.appintents" >&2; exit 1; }
        done
        printf 'App Intents: %s actions in Metadata.appintents\n' "${#EXPECTED_ACTIONS[@]}"
        ;;
    *)
        echo "usage: $0 build-flags | extract APP" >&2
        exit 2
        ;;
esac
