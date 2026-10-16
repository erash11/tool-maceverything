# 2026-10-16: pick one cloud account in the scope menu

## What and why
Eric asked to search one cloud drive alone (for example only Google Drive) instead of all synced
cloud folders at once. The scope menu now lists each cloud account under "Cloud".

## How it works
- New `SearchScope.cloudFolder(path)` in `Sources/EverythingCore/Scope.swift`. Its query is
  `"path:<folder>/"`, the same form as `.drive`, so it costs nothing extra in the search engine.
- `SearchScope.choices` lists every non-hidden entry of `~/Library/CloudStorage` (sorted), then
  iCloud Drive (`~/Library/Mobile Documents`) when `com~apple~CloudDocs` exists. A `list:` closure
  was added beside `exists:` so tests can fake the folder.
- Titles: `GoogleDrive-me@x.com` -> "Google Drive (me@x.com)", `OneDrive-BaylorUniversity` ->
  "OneDrive (BaylorUniversity)", `Box-Box` -> "Box", `Dropbox` -> "Dropbox". The account stays in
  the title so two accounts from one provider stay apart.
- Saved choice id: `cloud:<path>`. Old saved ids still load.

## Decisions
- OneDrive's standalone Group Containers folder is not its own choice. It holds sync data, not the
  user's files; the overall "Cloud" scope still covers it.
- The menu does not indent the account items: SwiftUI shows the picked title in the closed menu,
  and leading spaces would show there too. The order (right after Cloud) groups them.

## Checks
- `swift build` passes on the Mac (Command Line Tools only; `swift test` needs Xcode, so CI runs
  the tests). CI green, 50 tests, commit after 7755ce5.
- Live `ev` check with the same query text, PDFs only, counts only: Google Drive 55,543,
  OneDrive 20,350, iCloud 43. Zero hits outside each account's folder.
- NOT yet seen in the search window: the installed app is still the old build.

## Files changed
Sources/EverythingCore/Scope.swift, Sources/EverythingApp/EverythingApp.swift (help text and
comment), Tests/EverythingCoreTests/IndexTests.swift, docs/STATUS.md, this file.

## Next
See `docs/STATUS.md` > Next, item 1.
