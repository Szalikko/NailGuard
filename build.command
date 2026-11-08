#!/bin/zsh
set -eu
cd "$(dirname "$0")"
TASK_BUILD_CACHE="${TMPDIR:-/tmp}/NailGuardSwiftModules"
mkdir -p "$TASK_BUILD_CACHE" NailGuard.app/Contents/MacOS NailGuard.app/Contents/Resources
cp Resources/Info.plist NailGuard.app/Contents/Info.plist
cp Assets/AppIcon.icns NailGuard.app/Contents/Resources/AppIcon.icns
swiftc -target arm64-apple-macosx14.0 -module-cache-path "$TASK_BUILD_CACHE" -swift-version 5 -O -framework Cocoa -framework AVFoundation -framework Vision -framework SwiftUI -framework Charts -framework ServiceManagement Source/main.swift Source/Support.swift -o NailGuard.app/Contents/MacOS/NailGuard
codesign --force --sign - NailGuard.app
NailGuard.app/Contents/MacOS/NailGuard --self-test
