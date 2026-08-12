#!/bin/bash
# Universal .app üretimi — Xcode projesi yok, salt SPM + sistem araçları.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-0.1.0}"
APP="build/Blooper.app"

swift build -c release --arch arm64 --arch x86_64

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/apple/Products/Release/Blooper "$APP/Contents/MacOS/Blooper"
cp Resources/scripts/hook.sh Resources/scripts/checker.sh \
   Resources/scripts/statusline-fragment.sh Resources/scripts/statusline-wrapper-template.sh \
   "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/"*.sh
cp Resources/AppIcon.icns Resources/MenuBarIcon.png "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Blooper</string>
    <key>CFBundleIdentifier</key><string>com.barisatalay.blooper</string>
    <key>CFBundleName</key><string>Blooper</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
EOF

# Ad-hoc imza, sabit identifier (garanti değil ama TCC kimliğini stabilize etmeyi dener)
codesign --force -s - --identifier com.barisatalay.blooper "$APP"
echo "OK: $APP"
