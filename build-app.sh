#!/bin/sh
# Builds EQMenuBar.app: a release binary in a bundle with Info.plist, ad-hoc signed.
# macOS only shows the System Audio Recording prompt for a bundled, signed app.
set -e

cd "$(dirname "$0")"
swift build -c release

APP=EQMenuBar.app
BIN="$(swift build -c release --show-bin-path)/EQMenuBar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/EQMenuBar"
cp Sources/EQMenuBar/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

echo "Built $(pwd)/$APP"
