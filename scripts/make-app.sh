#!/bin/bash
# Builds release binaries and wraps the menu-bar app in build/MacEverything.app.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN=.build/release
APP=build/MacEverything.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/EverythingApp" "$APP/Contents/MacOS/MacEverything"
cp "$BIN/everythingd" "$BIN/ev" build/

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MacEverything</string>
  <key>CFBundleIdentifier</key><string>com.erash11.maceverything</string>
  <key>CFBundleExecutable</key><string>MacEverything</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature so macOS will run it locally.
codesign --force --sign - "$APP" build/everythingd build/ev
echo "Built $APP, build/everythingd and build/ev"
