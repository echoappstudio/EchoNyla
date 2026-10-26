#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT_DIR/dist/EchoNyla.app"
test -x "$APP/Contents/MacOS/EchoNyla"
open "$APP"
sleep 3
pid="$(pgrep -x EchoNyla || true)"
if test -z "$pid"; then
  printf 'App did not remain running after launch.\n' >&2
  exit 1
fi
kill "$pid"
# Launching may have put a skin icon on the app in Finder (if a skin other than Signature is saved); later steps
# copy and re-sign this app, so take it off again.
for _ in {1..10}; do
  if ! pgrep -x EchoNyla >/dev/null 2>&1; then break; fi
  sleep 0.5
done
rm -f "$APP/Icon"$'\r'
xattr -d com.apple.FinderInfo "$APP" >/dev/null 2>&1 || true
printf 'App launch smoke test passed (process started and was stopped cleanly).\n'
