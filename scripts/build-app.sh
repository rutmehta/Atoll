#!/bin/bash
# Builds Atoll.app into dist/ from the SPM executable target.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"

BUILD=".build/$CONFIG"
APP="dist/Atoll.app"

rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BUILD/Atoll" "$APP/Contents/MacOS/Atoll"
cp Resources/Info.plist "$APP/Contents/"

# SPM resource bundles must sit in Contents/Resources for Bundle.module to resolve.
for bundle in "$BUILD"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

# Dynamic-library products (MediaRemoteAdapter) go into Contents/Frameworks.
shopt -s nullglob
for dylib in "$BUILD"/*.dylib; do
  cp "$dylib" "$APP/Contents/Frameworks/"
done
shopt -u nullglob
shopt -s nullglob
for fw in "$BUILD"/*.framework; do
  cp -R "$fw" "$APP/Contents/Frameworks/"
done
shopt -u nullglob
/usr/bin/install_name_tool -add_rpath "@executable_path/../Frameworks" \
  "$APP/Contents/MacOS/Atoll" 2>/dev/null || true

if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

# Sign with Developer ID when available so TCC grants (accessibility, screen
# recording) survive rebuilds; ad-hoc otherwise. Pin by hash, not name — the
# keychain also holds Apple Development certs that would match a substring.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | awk '/Developer ID Application/ {print $2; exit}')}"
if [ -n "$IDENTITY" ]; then
  # Inner code first, then the bundle — never --deep for real signing.
  shopt -s nullglob
  for dylib in "$APP/Contents/Frameworks/"*.dylib; do
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$dylib"
  done
  shopt -u nullglob
  SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
  if [ -d "$SPARKLE_FW" ]; then
    for nested in "$SPARKLE_FW"/Versions/B/XPCServices/*.xpc \
                  "$SPARKLE_FW"/Versions/B/Autoupdate \
                  "$SPARKLE_FW"/Versions/B/Updater.app; do
      [ -e "$nested" ] && codesign --force --options runtime --timestamp --sign "$IDENTITY" "$nested"
    done
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPARKLE_FW"
  fi
  codesign --force --options runtime --timestamp \
    --entitlements Resources/Atoll.entitlements \
    --sign "$IDENTITY" "$APP"
else
  codesign --force --deep --sign - "$APP"
fi
codesign --verify --strict --deep "$APP"
echo "Built $APP"
