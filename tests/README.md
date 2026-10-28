# NoBrainer offline checks

Run from the workspace root with `tools\luajit\luajit.exe` (Windows) or `tools/luajit/luajit`.

The solver suites are BetterBrainer's (`mods/active/BetterBrainer/tests/`), pointed at NoBrainer's files by `fixture.lua`. Their coverage, models and limits are described in BetterBrainer's `tests/README.md`. The fixture replaces the servo skull module with an inert one, because it needs engine settings the fixture does not load; `servo_skull_spec.lua` covers that module separately with stubs.

| Command | What it checks | Last result |
|---|---|---|
| `speed_spec.lua` | Receipt gates, press edges, opening timing, full solves | 2026-10-28: 73/73 |
| `search_spec.lua` | Search pre-send, lag safety, reopen mid-solve | 2026-10-28: 21/21 |
| `drill_spec.lua` | Drill aim planner, holds, lag safety | 2026-10-28: 36/36 |
| `scan_marker_spec.lua` | Scan highlight release | 2026-10-28: 4/4 |
| `reopen_spec.lua` | Search transition skip, Symbols reroll (average board and exact boards from a known seed), a replayed old session, the player's own cancel after a re-entry, a terminal on a locked chest, a corrected session that comes back or never does, Frequency pipeline, Drill seed-predicted opening (kept, seed and first-seed boards, a wrong board, quick re-entry, W held, local server) and a Drill re-hack after a decoder interrupt | 2026-10-28: 31/31 |
| `balance_spec.lua` | Balance closed loop against the game's server physics: distance from the centre with kicks, hold without them, over host and 30-250 ms links, late input and quantized samples (thresholds in the file; an optional argument runs another `balance.lua`) | 2026-10-28: 7/7 (1.0.4 solver: 0/7) |
| `servo_skull_spec.lua` | Servo skull ordering through `ctx.settings` and `update(dt, t)` | 2026-10-28: 4/4 |

Offline evidence, not in-game results.
