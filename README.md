# MacEverything

Instant filename search for macOS, modeled on voidtools Everything for Windows.
Every file and folder name lives in memory, so results update on each keystroke.

- **everythingd**: background daemon. Scans with `getattrlistbulk()`, keeps the index current
  with FSEvents, saves it to `~/Library/Application Support/MacEverything/index.bin`, and
  answers queries over a local Unix socket.
- **ev**: command-line search. `ev report 2026`, `ev ext:pdf dm:thisweek`, `ev --status`.
- **MacEverything.app**: menu-bar app. Option-Space opens the search window.

## Install (on the Mac)

```bash
git clone https://github.com/erash11/MacEverything.git
cd MacEverything
./scripts/install.sh
```

Needs Xcode or the Xcode Command Line Tools (`xcode-select --install`), macOS 13 or later.
Then give `~/.local/bin/everythingd` Full Disk Access (the installer prints the steps) and run
`ev --rescan`.

## Query syntax

| Query | Matches |
| --- | --- |
| `report 2026` | names containing both words |
| `"game film"` | exact phrase |
| `a \| b` | either word |
| `!draft` | names without the word |
| `*.pdf`, `IMG_????.jpg` | wildcards on the whole name |
| `ext:mp4;mov` | any listed extension |
| `path:Football` | the word anywhere in the full path |
| `size:>1gb`, `size:<10kb` | file size |
| `dm:today`, `dm:thisweek`, `dm:>2026-10-01` | date modified |
| `regex:^IMG_\d+` | regular expression on the name |
| `file:`, `folder:` | only files or only folders |

## Settings

Optional `~/Library/Application Support/MacEverything/config.json`:

```json
{ "roots": ["/", "/Volumes/Work"], "exclusions": ["/Users/me/node_modules"], "includeExternalVolumes": true }
```

## Develop

`swift build`, `swift test`, `.build/debug/ev --bench ~/Documents`. Design notes: `docs/DESIGN.md`.
