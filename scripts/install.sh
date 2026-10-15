#!/bin/bash
# Installs ev and everythingd into ~/.local/bin, the app into ~/Applications,
# and starts the daemon at login with launchd.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/make-app.sh

BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR" "$HOME/Applications" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cp build/ev build/everythingd "$BIN_DIR/"
rm -rf "$HOME/Applications/MacEverything.app"
cp -R build/MacEverything.app "$HOME/Applications/"

LABEL=com.erash11.maceverything.daemon
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$BIN_DIR/everythingd</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/everythingd.log</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
open "$HOME/Applications/MacEverything.app"

cat <<MSG

Installed.
  CLI:     $BIN_DIR/ev   (add $BIN_DIR to your PATH if it is not there)
  Daemon:  $BIN_DIR/everythingd, started by launchd, log at ~/Library/Logs/everythingd.log
  App:     ~/Applications/MacEverything.app   (Option-Space opens search)

One manual step: System Settings > Privacy & Security > Full Disk Access,
click +, press Command-Shift-G, enter $BIN_DIR/everythingd, and turn it on.
Then run:  ev --rescan
MSG
