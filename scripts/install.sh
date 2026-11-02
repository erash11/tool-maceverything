#!/bin/bash
# Installs ev and everythingd into ~/.local/bin, the app into ~/Applications,
# and starts the daemon at login with launchd.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/make-app.sh

BIN_DIR="$HOME/.local/bin"
LABEL=com.erash11.maceverything.daemon
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
mkdir -p "$BIN_DIR" "$HOME/Applications" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

# Stop the running daemon and app before replacing their binaries. Overwriting a running,
# code-signed binary in place can get it killed, and launchd could relaunch a half-copied file.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
osascript -e 'quit app "MacEverything"' 2>/dev/null || true
for i in 1 2 3 4 5 6 7 8 9 10; do
  launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || break
  sleep 0.5
done

# rm first, so each copy is a new file rather than a rewrite of the old one.
for bin in ev everythingd; do
  rm -f "$BIN_DIR/$bin"
  cp "build/$bin" "$BIN_DIR/$bin"
done
rm -rf "$HOME/Applications/MacEverything.app"
cp -R build/MacEverything.app "$HOME/Applications/"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$BIN_DIR/everythingd</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Standard</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/everythingd.log</string>
</dict>
</plist>
PLIST

# bootstrap can fail briefly right after a bootout; retry before giving up.
for i in 1 2 3 4 5; do
  if launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null; then break; fi
  if [ "$i" = 5 ]; then echo "launchctl bootstrap failed; run: launchctl bootstrap gui/$(id -u) $PLIST" >&2; exit 1; fi
  sleep 1
done
open "$HOME/Applications/MacEverything.app"

# Start the menu-bar app at login (launchd above only starts the daemon). The login item is
# keyed by path, so the rm/cp above keeps it; add it only when it is missing.
APP_PATH="$HOME/Applications/MacEverything.app"
if ! osascript -e 'tell application "System Events" to get the path of every login item' 2>/dev/null | grep -qF "$APP_PATH"; then
  osascript -e "tell application \"System Events\" to make login item at end with properties {path:\"$APP_PATH\", hidden:false}" >/dev/null \
    || echo "Could not add the login item; add MacEverything in System Settings > General > Login Items." >&2
fi

cat <<MSG

Installed.
  CLI:     $BIN_DIR/ev   (add $BIN_DIR to your PATH if it is not there)
  Daemon:  $BIN_DIR/everythingd, started by launchd, log at ~/Library/Logs/everythingd.log
  App:     ~/Applications/MacEverything.app   (Option-Space opens search)

First install only: System Settings > Privacy & Security > Full Disk Access,
click +, press Command-Shift-G, enter $BIN_DIR/everythingd, and turn it on,
then run  ev --rescan  once. Updates need neither; the daemon keeps itself current.
MSG
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q -e '"MacEverything Local Signing"' -e '"Developer ID Application'; then
  echo
  echo "Tip: run ./scripts/create-signing-cert.sh once, then reinstall, so Full Disk Access"
  echo "survives future rebuilds."
fi
