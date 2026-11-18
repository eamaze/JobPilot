#!/bin/bash
# Builds JobPilot.app into ./build. Works with Xcode or with only the Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"

CLT=/Library/Developer/CommandLineTools
if swiftc --version >/dev/null 2>&1 && xcodebuild -version >/dev/null 2>&1; then
  SDK=$(xcrun --show-sdk-path)
else
  # No usable Xcode (not installed, or its licence has not been accepted yet):
  # build with the Command Line Tools instead.
  export DEVELOPER_DIR=$CLT
  # The Command Line Tools ship no SwiftUI macro plugin for the macOS 27 SDK,
  # so fall back to the newest macOS 26 SDK, where SwiftUI needs no macros.
  SDK=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.*.sdk 2>/dev/null | sort -V | tail -1)
  [ -n "$SDK" ] || SDK=$(xcrun --show-sdk-path)
fi

APP=build/JobPilot.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling with $SDK"
swiftc -O -parse-as-library -swift-version 5 \
  -sdk "$SDK" -target "$(uname -m)-apple-macos14.0" \
  Sources/*.swift -o "$APP/Contents/MacOS/JobPilot"

cp Info.plist "$APP/Contents/Info.plist"

if [ ! -f build/AppIcon.icns ]; then
  swiftc -sdk "$SDK" Tools/make_icon.swift -o build/make_icon 2>/dev/null && build/make_icon build/icon.png || true
  if [ -f build/icon.png ]; then
    SET=build/AppIcon.iconset; rm -rf "$SET"; mkdir -p "$SET"
    for s in 16 32 128 256 512; do
      sips -z $s $s build/icon.png --out "$SET/icon_${s}x${s}.png" >/dev/null
      sips -z $((s*2)) $((s*2)) build/icon.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$SET" -o build/AppIcon.icns || true
  fi
fi
[ -f build/AppIcon.icns ] && cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
