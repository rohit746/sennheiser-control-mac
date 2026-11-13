#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="SennheiserControl"
BUNDLE="build/${APP_NAME}.app"

swift build -c release

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp ".build/release/${APP_NAME}" "$BUNDLE/Contents/MacOS/${APP_NAME}"

ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$BUNDLE/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>SennheiserControl</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>dev.rohit.SennheiserControl</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Sennheiser Control</string>
    <key>CFBundleDisplayName</key>
    <string>Sennheiser Control</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>2.0.0</string>
    <key>CFBundleVersion</key>
    <string>3</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>Sennheiser Control connects to your paired Sennheiser headphones over Bluetooth to control noise cancellation, transparency, the equalizer and device settings.</string>
    <key>NSBluetoothPeripheralUsageDescription</key>
    <string>Sennheiser Control connects to your paired Sennheiser headphones over Bluetooth to control noise cancellation, transparency, the equalizer and device settings.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$BUNDLE" 2>/dev/null || true

echo "Built: $BUNDLE"
