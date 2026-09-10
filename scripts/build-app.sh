#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
APP_DIR="$PWD/dist/VectorScroll.app"
if [ -e "$APP_DIR" ]; then
    echo "Output already exists: $APP_DIR. Move it to Trash before rebuilding." >&2
    exit 1
fi
swift build -c release --arch arm64 --arch x86_64
BIN_DIR=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
mkdir -p "$PWD/dist"
ICONSET=$(mktemp -d "$PWD/dist/VectorScroll-icons.XXXXXX")
ICONSET="$ICONSET/VectorScroll.iconset"
mkdir -p "$MACOS" "$RESOURCES"

cp "$BIN_DIR/VectorScroll" "$MACOS/VectorScroll"
swift scripts/make-icons.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$RESOURCES/VectorScroll.icns"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>VectorScroll</string>
    <key>CFBundleIdentifier</key>
    <string>local.vectorscroll.app</string>
    <key>CFBundleName</key>
    <string>VectorScroll</string>
    <key>CFBundleDisplayName</key>
    <string>VectorScroll</string>
    <key>CFBundleIconFile</key>
    <string>VectorScroll.icns</string>
    <key>CFBundleIconName</key>
    <string>VectorScroll</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>CFBundleShortVersionString</key>
    <string>1.2.0</string>
    <key>CFBundleVersion</key>
    <string>3</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAccessibilityUsageDescription</key>
    <string>VectorScroll uses accessibility to bring the window under the cursor forward and post native scroll events on the user's behalf.</string>
    <key>NSInputMonitoringUsageDescription</key>
    <string>VectorScroll listens for middle-click and other mouse buttons to start and stop vector scrolling.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_DIR" >/dev/null
touch "$APP_DIR"

echo "Built $APP_DIR"
