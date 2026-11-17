#!/bin/bash
# Build, sign and launch SpeakerSync into ~/.local/speakersync.
# Usage: ./build.sh          (build + relaunch)
#        ./build.sh --no-run (build only)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="$HOME/.local/speakersync"
APP="$OUT/SpeakerSync.app"

mkdir -p "$APP/Contents/MacOS"
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"
# The app reads live.html from ~/.local/speakersync; point it at the repo's dashboard.
ln -sfn "$ROOT/03 Dashboard/(C) Live Dashboard.html" "$OUT/live.html"
ln -sfn "$HERE/src" "$OUT/src"

# -target: the toolchain defaults to a newer macOS and the app won't launch on 27 without it.
swiftc -O -swift-version 5 -target arm64-apple-macosx27.0 "$HERE/src/main.swift" -o "$APP/Contents/MacOS/SpeakerSync"
# The fixed designated requirement keeps the app's identity stable, so macOS
# doesn't re-ask for Microphone / System Audio Recording after every rebuild.
codesign -s - --force -r='designated => identifier "local.vivos.speakersync"' "$APP"
echo "Built $APP"

if [[ "${1:-}" != "--no-run" ]]; then
  pkill -TERM -x SpeakerSync 2>/dev/null || true
  sleep 1
  open "$APP"
fi
