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
# Sign with the local certificate if there is one (see make-signing-cert.sh), so macOS
# keeps the Accessibility permission across rebuilds. Otherwise sign ad hoc.
if security find-certificate -c "Kokoro Speak Local Signing" >/dev/null 2>&1; then
  codesign --force --sign "Kokoro Speak Local Signing" "$APP" >/dev/null
else
  codesign --force --sign - "$APP" >/dev/null
fi
echo "Built $APP"
