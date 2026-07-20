#!/bin/bash
# Builds, Developer ID-signs, notarizes, and staples Atoll for distribution.
#
# One-time setup (see README "Notarized builds"):
#   1. A "Developer ID Application" certificate in your keychain.
#   2. xcrun notarytool store-credentials atoll-notary \
#        --apple-id <apple-id> --team-id <TEAMID> --password <app-specific-pw>
#
# Then: ./scripts/notarize.sh
# Env overrides: SIGN_IDENTITY (default: first "Developer ID Application" match),
#                NOTARY_PROFILE (default: atoll-notary)
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
PROFILE="${NOTARY_PROFILE:-atoll-notary}"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)

if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  echo "error: no 'Developer ID Application' certificate in the keychain." >&2
  echo "Create one at developer.apple.com (Account Holder role required) or via" >&2
  echo "Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application." >&2
  exit 1
fi

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
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true

echo "Signing (hardened runtime)…"
# Inner code first, then the bundle — never --deep for real signing.
for dylib in "$APP/Contents/Frameworks/"*.dylib; do
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$dylib"
done
codesign --force --options runtime --timestamp \
  --entitlements Resources/Atoll.entitlements \
  --sign "$IDENTITY" "$APP"
codesign --verify --strict --deep "$APP"

echo "Notarizing the app…"
ditto -c -k --keepParent "$APP" "dist/Atoll-notarize.zip"
xcrun notarytool submit "dist/Atoll-notarize.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm "dist/Atoll-notarize.zip"

echo "Building DMG from the stapled app…"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="dist/Atoll-$VERSION.dmg"
hdiutil create -volname "Atoll" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "Notarizing the DMG…"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

echo "Gatekeeper check:"
spctl --assess --type execute -vv "$APP" 2>&1 | sed 's/^/  /'
echo "Built + notarized $DMG — installs on any Mac with zero warnings."
