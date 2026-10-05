# NoBrainer offline tests

Run from the workspace root with the workspace LuaJIT (`tools\luajit\luajit.exe` on Windows, `tools/luajit/luajit` on Linux). Each prints `RESULT n passed, m failed`. All results are offline evidence against the Darktide 1.13.0 Lua source, not in-game tests.

| Command | Covers | Last result (2026-10-05) |
|---|---|---|
| `mods/active/NoBrainer/tests/search_spec.lua` | Decode Search: pre-send, recentre on reopen, server input-state gate, stalls, late receipts | 21/21 |
| `mods/active/NoBrainer/tests/drill_spec.lua` (about 60 s) | Drill: aim planner, held first move, acknowledgement, lost-move retry, stalls, high ping | 36/36 |
| `mods/active/NoBrainer/tests/speed_spec.lua` | Search and Symbols speed/receipt cases and full native solves | 56/56, 17 BetterBrainer-only Frequency/Scan cases skipped |
| `mods/active/NoBrainer/tests/nobrainer_spec.lua` | Smart Seed Reroll with the Symbols solver; Frequency opening receipts, opening delay and quick restart | 7/7 |
| `mods/active/NoBrainer/tests/scan_retry_spec.lua` | Auto-scan retry after an interrupted confirm | 3/3 |

## Fixture

`fixture.lua` adapts BetterBrainer's `tests/fixture.lua` (itself built on the historical fixture in `tools/tests/better_brainer_spec.lua`) to load `NoBrainer.lua`: the real input, character-state, minigame and RPC source files run, with mocked native services, DMF registration and a queued transport. The server runs client frame n at tick n + 3 and reports its per-tick input state behind the frame's RPCs. Servo skull, Scan and Balance hook engine classes the fixture does not load and are skipped; Frequency, Smart Seed Reroll and the legacy input route load. `search_spec.lua`, `drill_spec.lua` and `speed_spec.lua` are BetterBrainer 1.0.3's specs pointed at this fixture (speed_spec skips the cases for BetterBrainer's own Frequency and Scan). In the fixture Smart Seed Reroll has no level seed, so it decides statistically; the seed-predicted fast sync is not exercised there.

`scan_retry_spec.lua` loads `NoBrainer_input.lua` and `NoBrainer_minigame_scan.lua` against a small mock of DMF, the player and the scanner components.

# Decode Symbols reroll phase harness

Run from the NoBrainer mod root:

```powershell
& "..\..\..\tools\luajit\luajit.exe" tests\decode_symbols_reroll_phase_harness.lua 20000 1 0.22
```

Arguments: trials, seed, real retry cost in seconds. `NB_RANDOM_PHASE=1` replays the 1.12.x random start phase; `NB_COLD_START=1` reloads the module before every trial (first terminal after game start); `NB_READY_DELAY` (default 0.05 s) and `NB_ACK_DELAY` (default 0.05 s) set the solver's next-press and stage-receipt delays. The harness loads the real `NoBrainer_decode_symbols_reroll.lua` twice, as shipped and with `MEASURED_PHASE_MAX` patched below zero (the uniform-phase valuation), and drives both through start, evaluation, cancel, stop, reinteract and predicted restart on identical boards. Engine RNG and board generation are deterministic stand-ins; phases follow the 2026-09-30 Flight-recorder measurement (first evaluation at 6-7 ticks of 52 Hz, predicted restarts at about 0 s).

Last run (2026-10-05, seed 1, 20000 trials, 3.2.0 press model): retry 0.22 s uniform 4.885 s / measured 4.784 s (-0.101 s); retry 0.40 s -0.111 s; retry 0.75 s -0.183 s. Random phase (1.12.x, retry 0.22 s): measured 0.004 s slower. Cold start (2000 trials, retry 0.22 s): measured 0.011 s slower. The in-flight limit never binds below an ACK delay of 0.6 s on any board (all 96,768 target/phase combinations checked). For comparison, 3.1.7's press model gave 4.927 / 4.826 s at retry 0.22 s.
