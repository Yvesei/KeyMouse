#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/build/KeyMouse.app"
mkdir -p "$APP/Contents/MacOS" build/module-cache
SWIFT_ARGS=(-O -module-cache-path "$PWD/build/module-cache" -framework AppKit -framework CoreBluetooth -framework IOKit Sources/main.swift)
if [[ "${KEYMOUSE_UNIVERSAL:-0}" == 1 ]]; then
  for arch in arm64 x86_64; do
    xcrun swiftc "${SWIFT_ARGS[@]}" -target "${arch}-apple-macosx12.0" -o "$PWD/build/KeyMouse-$arch"
  done
  xcrun lipo -create build/KeyMouse-arm64 build/KeyMouse-x86_64 -output "$APP/Contents/MacOS/KeyMouse"
  rm build/KeyMouse-arm64 build/KeyMouse-x86_64
else
  xcrun swiftc "${SWIFT_ARGS[@]}" -o "$APP/Contents/MacOS/KeyMouse"
fi
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
printf 'Built: %s\n' "$APP"
