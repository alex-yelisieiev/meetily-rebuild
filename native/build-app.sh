#!/bin/bash
# Builds Meetily.app: native SwiftUI front end with the Rust engine embedded.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
ENGINE_SRC="$ROOT/target/release/bundle/macos/meetily.app"
OUT="build/Meetily.app"
ENGINE="$OUT/Contents/Library/Engine/Meetily Engine.app"

[ -d "$ENGINE_SRC" ] || { echo "Engine bundle missing: build it with 'pnpm tauri build --bundles app' in frontend/"; exit 1; }

swift build -c release
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources" "$OUT/Contents/Library/Engine"
cp .build/release/Meetily "$OUT/Contents/MacOS/Meetily"
cp Info.plist "$OUT/Contents/Info.plist"
cp "$ENGINE_SRC/Contents/Resources/app_icon.icns" "$OUT/Contents/Resources/AppIcon.icns"
ditto "$ENGINE_SRC" "$ENGINE"

# The engine never shows UI of its own.
/usr/libexec/PlistBuddy -c "Delete :LSUIElement" "$ENGINE/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$ENGINE/Contents/Info.plist"

codesign -d --entitlements - --xml "$ENGINE_SRC" > build/engine.entitlements 2>/dev/null || true
if [ -s build/engine.entitlements ]; then
  codesign --force --sign - --options runtime --entitlements build/engine.entitlements "$ENGINE"
else
  codesign --force --sign - "$ENGINE"
fi
codesign --force --sign - "$OUT"
codesign --verify --deep --strict "$OUT" && echo "Built $(pwd)/$OUT"
