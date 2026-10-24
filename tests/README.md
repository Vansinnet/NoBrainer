# NoBrainer offline checks

Run from the repository root with LuaJIT (`luajit tests/<suite>.lua`).

| Command | What it checks | Last result |
|---|---|---|
| `betterbrainer_suites.lua` | BetterBrainer's own suites (`BetterBrainer/tests/*_spec.lua`, unchanged) run through NoBrainer's core, import and Symbols wrapper; see below | 2026-10-24: speed 73/73, search 21/21, drill 36/36, scan_marker 4/4, reopen 17/17 |
| `nobrainer_spec.lua` | Import of BetterBrainer's core, data and localization through a DMF stub; option and string placement; Smart Seed Reroll with a host seed, a predicted board after a reroll, a client seed rebuilt from the level seed, and BetterBrainer's own reroll when it is off | 2026-10-24: 136/136 |
| `servo_skull_spec.lua` | Servo skull ordering through `ctx.settings` and `update(dt, t)` | 2026-10-24: 4/4 |

## BetterBrainer's suites through NoBrainer

`luajit tests/betterbrainer_suites.lua` runs all of them; name suites to run only those (`speed`, `search`, `drill`, `scan_marker`, `reopen`). Each suite runs from the submodule unchanged, except that it loads `tests/fixture.lua` instead of BetterBrainer's fixture. Their coverage, models and limits are described in `BetterBrainer/tests/README.md`.

`tests/fixture.lua` is BetterBrainer's `tests/fixture.lua` with these differences:
- It loads NoBrainer's core, which imports BetterBrainer's files from the submodule.
- The game source comes from `darktide_source.lua`.
- The fixture's mod is a DMF-like class instance, so `import.lua` can redirect its `io_dofile` as it does DMF's.
- The servo skull is replaced by an inert module, because it needs engine settings the fixture does not load.

Like BetterBrainer's fixture, it builds on `better_brainer_spec.lua`, the historical BetterBrainer suite. Only the fixture half of that file is used; its own suite is never run.

Smart Seed Reroll is on in these runs, at its default. The reopen suite's local-server Symbols case uses the host seed: mean solve 3.719 s, against 4.003 s with BetterBrainer's own reroll (2026-10-24). The fixture's client terminals are not created through `MinigameSystem` with a level seed, so client cases use BetterBrainer's own reroll. `nobrainer_spec.lua` covers the client seed instead.

## Darktide source

The mod never needs the game source; only the tests do. `darktide_source.lua` fetches the files a suite asks for from [Aussiemon/Darktide-Source-Code](https://github.com/Aussiemon/Darktide-Source-Code), at a pinned commit (1.13.4), into `tests/.darktide-source/` (git-ignored). The fetch is sparse and partial: only the files used are downloaded. The first run of all suites fetches about 30 files, file by file. It needs `git` and network access; later runs reuse the checkout.

To use an existing checkout instead, set `DARKTIDE_SOURCE` to its root, for example `$env:DARKTIDE_SOURCE = "D:\Darktide-Source-Code"`. It is read as is, at whatever version it is.

`nobrainer_spec.lua` builds its boards with the game's `MinigameDecodeSymbols.setup_game`, `table.shuffle` and minigame settings. In every suite, `math.next_random` is native to the engine, so a stand-in generator replaces it, and board costs are not the game's. These are offline results, not in-game results.
