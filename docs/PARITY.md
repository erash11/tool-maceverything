# MacEverything vs voidtools Everything: feature parity checklist

Checked 2026-11-02 against repo HEAD (`Sources/`, README, docs) and the live daemon (`ev`, 2,586,495 entries).
Everything features come from voidtools' own docs (1.4, plus 1.5 alpha where marked); each section cites its page.

## Summary

**Score: 36 Have / 23 Partial / 55 Missing (114 rows).** Name search speed is at par. Most of the gap is in the search window (keyboard flow, file actions, history) and in the query language past the basics.

The 10 gaps most likely to make it feel broken for someone coming from Everything, worst first:

1. **Fixed 2026-11-03 (PR #13): they now match nothing.** Next step: support these values. Was: **Search terms the parser can't read return everything.** Unparsed values are dropped, so `dm:lastweek`, `dm:7days`, `dm:2026`, `size:10mb..50mb` and `size:huge` each return all 2.59M entries, with no error.
2. **Functions and modifiers it doesn't know become literal text, so they return 0.** `case:`, `parent:`, `ww:`, `dc:`, `empty:`, `type:`, `image:` and `<…>` grouping return 0 results, with no error.
3. **The type, arrow, Enter habit doesn't work.** Down Arrow doesn't move from the search box into the results. Enter opens the first hit alphabetically, not the one you open most.
4. **The list stops at 500 rows.** The window asks the daemon for only 500 results. The status bar can say "1,452,260 objects", but scrolling ends at row 500.
5. **Sorting by anything but Name is slow.** Path, Size and Date sort every match on every keystroke: 2.2 s, 0.5 s and 0.2 s for `a`. Everything keeps fast-sort indexes. Type and Extension can't be sorted at all.
6. **You can't do anything to a file from the results.** There's no rename (F2), no Move to Trash, no drag-out, no cut or paste, and no Get Info. Cmd+C copies path text, not the files.
7. **No search history and no run count.** There's no history dropdown, Ctrl+Space completion, Back/Forward, or "most opened first".
8. **Date search covers only the basics.** It understands today, yesterday, a rolling 7 days, and one exact date. There are no ranges, relative dates or month/year values, and no `dc:`/`da:` (creation and access dates are not stored).
9. **Results are hard to scan.** Matches aren't highlighted, icons are generic, and there's no Quick Look/preview pane.
10. **Matching options are missing.** There's no `case:`, no whole-word, and no accent-insensitive match (`resume` won't find `résumé`). There's also no `< >` grouping and no `parent:`/`depth:`.

Notes on scope:
- **Build status.** The menu-bar app doesn't build on this Mac right now (STATUS Next #2, SwiftUIMacros). The installed app is the 2026-10-16 build, so UI rows describe the source at HEAD. Check them on a rebuilt app.
- **Cloud exclusion gap.** The OneDrive standalone container (`~/Library/Group Containers/UBF8T346G9.OneDriveStandaloneSuite`) is not in `Scanner.cloudExclusions` (Scanner.swift:22-25). `ev --count '"path:/library/group containers/ubf8t346g9.onedrivestandalonesuite/"'` = 164,321 entries are indexed, despite the 2026-10-24 cloud decision.

## Two parse behaviors behind most "it didn't work" moments

| Case | Code | Evidence (live index today) | Test |
| --- | --- | --- | --- |
| A value the parser can't read drops the whole term | `parseSize`/`parseDay` return nil (Query.swift:109, :114, :135-166); `parseTerm` returns nil and line 38 `continue` skips it | `dm:lastweek`, `dm:7days`, `dm:2026`, `dm:2026-10-01..2026-10-15`, `size:10mb..50mb`, `size:empty`, `size:huge` each = 2,586,495 = `ev --count ''` | `ev --count 'dm:lastweek'` equals `ev --count ''` → bug |
| A function or modifier it doesn't know is searched as plain name text | Falls through to `.contains` (Query.swift:123) | `case:Report`, `ww:report`, `wholeword:report`, `nopath:report`, `parent:/Users`, `depth:2`, `empty:`, `dc:today`, `attrib:H`, `dupe:`, `type:pdf`, `stem:report`, `name:report`, `startwith:report`, `len:>200`, `image:`, `<report 2026>\|invoice` all = 0 | `ev --count 'case:Report'` = 0 while `ev --count report` = 5478 → bug |

## 1. Search syntax and operators

Source: [Search Syntax](https://www.voidtools.com/support/everything/search_syntax/), [Searching](https://www.voidtools.com/support/everything/searching/)

| Feature | Everything behavior | MacEverything status | How to test on the Mac |
| --- | --- | --- | --- |
| AND (space) | `abc 123` matches both | **Have**: Query.swift:30-46 (each token is a group, groups ANDed, Search.swift:343-399) | `ev --count 'report 2026'` (176) < `ev --count report` (5478) |
| OR (`\|`) | `abc\|123`; spaces around `\|` ignored | **Have**: Query.swift:34-36, :63-66 | `ev --count 'report\|invoice'` = `ev --count 'report \| invoice'` (5636) |
| NOT (`!`) | `!abc` excludes | **Have**: Query.swift:77-80 | `ev --count '!report'` = total − 5478 |
| Precedence OR before AND | `apple banana \| orange` = apple AND (banana OR orange) | **Have**: Query.swift:39-43 (OR joins into the previous group) | `ev --count 'report 2026 \| invoice'` |
| Grouping `< >` | `!<abc 123>`, `<a b>\|c` | **Missing**: no `<`/`>` in the tokenizer (Query.swift:49-72); treated as literal text | `ev --count '<report 2026>\|invoice'` = 0 |
| Quotes | `"c:\program files\"` is literal, spaces included | **Have**: Query.swift:54-57 | `ev --count '"game film"'` |
| Wildcards `*` `?`, whole-name match | `*.mp3`, `foo*` | **Have**: Query.swift:117-118, Search.swift:426-445 | `ev --count '*.pdf'` (28,295); `ev --count 'report*'` (1412) |
| Wildcards in a path term | `c:\*\downloads\*.pdf`; `**` crosses folders | **Missing**: any `*` makes the term a name-only glob, checked before `/` (Query.swift:117-121) | `ev --count '/downloads/*.pdf'` = 0; workaround `'/downloads/ *.pdf'` = 10 |
| Search a folder by path | `\downloads`, `c:\windows\` (a backslash means full-path match) | **Have** (with `/`): a term containing `/` matches the full path (Query.swift:120-121) | `ev --count '/downloads/'` (1203) |
| Drive filter | `d:`, `c:\|e:`, `!e:` | **Partial**: `drive:NAME` = path contains `/volumes/NAME/` (Query.swift:94-98); scope menu (EverythingApp.swift:234-242). Different syntax. | Plug in a drive, then `ev --count 'drive:CRASHBOX'`; or use the scope menu |
| Built-in macros | `audio: doc: exe: image: video: zip:` | **Partial**: `audio: zip: doc: exe: pic: video:` (Scope.swift:120-130, Query.swift:87-89); Everything's `image:` is not recognized | `ev --count 'image:'` = 0 vs `ev --count 'pic:'` = 84,918 |
| Regex | `regex:^IMG_\d+`, quoted patterns with spaces | **Have**: Query.swift:103-106, Search.swift:107-121 (always case-insensitive) | `ev --count 'regex:^IMG_\d+'` (7038) |
| Search as you type | Results update on each keystroke | **Have**: EverythingApp.swift:109 (`didSet { run() }`) | Type in the window and watch the count change |
| Feedback on bad syntax | Invalid input is reported or matched literally | **Missing**: see "Two parse behaviors" above | `ev --count 'dm:lastweek'` |
| Character entities | `&sp:`, `&excl:`, `&quot:` (1.5) | **Missing**: no handling in Query.swift | `ev --count '&excl:readme'` |

## 2. Search options, modifiers and functions

Source: [Search Modifiers](https://www.voidtools.com/support/everything/search_modifiers/), [Search Functions](https://www.voidtools.com/support/everything/search_functions/), [Searching: Search options](https://www.voidtools.com/support/everything/searching/#options)

| Feature | Everything behavior | MacEverything status | How to test on the Mac |
| --- | --- | --- | --- |
| `case:` / Match Case (Ctrl+I) | Case-sensitive per term or globally | **Missing**: names are matched only in lowercase form (FileIndex.swift:143-144); regex is compiled `.caseInsensitive` (Search.swift:109) | `ev --count 'case:Report'` = 0 |
| Diacritics (Ctrl+M; default ignores accents) | `resume` finds `résumé` unless Match Diacritics is on | **Missing**: lowercased and precomposed, not accent-folded (FileIndex.swift:143-144), so it always matches accents exactly | Create nothing; on a known accented file name, search without accents |
| `ww:` / whole words (Ctrl+B) | Matches whole words only | **Missing**: literal text | `ev --count 'ww:report'` = 0 |
| `path:` modifier / Match Path (Ctrl+U) | Match the term against the full path; global toggle | **Partial**: `path:text` = substring of the full path (Query.swift:99-102, PathTable); no global toggle, no `no-path:`, no wildcards in `path:` | `ev --count 'path:football'` (72,288); `ev --count 'path:*.pdf'` = 0 |
| Prefix / suffix / `startwith:` / `endwith:` / `whole:` (`wfn:`) | Anchor the match to word or name start/end | **Missing**: literal text; `report*` (glob) is the only stand-in for "starts with" | `ev --count 'startwith:report'` = 0 |
| Ignore punctuation / white-space (1.5) | `spiderman` finds `spider-man` | **Missing** | `ev --count 'nopunc:spiderman'` = 0 |
| `file:` / `folder:` | Files or folders only | **Have**: Query.swift:84-85, Search.swift:387-392 | `ev --count file:` (2,083,335); `ev --count folder:` (503,160) |
| `ext:` | `ext:pdf;docx` | **Have**: Query.swift:90-93 | `ev --count 'ext:pdf;docx'` (30,267) |
| `size:` with `< > <= >= =` and kb/mb/gb/tb | `size:>1gb` | **Have**: Query.swift:107-111, :126-145 | `ev --count 'size:>1gb'` (33) |
| `size:` ranges | `size:10mb..50mb` | **Missing**: the term is dropped, so it returns the whole index | `ev --count 'size:10mb..50mb'` = 2,586,495 |
| `size:` constants | `empty tiny small medium large huge gigantic unknown` (1.4 in-app syntax help) | **Missing**: dropped, returns everything | `ev --count 'size:huge'` = 2,586,495 |
| `dm:` today / yesterday / exact date / comparisons | `dm:today`, `dm:>2022` | **Have** for `today`, `yesterday`, `YYYY-MM-DD` and comparisons on those: Query.swift:112-116, :148-166 | `ev --count dm:today`; `ev --count 'dm:>2026-10-01'` |
| `dm:thisweek` | Calendar week | **Partial**: `thisweek` and `last7days` both mean a rolling 7 days (Query.swift:156-158) | `ev --count dm:thisweek` |
| Other `dm:` values | `lastweek thismonth lastmonth thisyear`, month and day names, `mtd ytd`, `7days`, `2hours`, `YYYY`, `YYYY-MM`, ranges `a..b`, times | **Missing**: dropped, returns everything | `ev --count 'dm:2026'` = 2,586,495 |
| `dc:` date created | Created date | **Missing**: not stored. `Record` has only `modified` (FileIndex.swift:19-27) and the scanner asks only for `cmnModTime` (Scanner.swift:103). Needs an index format change. | `ev --count 'dc:today'` = 0 |
| `da:` date accessed, `rc:` recently changed | Accessed date, recent-change date | **Missing**: same as `dc:` | `ev --count 'da:today'` |
| `attrib:` | Hidden, system, read-only… | **Missing**: flags hold only directory/deleted (FileIndex.swift:25) | `ev --count 'attrib:H'` = 0 |
| `parent:` | Direct children of a folder | **Missing**: literal text. `"path:/x/y/"` returns every descendant, not only direct children. | `ev --count 'parent:/Users'` = 0 |
| `depth:` / `parent-count:` | Folder depth | **Missing** | `ev --count 'depth:2'` = 0 |
| `child:`, `childcount:`, `empty:` | Folders by what they contain | **Missing**: the child map exists (FileIndex.swift:99) but there's no query term | `ev --count 'empty:'` = 0 |
| `dupe:` (1.5) | Duplicate names, sizes, etc. | **Missing** | `ev --count 'dupe:'` = 0 |
| `content:` | Search file text | **Missing** | `ev --count 'content:invoice'` |
| `len:` | Name length | **Missing** | `ev --count 'len:>200'` = 0 |
| `type:`, `name:`, `stem:`, `extension:`, `full-path:` | Property text matches | **Missing**: all literal text | `ev --count 'type:pdf'` = 0 |
| `regex:` | PCRE on the name | **Have** (ICU, not PCRE): see section 1 | `ev --count 'regex:^IMG_\d+'` |

## 3. Results window

Source: [Results](https://www.voidtools.com/support/everything/results/), [Keyboard Shortcuts](https://www.voidtools.com/support/everything/keyboard_shortcuts/)

| Feature | Everything behavior | MacEverything status | How to test on the Mac |
| --- | --- | --- | --- |
| All matches scrollable | A virtual list holds every result | **Partial**: the app requests `limit: 500` (EverythingApp.swift:182); the status bar shows the true total (:192) | Type `a`: footer says ~1.45M objects; scroll to the end and it stops at 500 rows |
| Default columns | Name, Path, Size, Date Modified | **Partial**: Name, Type, Path shown; Size and Date Modified exist but are hidden by default (EverythingApp.swift:295-310) | Right-click a header and tick Size and Date Modified |
| More columns: Extension, Full Path, Type | Any property as a column | **Have**: EverythingApp.swift:298, :311-319 | Right-click a header |
| Date Created / Accessed / Attributes / Run Count columns | Available | **Missing**: not indexed (FileIndex.swift:19-27) | n/a |
| Show/hide, reorder, remember columns | Right-click header, drag | **Have**: EverythingApp.swift:222, :280-288 (macOS 14+) | Drag a header, close and reopen |
| Click header to sort (Name, Path, Size, Date Modified) | Sort, click again to reverse | **Have**: EverythingApp.swift:376-393, Search.swift:157-174 (sorted by the daemon across all matches) | Click Size twice |
| Sort by Type / Extension | Yes (Ctrl+4, Ctrl+5) | **Missing**: those columns have no `value:` (EverythingApp.swift:298, :311); STATUS Next #5 | Click the Type header: nothing happens |
| Sort shortcuts Ctrl+1…9 | Sort by name, path, size… | **Missing** | Press Cmd/Ctrl+1 |
| Folder sizes in the Size column | Shown when folder size indexing is on | **Missing**: folders have size 0 and show "" (Scanner.swift:94, :179; EverythingApp.swift:351) | Show Size, search `folder:` |
| File icons / thumbnails | Shell icons; thumbnail views | **Partial**: generic SF Symbols `folder`/`doc` (EverythingApp.swift:340); no thumbnails | Look at a .pdf row |
| Highlight matched text | Bold match in the name (1.5) | **Missing**: plain `Label` (EverythingApp.swift:339-341) | Search `report` |
| Down/Up Arrow from search box into results | Focuses the list | **Missing**: no key handling on the TextField (EverythingApp.swift:243-247) | Type, press Down |
| Tab between search box and results | Cycles focus | **Partial**: no code; depends on SwiftUI's default focus loop and macOS Keyboard Navigation | Type, press Tab, then arrows |
| Enter in search box | Focus list, select item with highest run count | **Partial**: opens the selection, or the first hit in name order (EverythingApp.swift:247, :403-409) | Type, press Return |
| Open result (Enter / double-click) | Opens with default app | **Have** for double-click: `primaryAction` (EverythingApp.swift:398-400); Return inside the table is untested | Double-click a row; select a row and press Return |
| Ctrl+Enter: open the folder | Opens containing folder, selects file | **Partial**: "Reveal in Finder" in the context menu only (EverythingApp.swift:396, :415-416); no shortcut | Right-click > Reveal in Finder; try Cmd+Return |
| Multi-select (Shift/Cmd-click, Shift+arrows, select all) | Yes | **Have**: `Table(selection: Set)` (EverythingApp.swift:217, :293) | Shift-click two rows |
| Ctrl+C copies the files; Ctrl+Shift+C copies full paths | Files paste into Explorer | **Partial**: Cmd+C copies full paths as text (EverythingApp.swift:272-275); "Copy Path" menu item (:397, :422-425); files can't be pasted into Finder; no copy-name | Select, Cmd+C, paste in Finder (nothing) and in a text field (paths) |
| Rename in place (F2) and multi-file rename | Yes | **Missing** | Select a row, press Return or F2 |
| Delete (to Trash) / Shift+Delete | Yes | **Missing** | Select, press Cmd+Delete |
| Cut / paste into a folder (Ctrl+X / Ctrl+V) | Yes | **Missing** | n/a |
| Drag results out to Finder or other apps | Yes | **Missing**: no `.draggable`/`.onDrag` in Sources/ | Drag a row onto the Desktop |
| Context menu | Full Explorer shell menu | **Partial**: Open, Reveal in Finder, Copy Path only (EverythingApp.swift:394-397) | Right-click a row |
| Properties (Alt+Enter) → Get Info | Yes | **Missing** | n/a |
| Preview pane (Alt+P) → Quick Look | Yes | **Missing**: no QuickLook code | Select, press Space |
| Status bar result count | "N objects" | **Have**: EverythingApp.swift:192, :261 (plus search ms) | Look at the footer |
| Selected-items count in status bar | "N objects, M selected" | **Missing** | Select 3 rows |
| Jump-to by typing in the list | Type a name start to jump | **Missing**: no code (native NSTableView type-select may or may not apply) | Click the list, type letters |
| Export results (Ctrl+S, CSV/TXT/EFU) | Yes | **Partial**: `ev -n 0 query > file.txt` or `ev --json` (ev/main.swift:23-29); nothing in the UI | `ev -n 0 --long 'ext:pdf' > ~/Desktop/out.txt` (pick a non-cloud query) |

## 4. Filters and bookmarks

Source: [Searching: Filters, Bookmarks, Macros](https://www.voidtools.com/support/everything/searching/#filters)

| Feature | Everything behavior | MacEverything status | How to test on the Mac |
| --- | --- | --- | --- |
| Built-in filters (Audio, Compressed, Document, Executable, Folder, Picture, Video) | Search menu, filter bar | **Have**: Scope.swift:112-159; type menu EverythingApp.swift:248-256 | Pick "Video" in the type menu |
| Active filter remembered | Yes | **Have**: UserDefaults (EverythingApp.swift:132-138) | Pick a filter, close, reopen |
| Edit filters / add custom filters (Organize Filters) | Yes | **Missing**: extension lists hard-coded (Scope.swift:137-159) | n/a |
| Filter bar / filters sidebar (1.5) | Yes | **Missing**: menu only | n/a |
| Result omissions (hide paths) | Index > Result Omissions | **Have** (analog): `!temp:` and the "Show temp files" toggle (Temp.swift, EverythingApp.swift:141-147, :263) | `ev --count '!temp:'` |
| Bookmarks (save search + filter + sort + columns; Ctrl+D) | Yes | **Missing** | n/a |
| Custom macros on filters/bookmarks | `mymacro:` | **Missing** | n/a |
| Scope by location | `c:`, folder bookmarks | **Have** (extra): scope menu All / This Mac / Cloud / each drive (Scope.swift:5-100, EverythingApp.swift:234-242). Cloud scopes now return 0 unless the account is added as a location (STATUS Next #1). | Pick a drive in the scope menu |

## 5. Search history and run count

Source: [Search History](https://www.voidtools.com/support/everything/search_history/), [Run History](https://www.voidtools.com/support/everything/run_history/), [Keyboard Shortcuts](https://www.voidtools.com/support/everything/keyboard_shortcuts/)

| Feature | Everything behavior | MacEverything status | How to test on the Mac |
| --- | --- | --- | --- |
| Search history recorded on Enter or when a result is opened | Yes (opt-in) | **Missing**: nothing in Sources/ | n/a |
| History dropdown, Alt+Up/Down | Yes | **Missing** | n/a |
| Ctrl+Space completion from history | Yes | **Missing** | n/a |
| Back / Forward (Alt+Left/Right) | Yes | **Missing** | n/a |
| Last search kept between openings | Home search / restore session | **Partial**: query text stays while the app runs (one `SearchModel`, EverythingApp.swift:28); scope and filter persist (:126, :135); query text is lost on app restart | Search, Esc, Option-Space: text still there; quit and relaunch: gone |
| Run count increments on open | Yes | **Missing** | n/a |
| Sort by run count; Enter picks most-run | Yes | **Missing** | n/a |
| `runcount:`, `dr:` (date run) | Yes | **Missing** | `ev --count 'runcount:>1'` = literal |

## 6. Indexing

Source: [Indexes](https://www.voidtools.com/support/everything/indexes/), [Folder Indexing](https://www.voidtools.com/support/everything/folder_indexing/)

| Feature | Everything behavior | MacEverything status | How to test on the Mac |
| --- | --- | --- | --- |
| Live updates (NTFS USN journal) | Real time | **Partial**: FSEvents, 0.3 s latency (Watcher.swift:78) + 0.2 s batch (Service.swift:350-353); folder re-list and diff. A missed bulk change was seen on 2026-11-02, "intermittent" (scripts/parity_check.py:22). | `python3 -I scripts/parity_check.py` (writes only `~/MacEverything-paritytest`; another agent is running it now) |
| Catch up after restart without rescan | USN journal replay | **Have**: saves volume UUID + last event id, resumes FSEvents from it (DESIGN.md step 5; Service.swift:153-168) | Restart the daemon; `ev --status` shows no scan |
| Index the system disk automatically | All fixed NTFS/ReFS volumes | **Have**: `/` default root (Service.swift:136-147) | `ev --status` roots |
| External drives: auto-include, plug/unplug | Removable NTFS opt-in; FAT/exFAT via folder indexing | **Have**: local `/Volumes/*` auto-added (Service.swift:136-147); new drive found within 30 s (everythingd/main.swift:57-66); returning drive re-listed (Service.swift:474-486). exFAT has no FSEvents history, so it's rescanned at every start (STATUS). | Plug in a drive, wait 30 s, `ev --status` |
| Network shares | Folder index: monitor changes + daily rescan | **Partial**: not auto-added (`volumeIsLocal` filter, Service.swift:142); can be added in Locations / `extraRoots` (EverythingApp.swift:443-452). FSEvents doesn't see changes made from other machines, and there's no scheduled rescan. | Mount an SMB share, add it in Locations, change a file from another machine |
| Scheduled rescan of folder indexes | Daily / interval | **Missing**: manual only (menu "Rebuild Index" EverythingApp.swift:20, `ev --rescan`) | n/a |
| Exclude folders / files | Folder list, wildcard and `regex:` filters, hide hidden/system | **Partial**: config.json `exclusions` (full paths) and `excludedNames` (exact folder names) (Service.swift:8, :47-50; Scanner.swift:30-33); no UI, no wildcards, no hidden/system switch | Edit `~/Library/Application Support/MacEverything/config.json` |
| Cloud folders not walked by default | n/a (Mac-specific) | **Partial**: CloudStorage, Mobile Documents, FileProvider excluded (Scanner.swift:22-25), but the OneDrive standalone group container is not: 164,321 entries indexed | `ev --count '"path:/library/group containers/ubf8t346g9.onedrivestandalonesuite/"'` |
| Index file size and date modified | Yes | **Have**: `Record.size`, `.modified` (FileIndex.swift:26-27) | `ev --long 'size:>1gb'` (non-cloud query) |
| Index folder sizes | Option | **Missing**: folders stored as 0 (Scanner.swift:94, :179) | `ev --long folder: -n 5` shows `<dir>` |
| Index date created / accessed / attributes | Options | **Missing**: not in `Record` (FileIndex.swift:19-27) | n/a |
| Fast sort indexes (size, date, path, extension) | Options | **Missing**: only name has a presorted order (FileIndex.swift:42; Search.swift:158-159); others sort per query (Search.swift:160-173) | See Speed |
| Force rebuild | Index > Force Rebuild | **Have**: EverythingApp.swift:20, `ev --rescan` (ev/main.swift:198-202) | Menu bar > Rebuild Index |
| Add/remove indexed locations in a UI | Options > Folders | **Have** in source: Locations window (EverythingApp.swift:428-530); the installed 10-16 app uses older exclusions (STATUS) | Menu bar > Locations… |

## 7. Global hotkey and window behavior

Source: [Keyboard Shortcuts: Hotkeys, Global](https://www.voidtools.com/support/everything/keyboard_shortcuts/)

| Feature | Everything behavior | MacEverything status | How to test on the Mac |
| --- | --- | --- | --- |
| System-wide hotkey | Configurable | **Partial**: Option-Space via Carbon (EverythingApp.swift:50, :84-106), hard-coded, no setting | Press Option-Space in any app |
| Hotkey "toggle window" method | Hide if in front, else show | **Have**: EverythingApp.swift:55-61 | Press Option-Space twice |
| Hotkey "new window" method, Ctrl+N, tabs (1.5) | Yes | **Missing**: one panel (EverythingApp.swift:27, :64-76) | n/a |
| Esc / Ctrl+W closes the window | Yes | **Partial**: Esc hides (EverythingApp.swift:271); no Cmd+W handling beyond the panel's close button | Press Esc; press Cmd+W |
| Focus and select the search text on show (F3/Ctrl+F) | Yes | **Partial**: focus set `onAppear` (EverythingApp.swift:270), which fires on first show; no select-all; no Cmd+F | Search, Esc, Option-Space, type: does it replace the old text? |
| Always on top toggle (Ctrl+T) | Toggle | **Partial**: always floating (EverythingApp.swift:69-70), no toggle | n/a |
| Runs in background, tray icon, starts at login | Yes | **Have**: menu-bar extra (EverythingApp.swift:16-23); login item since 2026-11-02 (STATUS, scripts/install.sh) | Log out and in; check the menu bar |
| Window size and position remembered | Yes | **Missing**: `p.center()` on creation, no frame autosave (EverythingApp.swift:64-76) | Move the window, quit, relaunch |
| Options window | Tools > Options | **Missing**: config.json and Locations only | n/a |
| Sort / match-case / regex toggles by shortcut (Ctrl+1…9, Ctrl+I, Ctrl+B, Ctrl+U, Ctrl+R) | Yes | **Missing** | n/a |

## 8. Speed

Source: [Indexes (fast sort)](https://www.voidtools.com/support/everything/indexes/), [Searching](https://www.voidtools.com/support/everything/searching/). Measured today on the Mac, 2.59M entries, daemon time from `ev --json`.

| Feature | Everything behavior | MacEverything status | How to test on the Mac |
| --- | --- | --- | --- |
| Name search per keystroke | Instant | **Have**: `a` 20 ms, `report` 17 ms, `report 2026` 16 ms, `*.pdf` 29 ms, `regex:^IMG_\d+` 18 ms, `report !temp:` 20 ms, `dm:thisweek` 6 ms, `size:>1gb` 5 ms | `ev --json -n 1 report`, read `milliseconds` |
| Path and filter searches | Instant | **Have**: `path:football` 53 ms, `video:` 50 ms | `ev --json -n 1 path:football` |
| Sorted by Path / Size / Date while typing | Instant with fast sort | **Partial**: `a` with 500 rows: path 2,159 ms, size 504 ms, modified 216 ms (Search.swift:160-173 sorts every match) | `ev --json -n 500 --sort path a` |
| First full index | ~1 min per million files (NTFS) | **Have**: 122 s for 3.21M entries (STATUS 2026-10-24) | `ev --rescan`, then `ev --status` |
| Memory | Low | **Have**: 186 MB for 2.58M entries (`ev --status`) | `ev --status` |

## Out of scope

Everything Server/ETP, HTTP server, Everything Service, SDK/IPC API, file lists (.efu), plugins, multiple instances, pinyin/soundex, media/EXIF/document property functions (`width:`, `length:`, `artist:`…), hashes (`md5:`, `crc32:`), Windows-only properties (alternate data streams, file ID, owner), UI-layout functions (`columns:`, `sort:`, `layout:`).
