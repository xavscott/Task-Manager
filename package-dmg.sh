#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
NAME="Mac Task Manager"
APP="$ROOT/$NAME.app"
ACCESSORY_APP="$APP/Contents/Library/LoginItems/MacTaskManagerAccessory.app"
STAGE="$ROOT/.dmg-stage"
DMG="$ROOT/$NAME.dmg"
PKG="$ROOT/$NAME.pkg"
ICON_PNG="$STAGE/AppIcon1024.png"
ICONSET="$STAGE/AppIcon.iconset"
PKG_STAGE="$ROOT/.pkg-stage"
DERIVED_DATA="$ROOT/.build/Xcode"
BUILT_APP="$DERIVED_DATA/Build/Products/Release/MacTaskManager.app"

cd "$ROOT"
xcodebuild -project "$ROOT/MacTaskManager.xcodeproj" \
    -scheme MacTaskManager \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    -destination 'generic/platform=macOS' \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    build

rm -rf "$APP" "$STAGE" "$DMG" "$PKG" "$PKG_STAGE"
mkdir -p "$STAGE"
cp -R "$BUILT_APP" "$APP"
# The accessory monitor must have its own bundle identity. If it shares the main
# app's identity, macOS considers the hidden monitor to be the already-running
# Task Manager and opening the app will not create the visible window.
mkdir -p "$APP/Contents/Library/LoginItems"
cp -R "$BUILT_APP" "$ACCESSORY_APP"
# SMAppService.agent is the fallback for builds where macOS will not accept a
# Login Item registration (notably unsigned/ad-hoc development builds).
mkdir -p "$APP/Contents/Library/LaunchAgents"
cp "$ROOT/Sources/MacTaskManager/com.codex.mactaskmanager.accessory-monitor.plist" \
   "$APP/Contents/Library/LaunchAgents/"
# The monitor helper does not host the widget extension; excluding it keeps the
# helper self-contained and allows it to be signed independently.
rm -rf "$ACCESSORY_APP/Contents/PlugIns"
/usr/bin/plutil -replace CFBundleIdentifier -string com.codex.mactaskmanager.accessory-monitor "$ACCESSORY_APP/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleDisplayName -string "Mac Task Manager Accessory Monitor" "$ACCESSORY_APP/Contents/Info.plist"
# Keep the helper entirely in the background. It is registered through
# SMAppService.loginItem(identifier:) by the main app and relaunched by macOS
# at every user login, including after a reboot.
/usr/bin/plutil -replace LSUIElement -bool true "$ACCESSORY_APP/Contents/Info.plist"
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
/usr/libexec/PlistBuddy -c 'Add :CFBundleIconName string AppIcon' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIconFiles array' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIconFiles:0 string AppIcon' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleShortVersionString string 1.0' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 5' "$APP/Contents/Info.plist" || /usr/libexec/PlistBuddy -c 'Add :CFBundleVersion string 5' "$APP/Contents/Info.plist"
rm -rf "$ICON_PNG" "$ICONSET"
SIGNING_IDENTITY="$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/awk '/Apple Development:/ {print $2; exit}')"
if [ -n "$SIGNING_IDENTITY" ]; then
    codesign --force --sign "$SIGNING_IDENTITY" "$ACCESSORY_APP"
    codesign --force --sign "$SIGNING_IDENTITY" --entitlements "$ROOT/Sources/MacTaskManagerWidget/MacTaskManagerWidget.entitlements" "$APP/Contents/PlugIns/MacTaskManagerWidgetExtension.appex"
    codesign --force --sign "$SIGNING_IDENTITY" "$APP"
else
    codesign --force --sign - "$ACCESSORY_APP"
    codesign --force --sign - --entitlements "$ROOT/Sources/MacTaskManagerWidget/MacTaskManagerWidget.entitlements" "$APP/Contents/PlugIns/MacTaskManagerWidgetExtension.appex"
    codesign --force --sign - "$APP"
fi

# Package an explicit Applications directory under the package root. Component
# packages can relocate an app with the same bundle identifier to wherever an
# older copy was moved, which can leave no app in /Applications after install.
mkdir -p "$PKG_STAGE/Applications"
cp -R "$APP" "$PKG_STAGE/Applications/$NAME.app"
pkgbuild --root "$PKG_STAGE" \
    --component-plist "$ROOT/scripts/pkg-components.plist" \
    --identifier com.codex.mactaskmanager \
    --version 1.0 \
    --install-location / \
    --scripts "$ROOT/scripts/pkg-scripts" \
    "$PKG"
rm -rf "$PKG_STAGE"

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
echo "Created $DMG"
