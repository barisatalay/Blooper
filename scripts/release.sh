#!/bin/bash
# .dmg üret + GitHub Release aç. Kullanım: scripts/release.sh 0.1.0
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: release.sh <version>}"
DMG="build/Blooper-$VERSION.dmg"

scripts/bundle.sh "$VERSION"

rm -f "$DMG"
mkdir -p build/dmg-root
rm -rf build/dmg-root/*
cp -R build/Blooper.app build/dmg-root/
ln -sf /Applications build/dmg-root/Applications
hdiutil create -volname "Blooper" -srcfolder build/dmg-root -ov -format UDZO "$DMG"

gh release create "v$VERSION" "$DMG" --title "Blooper v$VERSION" --generate-notes
echo "OK: released v$VERSION"
