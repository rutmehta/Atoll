#!/bin/bash
# One-command Sparkle release:
#   ./scripts/release.sh 0.2.1 ["release notes"]
# Bumps versions, builds the universal DMG, signs it for Sparkle, prepends an
# appcast item, commits + pushes, and publishes the GitHub release the appcast
# points at. Existing installs pick the update up automatically.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: release.sh <version> [notes]}"
NOTES="${2:-Atoll $VERSION}"
SIGN_TOOL=".build/artifacts/sparkle/Sparkle/bin/sign_update"
[ -x "$SIGN_TOOL" ] || { echo "error: $SIGN_TOOL missing — run swift build first" >&2; exit 1; }

BUILDNUM=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Resources/Info.plist) + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
                        -c "Set :CFBundleVersion $BUILDNUM" Resources/Info.plist

./scripts/package-dmg.sh

DMG="dist/Atoll-$VERSION.dmg"
SIGNATURE=$("$SIGN_TOOL" "$DMG" | tr -d '\n')
URL="https://github.com/rutmehta/Atoll/releases/download/v$VERSION/Atoll-$VERSION.dmg"
PUBDATE=$(LC_ALL=en_US date "+%a, %d %b %Y %H:%M:%S %z")

python3 - "$VERSION" "$BUILDNUM" "$URL" "$SIGNATURE" "$PUBDATE" <<'EOF'
import html
import sys

version, buildnum, url, signature, pubdate = sys.argv[1:6]
item = f"""    <item>
      <title>{html.escape(version)}</title>
      <pubDate>{pubdate}</pubDate>
      <sparkle:version>{buildnum}</sparkle:version>
      <sparkle:shortVersionString>{html.escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="{html.escape(url)}" {signature} type="application/octet-stream"/>
    </item>
"""
path = "appcast.xml"
content = open(path).read()
marker = "<language>en</language>\n"
index = content.find(marker)
assert index != -1, "appcast.xml missing channel language marker"
insert_at = index + len(marker)
open(path, "w").write(content[:insert_at] + item + content[insert_at:])
print(f"appcast: added {version} (build {buildnum})")
EOF

git add Resources/Info.plist appcast.xml
git commit -m "Release $VERSION"
git push
gh release create "v$VERSION" "$DMG" --title "Atoll $VERSION" --notes "$NOTES"
echo "Released v$VERSION — Sparkle clients update automatically from the appcast."
