# Decode Search movement harness

Run from the NoBrainer mod root with the workspace LuaJIT binary:

```powershell
& "..\..\..\tools\luajit\luajit.exe" tests\decode_search_movement_harness.lua 7 0.30 0.02 0.02 500
```

Arguments: seed, RTT in seconds, dropped-move probability, extra-step probability, board count, optional pacing and `host`. The harness models the source-verified Darktide 1.13.0 `MinigameDecodeSearch.on_axis_set` movement rules and synthetic network delivery. It is offline evidence, not an in-game test.

Last run (2026-09-29, seed 7, 500 boards): 300 ms RTT with 2% drops and 2% extra steps solved 500/500 (average 1.004 s); 60 ms with the same faults solved 500/500 (average 0.487 s). A 300 ms, 10%/10% stress run solved 499/500 within the 20-second per-board limit.

# Decode Symbols reroll phase harness

Run from the NoBrainer mod root:

```powershell
& "..\..\..\tools\luajit\luajit.exe" tests\decode_symbols_reroll_phase_harness.lua 20000 1 0.22
```

Arguments: trials, seed, real retry cost in seconds. `NB_RANDOM_PHASE=1` replays the 1.12.x random start phase; `NB_COLD_START=1` reloads the module before every trial (first terminal after game start). The harness loads the real `NoBrainer_decode_symbols_reroll.lua` twice, as shipped and with `MEASURED_PHASE_MAX` patched below zero (the previous uniform-phase valuation), and drives both through start, evaluation, cancel, stop, reinteract and predicted restart on identical boards. Engine RNG and board generation are deterministic stand-ins; phases follow the 2026-09-30 Flight-recorder measurement (first evaluation at 6-7 ticks of 52 Hz, predicted restarts at about 0 s). Offline evidence, not an in-game test.

Last run (2026-09-30, seed 1, 20000 trials): retry 0.22 s uniform 4.927 s / measured 4.826 s (-0.101 s); retry 0.40 s -0.111 s; retry 0.75 s -0.183 s. Random phase (1.12.x, retry 0.22 s): measured 0.004 s slower. Cold start (2000 trials, retry 0.22 s): measured 0.011 s slower on the first terminal before two phases are measured.
