#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
NAME="Mac Task Manager"
APP="$ROOT/$NAME.app"
STAGE="$ROOT/.dmg-stage"
DMG="$ROOT/$NAME.dmg"
ICON_PNG="$STAGE/AppIcon1024.png"
ICONSET="$STAGE/AppIcon.iconset"
DERIVED_DATA="$ROOT/.build/Xcode"
BUILT_APP="$DERIVED_DATA/Build/Products/Release/MacTaskManager.app"

cd "$ROOT"
xcodebuild -quiet -project "$ROOT/MacTaskManager.xcodeproj" -scheme MacTaskManager -configuration Release -derivedDataPath "$DERIVED_DATA" CODE_SIGNING_ALLOWED=NO build
rm -rf "$APP" "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$BUILT_APP" "$APP"
mkdir -p "$APP/Contents/Resources"
swift "$ROOT/scripts/create-app-icon.swift" "$ICON_PNG"
mkdir -p "$ICONSET"
for ICON_SIZE in 16 32 128 256 512; do
    sips -z "$ICON_SIZE" "$ICON_SIZE" "$ICON_PNG" --out "$ICONSET/icon_${ICON_SIZE}x${ICON_SIZE}.png" >/dev/null
    DOUBLE_SIZE=$((ICON_SIZE * 2))
    sips -z "$DOUBLE_SIZE" "$DOUBLE_SIZE" "$ICON_PNG" --out "$ICONSET/icon_${ICON_SIZE}x${ICON_SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string AppIcon' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleShortVersionString string 1.0' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 5' "$APP/Contents/Info.plist" || /usr/libexec/PlistBuddy -c 'Add :CFBundleVersion string 5' "$APP/Contents/Info.plist"
rm -rf "$ICON_PNG" "$ICONSET"
SIGNING_IDENTITY="$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/awk '/Apple Development:/ {print $2; exit}')"
if [ -n "$SIGNING_IDENTITY" ]; then
    codesign --force --sign "$SIGNING_IDENTITY" --entitlements "$ROOT/Sources/MacTaskManagerWidget/MacTaskManagerWidget.entitlements" "$APP/Contents/PlugIns/MacTaskManagerWidgetExtension.appex"
    codesign --force --sign "$SIGNING_IDENTITY" "$APP"
else
    codesign --force --sign - --entitlements "$ROOT/Sources/MacTaskManagerWidget/MacTaskManagerWidget.entitlements" "$APP/Contents/PlugIns/MacTaskManagerWidgetExtension.appex"
    codesign --force --sign - "$APP"
fi
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
echo "Created $DMG"
