#!/bin/bash
set -uo pipefail
LABEL=com.erash11.maceverything.daemon
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist" "$HOME/.local/bin/ev" "$HOME/.local/bin/everythingd"
rm -rf "$HOME/Applications/MacEverything.app"
echo "Removed. The index is still in ~/Library/Application Support/MacEverything (delete it to free the space)."
