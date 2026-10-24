# NoBrainer design notes

## Structure (4.1.0)

NoBrainer is BetterBrainer, imported as a git submodule, plus NoBrainer's own features: Smart Seed Reroll and the Skitarius servo-skull command (user decision, 2026-10-24). Design, mechanisms and source contracts of the solvers are in `BetterBrainer/DESIGN.md`; this file covers only what NoBrainer adds.

- `BetterBrainer/`: the BetterBrainer repository as a submodule, installed inside NoBrainer's folder. NoBrainer never edits it: change BetterBrainer upstream, then move the submodule to that commit.
- `import.lua`: runs one BetterBrainer file as part of NoBrainer. While it runs, `get_mod("BetterBrainer")` returns NoBrainer, and the file's `mod:io_dofile("BetterBrainer/scripts/mods/BetterBrainer/<name>")` loads resolve inside the submodule. A caller can take over such a nested load. Imports nest, and each one restores what it replaced.
- `NoBrainer.lua`: migrates 3.1-era speed settings once (`_speed_schema_v2`), then imports `BetterBrainer.lua`. Two nested loads are taken over: `BetterBrainer_data` becomes `NoBrainer_data`, so the core reads NoBrainer's options too, and `symbols` is built with Smart Seed Reroll's context and wrapped by it. The core's context is captured there. Afterwards NoBrainer wraps the core's `update`, `on_setting_changed`, `on_enabled`, `on_disabled`, `on_game_state_changed` and `on_unload` for the servo skull.
- `NoBrainer_data.lua`, `NoBrainer_localization.lua`: import BetterBrainer's options and strings, then add NoBrainer's. Options: the servo skull group after `language`, and `enable_decode_smart_reroll` after `decode_reroll_limit`.
- `seed_reroll.lua`: Smart Seed Reroll (below).
- `servo_skull.lua`: the servo-skull command as a core module (`update(dt, t)`, `reset`, `settings_changed`). It reads `ctx.settings`; its logic is unchanged from 3.2.0.

Never enable NoBrainer and BetterBrainer together: both automate the same input. BetterBrainer's own `.mod` inside the submodule is not loaded, because DMF only loads folders listed in `mod_load_order.txt`.

## Smart Seed Reroll

Every board a terminal deals follows from one seed: `setup_game` shuffles the symbols and draws the targets from `self._seed` and keeps the seed it leaves behind (minigame_decode_symbols.lua:93-141, table.lua:781-797). With that seed known, every board a reroll will deal is known in advance.

- Seed: the host reads `mg._seed`. A client gets no seed (minigame_system.lua:33). It tracks `level_seed + n` for the n-th minigame extension added (minigame_system.lua:61-71), then looks for its board among the first 256 boards that seed deals. It uses the seed only if exactly one board matches. After one of our rerolls, the new board must equal the predicted one.
- Decision: once per board, where BetterBrainer's Symbols reroll reads `decode_reroll_limit`, which is at its first synchronized frame before any press. That read goes through a settings proxy in the context Symbols was built with. With the seed known, the remaining known boards are valued backwards with BetterBrainer's own cost model (`press_time`/`board_cost`, copied), its 0.15 s margin and its measured reopen delay. The board is rerolled only if they are expected to be faster, and BetterBrainer gets limit 0 for that board. Without a known seed, BetterBrainer gets the rest of the limit and its average-board reroll decides as before.
- A reroll goes through the core's `ctx.request_reopen`. Until the solver resumes in the new session, the wrapper holds presses. A reroll the terminal cannot take yet is retried until the board's first press, like BetterBrainer's own.
- Limit: `decode_reroll_limit` caps both kinds together per hack. BetterBrainer's own rerolls are counted through the proxy's `request_reopen`.
- Defaults: `enable_decode_smart_reroll` on, `decode_reroll_limit` 0 (BetterBrainer's default), so no reroll happens until the user sets a limit.

## Decisions

- 2026-10-24 (user): BetterBrainer's features come from the BetterBrainer submodule instead of copies. NoBrainer's own features (Smart Seed Reroll, servo skull) are implemented in this repository on top of it.
  - Smart Seed Reroll returns. It replaces 3.2.0's implementation, which used the removed legacy input route, with a wrapper around BetterBrainer's Symbols solver and reopen controller. The setting id `enable_decode_smart_reroll` is kept. Its 3.2.0 cap of two rerolls is replaced by `decode_reroll_limit`.
  - The copied BetterBrainer test suites are removed. `tests/betterbrainer_suites.lua` runs the submodule's suites, unchanged, through NoBrainer's core instead (`tests/fixture.lua`, on the historical `tests/better_brainer_spec.lua` from the BetterBrainer workspace).
- 2026-10-14 (user): replace every NoBrainer solver with BetterBrainer's current version. Keep the servo skull feature. Setting ids are shared with BetterBrainer, so saved values carry over.

## Runtime status

- Offline: `tests/README.md`. BetterBrainer's own suites pass through NoBrainer's core (`tests/betterbrainer_suites.lua`).
- In game: NoBrainer 4.1.0 is not tested. In particular, the client seed reconstruction depends on clients adding minigame extensions in the server's order. When that fails, the seed is not found and the average-board reroll is used.
- Smallest test, with DMF debug logging on and `Reroll Slow Boards` at 2 or more:
  1. As host (solo), hack Decode Symbols terminals: expect `Seed board kept (host seed)` or `Seed board rerolled (host seed)` lines; after a reroll, `(predicted seed)`.
  2. As a client, the same: expect `(rebuilt seed)`, or `seed unknown (...)` and BetterBrainer's `Symbols board kept/reroll` lines when no seed is found.
  3. As Skitarius with the hacking servo skull, walk within 25 m of a hackable terminal: the skull should be ordered to it.

## Open items

- 2026-10-14: `NoBrainerDebug` read the old solvers through `mod._frame_snapshot()`, which no longer exists. The companion needs updating before it can observe 4.x; it never ships.
- `.github/workflows/release.yml` is generated from a workspace template; the submodule checkout and payload lines added here must also go into that template.
