#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
NAME="Mac Task Manager"
APP="$ROOT/$NAME.app"
STAGE="$ROOT/.dmg-stage"
DMG="$ROOT/$NAME.dmg"

cd "$ROOT"
swift build -c release
rm -rf "$APP" "$STAGE" "$DMG"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$STAGE"
cp "$ROOT/.build/release/MacTaskManager" "$APP/Contents/MacOS/MacTaskManager"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>MacTaskManager</string>
    <key>CFBundleIdentifier</key><string>com.codex.mactaskmanager</string>
    <key>CFBundleName</key><string>Mac Task Manager</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>Mac Task Manager uses Bluetooth to show connected Apple accessories and details macOS provides, such as the device name, model, and battery level.</string>
</dict>
</plist>
PLIST
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
echo "Created $DMG"
