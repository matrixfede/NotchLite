#!/bin/sh
# Builds build/NotchLite.app with only the Command Line Tools (no Xcode needed).
#   ./build.sh           build
#   ./build.sh install   build and copy to /Applications
set -eu
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/NotchLite"

APP=build/NotchLite.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NotchLite"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Bridge/media.pl "$APP/Contents/Resources/media.pl"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# The bridge runs inside /usr/bin/perl, which is universal: build both slices.
clang -dynamiclib -fobjc-arc -O2 -Wall -arch arm64 -arch x86_64 \
  -mmacosx-version-min=14.0 -framework Foundation -framework AppKit -framework ImageIO \
  Bridge/MediaBridge.m -o "$APP/Contents/Resources/MediaBridge.dylib"

codesign --force --sign - "$APP/Contents/Resources/MediaBridge.dylib"
codesign --force --sign - "$APP"
echo "Built $APP"

if [ "${1:-}" = "install" ]; then
  pkill -x NotchLite 2>/dev/null || true
  rm -rf /Applications/NotchLite.app
  cp -R "$APP" /Applications/
  echo "Installed /Applications/NotchLite.app"
fi
