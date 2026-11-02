#!/bin/bash
# Installs the menu-bar app built by GitHub Actions into ~/Applications, for a Mac whose
# toolchain cannot build it (see docs/STATUS.md Gotchas). Leaves ev and the daemon alone.
# Needs gh, logged in. Optional argument: a CI run ID (default: the latest green run on main).
set -euo pipefail
REPO=erash11/MacEverything
ARTIFACT=MacEverything-app
APP="$HOME/Applications/MacEverything.app"

RUN_ID="${1:-$(gh run list -R "$REPO" -w CI -b main -s success -L 1 --json databaseId -q '.[0].databaseId')}"
[ -n "$RUN_ID" ] || { echo "No successful CI run on main." >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
if ! gh run download "$RUN_ID" -R "$REPO" -n "$ARTIFACT" -D "$WORK/dl"; then
  echo "Run $RUN_ID has no $ARTIFACT artifact (artifacts expire after 90 days)." >&2
  echo "Start a new build: gh workflow run CI -R $REPO --ref main, then run this again." >&2
  exit 1
fi
ditto -x -k "$WORK/dl/MacEverything.app.zip" "$WORK/app"
codesign --verify --deep --strict "$WORK/app/MacEverything.app"

# Quit the running app before replacing it (only if running, so osascript does not launch it).
if pgrep -xq MacEverything; then
  osascript -e 'quit app "MacEverything"' 2>/dev/null || true
  for i in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -xq MacEverything || break
    sleep 0.5
  done
fi

# rm first, so the copy is a new bundle rather than a rewrite of the old one. The login item
# is keyed by this path, so it keeps working.
mkdir -p "$HOME/Applications"
rm -rf "$APP"
ditto "$WORK/app/MacEverything.app" "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
codesign --verify --deep --strict "$APP"
open "$APP"
echo "Installed $APP from CI run $RUN_ID (https://github.com/$REPO/actions/runs/$RUN_ID)."
