# Decisions

## 2026-10-24: Cloud folders are not indexed by default
Replaces the 2026-10-16 choice to exclude nothing. `~/Library/CloudStorage` (the Google Drive
FUSE mount and OneDrive), `~/Library/Mobile Documents` (iCloud) and
`~/Library/Application Support/FileProvider` are now default exclusions. Reason: live updates
kept re-listing them and failing (Drive's `.tmp` folder, File Provider's `wharf/propagate`
folders answering "Resource deadlock avoided"), which wrote about 27,000 "giving up" lines
(5.5 MB) to `~/Library/Logs/everythingd.log` in eight days, and reading the Drive mount can hang.
They held about 887K of the 4.1M entries. Opt back in per account with Locations > Add
(`extraRoots`). Made in the 2026-10-24 agent-setup cleanup run ("stop everythingd crawling
Drive"); the scope menu still lists the cloud accounts (see `docs/STATUS.md` Next).

## 2026-10-16: Keep building MacEverything (#9)
Eric decided not to buy a third-party search app (Find Any File, ProFind, HoudahSpot) and to keep
building MacEverything. Reasons on record: it is the only option that updates results on every
keystroke, uses Everything's query syntax, and has a CLI (`ev`) for scripts and Claude. The
comparison and trial plan are on issue #9.

## 2026-10-16: Folder walk stays the default scanner (#6)
`searchfs()` measured about 10% faster for the first scan but reads whole volumes, so `/` would
need System/Data firmlink mapping and exclusions applied afterwards. The gain only affects the
first scan. Kept as `ev --bench-searchfs`.

## 2026-10-15: Unix socket instead of XPC
Clients talk to `everythingd` over a JSON-line Unix socket. No launchd Mach service
registration, and it is easy to test. See `docs/DESIGN.md`.
