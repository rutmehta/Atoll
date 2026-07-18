#!/bin/bash
# Builds AgentNook.app into dist/ from the SPM executable target.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/AgentNook"
APP="dist/AgentNook.app"

rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AgentNook"
cp Resources/Info.plist "$APP/Contents/"

# SPM resource bundles need to sit in Contents/Resources for Bundle.module to resolve.
for bundle in ".build/$CONFIG"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

codesign --force --sign - "$APP"
echo "Built $APP"
