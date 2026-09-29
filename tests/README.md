# Decode Search movement harness

Run from the NoBrainer mod root with the workspace LuaJIT binary:

```powershell
& "..\..\..\tools\luajit\luajit.exe" tests\decode_search_movement_harness.lua 7 0.30 0.02 0.02 500
```

Arguments: seed, RTT in seconds, dropped-move probability, extra-step probability, board count, optional pacing and `host`. The harness models the source-verified Darktide 1.13.0 `MinigameDecodeSearch.on_axis_set` movement rules and synthetic network delivery. It is offline evidence, not an in-game test.

Last run (2026-09-29, seed 7, 500 boards): 300 ms RTT with 2% drops and 2% extra steps solved 500/500 (average 1.004 s); 60 ms with the same faults solved 500/500 (average 0.487 s). A 300 ms, 10%/10% stress run solved 499/500 within the 20-second per-board limit.
