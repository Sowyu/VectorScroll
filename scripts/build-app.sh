#!/bin/sh
set -eu

swift build -c release

APP_DIR="dist/VectorScroll.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
ICONSET="dist/VectorScroll.iconset"

rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES"

cp ".build/release/VectorScroll" "$MACOS/VectorScroll"
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
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
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
