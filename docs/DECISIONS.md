# Decisions

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
