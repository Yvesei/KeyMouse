#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/build/KeyMouse.app"
mkdir -p "$APP/Contents/MacOS" build/module-cache
xcrun swiftc -O -module-cache-path "$PWD/build/module-cache" -framework AppKit -framework CoreBluetooth -framework IOKit Sources/main.swift -o "$APP/Contents/MacOS/KeyMouse"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
printf 'Built: %s\n' "$APP"
