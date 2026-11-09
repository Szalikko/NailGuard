#!/bin/zsh
set -eu
cd "$(dirname "$0")"
TASK_BUILD_CACHE="${TMPDIR:-/tmp}/NailGuardSwiftModules"
mkdir -p "$TASK_BUILD_CACHE" "NailGuard HRT.app"/Contents/MacOS "NailGuard HRT.app"/Contents/Resources
cp Resources/Info.plist "NailGuard HRT.app"/Contents/Info.plist
cp Assets/AppIcon.icns "NailGuard HRT.app"/Contents/Resources/AppIcon.icns
swiftc -target arm64-apple-macosx14.0 -module-cache-path "$TASK_BUILD_CACHE" -swift-version 5 -O -framework Cocoa -framework AVFoundation -framework Vision -framework SwiftUI -framework Charts -framework ServiceManagement Source/main.swift Source/Support.swift Source/HRT.swift -o "NailGuard HRT.app"/Contents/MacOS/NailGuard
codesign --force --sign - "NailGuard HRT.app"
"NailGuard HRT.app"/Contents/MacOS/NailGuard --self-test
