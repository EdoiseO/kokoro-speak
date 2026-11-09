#!/bin/zsh
# Builds "Kokoro Speak.app" into ./build. Usage: scripts/build-app.sh
set -euo pipefail
ROOT=${0:A:h:h}
APP="$ROOT/build/Kokoro Speak.app"

swift build --package-path "$ROOT/app" -c release --arch arm64
BIN=$(swift build --package-path "$ROOT/app" -c release --arch arm64 --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/KokoroSpeak" "$APP/Contents/MacOS/KokoroSpeak"
cp "$ROOT/app/Resources/Info.plist" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
