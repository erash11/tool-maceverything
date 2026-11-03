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

### Install the app from CI (when it will not build locally)

Command Line Tools without full Xcode cannot build the SwiftUI app (`SwiftUIMacros` missing).
Every CI run uploads an ad-hoc signed `MacEverything.app` (Apple silicon, macOS 13+) as the
`MacEverything-app` artifact. With `gh` logged in:

```bash
./scripts/install-app-from-ci.sh   # latest green run on main; pass a run ID to pick another
```

It replaces only `~/Applications/MacEverything.app`; `ev` and the daemon stay as built
locally. Artifacts expire after 90 days: `gh workflow run CI -R erash11/MacEverything --ref main`
makes a fresh one.

### Keep Full Disk Access across rebuilds (recommended, once per Mac)

macOS ties Full Disk Access to the code signature. Ad-hoc signatures change with every build,
so the grant is lost each time. Sign with a stable identity instead:

```bash
./scripts/create-signing-cert.sh   # free self-signed certificate; asks for your password once
./scripts/install.sh               # now signs with "MacEverything Local Signing"
```

Grant Full Disk Access one more time after that install; later rebuilds keep it. If a
"Developer ID Application" certificate is in your keychain, `make-app.sh` uses it instead
(needed only to give the app to other Macs). Set `MEV_SIGN_IDENTITY` to choose explicitly, or
`-` for ad-hoc.

## Query syntax

| Query | Matches |
| --- | --- |
| `report 2026` | names containing both words |
| `"game film"` | exact phrase |
| `a \| b` | either word |
| `!draft` | names without the word |
| `<report 2026> \| invoice`, `!<draft old>` | groups (a `>` right after `size:`, `dm:` or `len:` compares: `<size:>1gb>`; end a `regex:` with a space before `>`; at most 256 tests, so `<8 words>\|<8 words>` works and `<16 words>\|<16 words>` doesn't) |
| `*.pdf`, `IMG_????.jpg` | wildcards on the whole name |
| `ext:mp4;mov` | any listed extension |
| `path:Football` | the word anywhere in the full path |
| `drive:CRASHBOX` | only that drive (also the scope menu in the search window) |
| `audio:` `zip:` `doc:` `exe:` `pic:` (or `image:`) `video:` | file types (also the type menu in the search window) |
| `!temp:` | hide temp and generated files: node_modules, .git, build and cache folders, *.tmp, system temp. The search window hides them unless "Show temp files" is ticked |
| `size:>1gb`, `size:<10kb` | file size |
| `dm:today`, `dm:thisweek`, `dm:>2026-10-01` | date modified |
| `regex:^IMG_\d+` | regular expression on the name |
| `file:`, `folder:` | only files or only folders |
| `case:Report` | the word with this exact case |
| `ww:report` | the word as a whole word (`report-2026.pdf`, not `reports.pdf`) |
| `wfn:notes.txt`, `startwith:q1`, `endwith:.txt` | the whole name, its start, its end |
| `len:>200` | names longer than 200 characters |

## Settings

Optional `~/Library/Application Support/MacEverything/config.json`:

```json
{ "roots": ["/", "/Volumes/Work"], "exclusions": ["/Users/me/node_modules"], "includeExternalVolumes": true }
```

Browser and Electron app caches (folders named `Cache_Data`, `Code Cache`, `GPUCache`,
`DawnGraphiteCache`, `DawnWebGPUCache`, `cache2`) are listed but not walked into.
`"excludedNames": [...]` replaces that list; `[]` indexes them again.

Cloud folders in your home folder are listed but not walked into: `~/Library/CloudStorage`
(Google Drive, OneDrive, Dropbox, Box), `~/Library/Mobile Documents` (iCloud) and
`~/Library/Application Support/FileProvider`. Walking them makes the providers fetch and lock
files and fills the daemon log with errors. To index one cloud account anyway, add its folder in
the Locations window (or `"extraRoots"` in config.json); it then gets its own root and watcher.

## Develop

`swift build`, `swift test`, `.build/debug/ev --bench ~/Documents`. Design notes: `docs/DESIGN.md`.
