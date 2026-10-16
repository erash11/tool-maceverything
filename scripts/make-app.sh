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

# Signing. macOS ties Full Disk Access to the code signature's designated requirement.
# An ad-hoc signature's requirement is the binary's hash, so every rebuild loses the grant.
# A certificate-based signature's requirement is "this identifier, signed by this
# certificate", which stays the same across rebuilds.
#
# Identity, in order of preference:
#   1. MEV_SIGN_IDENTITY, if set ("-" forces ad-hoc)
#   2. a "Developer ID Application" certificate in the keychain
#   3. the free local certificate made by scripts/create-signing-cert.sh
#   4. ad-hoc
LOCAL_NAME="MacEverything Local Signing"
if [ -z "${MEV_SIGN_IDENTITY:-}" ]; then
  identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  if dev_id="$(printf '%s\n' "$identities" | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')" && [ -n "$dev_id" ]; then
    MEV_SIGN_IDENTITY="$dev_id"
  elif printf '%s\n' "$identities" | grep -q "\"$LOCAL_NAME\""; then
    MEV_SIGN_IDENTITY="$LOCAL_NAME"
  else
    MEV_SIGN_IDENTITY="-"
  fi
fi

sign() {
  local identifier="$1"; shift
  if [ "$MEV_SIGN_IDENTITY" = "-" ]; then
    codesign --force --sign - --identifier "$identifier" "$@"
  else
    local opts=(--force --options runtime --sign "$MEV_SIGN_IDENTITY" --identifier "$identifier")
    # Apple's timestamp server only accepts Apple-issued certificates.
    case "$MEV_SIGN_IDENTITY" in "Developer ID"*) opts+=(--timestamp) ;; esac
    codesign "${opts[@]}" "$@"
  fi
}
sign com.erash11.maceverything.daemon build/everythingd
sign com.erash11.maceverything.ev build/ev
sign com.erash11.maceverything "$APP"

if [ "$MEV_SIGN_IDENTITY" = "-" ]; then
  echo "Signed ad-hoc. Full Disk Access must be granted again after each rebuild;"
  echo "run scripts/create-signing-cert.sh once to sign with a stable identity."
else
  echo "Signed with: $MEV_SIGN_IDENTITY"
fi
echo "Built $APP, build/everythingd and build/ev"
