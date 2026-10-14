# NoBrainer offline checks

Run from the workspace root with `tools\luajit\luajit.exe` (Windows) or `tools/luajit/luajit`.

The solver suites are BetterBrainer's (`mods/active/BetterBrainer/tests/`), pointed at NoBrainer's files by `fixture.lua`. Their coverage, models and limits are described in BetterBrainer's `tests/README.md`. The fixture replaces the servo skull module with an inert one, because it needs engine settings the fixture does not load; `servo_skull_spec.lua` covers that module separately with stubs.

| Command | What it checks | Last result |
|---|---|---|
| `speed_spec.lua` | Receipt gates, press edges, opening timing, full solves | 2026-10-14: 73/73 |
| `search_spec.lua` | Search pre-send, lag safety, reopen mid-solve | 2026-10-14: 21/21 |
| `drill_spec.lua` | Drill aim planner, holds, lag safety | 2026-10-14: 36/36 |
| `scan_marker_spec.lua` | Scan highlight release | 2026-10-14: 4/4 |
| `reopen_spec.lua` | Search transition skip, Symbols reroll, Frequency pipeline | 2026-10-14: 17/17 |
| `servo_skull_spec.lua` | Servo skull ordering through `ctx.settings` and `update(dt, t)` | 2026-10-14: 4/4 |

Offline evidence, not in-game results.
