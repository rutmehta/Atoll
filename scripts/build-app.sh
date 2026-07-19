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
/usr/bin/install_name_tool -add_rpath "@executable_path/../Frameworks" \
  "$APP/Contents/MacOS/Atoll" 2>/dev/null || true

if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

codesign --force --deep --sign - "$APP"
echo "Built $APP"
