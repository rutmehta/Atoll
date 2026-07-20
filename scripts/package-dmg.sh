#!/bin/bash
# Builds a universal (arm64 + x86_64) Atoll.app and packages it into a
# drag-to-Applications DMG at dist/Atoll-<version>.dmg for installing on
# other Macs.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist 2>/dev/null || echo "0.1.0")

echo "Building universal binary…"
swift build -c release --arch arm64 --arch x86_64

BUILD=".build/apple/Products/Release"
APP="dist/Atoll.app"

rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BUILD/Atoll" "$APP/Contents/MacOS/Atoll"
cp Resources/Info.plist "$APP/Contents/"

for bundle in "$BUILD"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

shopt -s nullglob
for dylib in "$BUILD"/*.dylib; do
  cp "$dylib" "$APP/Contents/Frameworks/"
done
shopt -u nullglob
/usr/bin/install_name_tool -add_rpath "@executable_path/../Frameworks" \
  "$APP/Contents/MacOS/Atoll" 2>/dev/null || true

if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

# Ad-hoc signature. For Gatekeeper-clean distribution, set SIGN_IDENTITY to a
# "Developer ID Application: …" cert and notarize the DMG afterwards.
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" "$APP" 2>/dev/null \
  || codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"

echo "Archs: $(lipo -archs "$APP/Contents/MacOS/Atoll")"

STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="dist/Atoll-$VERSION.dmg"
hdiutil create -volname "Atoll" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "Built $DMG"
echo
echo "Install on another Mac:"
echo "  1. Copy the DMG over (AirDrop works), open it, drag Atoll to Applications."
echo "  2. First launch will be blocked (app is not notarized). Either:"
echo "       xattr -dr com.apple.quarantine /Applications/Atoll.app"
echo "     or open System Settings → Privacy & Security → 'Open Anyway'."
echo "  3. Re-grant permissions on that Mac (Calendar, Camera, Accessibility,"
echo "     Notifications) and opt into agent hooks via Settings → Agents."
