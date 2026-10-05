# NoBrainer design notes

## Structure (3.2.0)

- `NoBrainer.lua`: settings cache (`mod._S`, `mod._N`, `mod._speed_pacing`), callback lists (`mod._reg`), loads the modules below.
- `NoBrainer_core.lua`: BetterBrainer 1.0.3's core. Owns the `InputService._get`, `HumanInputHandler.pre_update`/`fixed_update`, `PlayerCharacterStateMinigame._update_input`/`on_exit` and `PlayerUnitDataExtension._read_server_unit_data_state` hooks. Every `_get` first passes `mod._route_input` (legacy features), then the serialized sample of the local player passes the active frame solver. The `_update_input` hook also calls the Balance/Frequency rearm functions and Smart Seed Reroll's evaluation.
- Frame solvers, BetterBrainer-shaped modules (`return function(ctx) ... return module end`): `NoBrainer_minigame_decode_search.lua` and `NoBrainer_minigame_drill.lua` (copies of BetterBrainer 1.0.3 `search.lua`/`drill.lua`), `NoBrainer_minigame_decode_symbols.lua` (BetterBrainer `symbols.lua` plus the Smart Seed Reroll glue).
- Legacy NoBrainer features on `mod._route_input` (`NoBrainer_input.lua`): Frequency, Balance, Auspex Scan and the reroll's cancel/re-interact input. Servo skull and Smart Seed Reroll keep their own files.

## Backport of BetterBrainer 1.0.0-1.0.3 (3.2.0)

Taken over: serialized-frame decisions and `ctx.pulse`; the server input-state gate (`had_received_input`); Search recentre wait, speed-5 start/press and pre-send; Drill aim planner, held first move, own-selection acknowledgement, late-result wait, lost-move retry, kill switches re-armed per mission, origin-target fix; Symbols full hit window with 30 ms margin, two presses ahead, complete-fresh-board sync and the 2.5 s safe exit; Frequency opening receipts and opening delay; Scan per-target retry.

Deliberate differences from BetterBrainer:
- Smart Seed Reroll stays. While it evaluates or reopens, the Symbols solver releases (`mod._ds_reroll_blocks_solver`). A board that matches the seed prediction counts as synchronized at once. `mod._ds_stage_ready_delay` reports two fixed frames (presses run ahead of receipts) and `mod._ds_stage_ack_delay` the receipt delay; the reroll's `board_cost` models the whole hit window less 30 ms and at most two presses in flight.
- Frequency is NoBrainer's own solver (presses on the visual target with speed pacing), with only BetterBrainer's opening receipts and opening delay added; its quick-restart recovery stays, and the server's argumentless stop during that recovery keeps the new opening. BetterBrainer's target-payload submission is not taken over.
- Scan and Balance are NoBrainer's own; only the Scan retry rule changed.
- Servo skull exists only in NoBrainer.
- The restart recovery of Search and Drill is removed; receipts (recentre, Drill openings) cover reopening.

Old and new solvers must not run together: never enable NoBrainer and BetterBrainer at the same time.

## Runtime status

- Offline: see `tests/README.md` (all pass, 2026-10-05).
- In game: not tested. BetterBrainer 1.0.3's in-game evidence (remote missions, speed 5: Drill holds, Search pre-send and recentre) applies to the same solver code but not to NoBrainer's integration.
- Smallest in-game test: as a client on a dedicated server at speed 5, solve Search (including a reopen), Drill and Symbols with and without Smart Seed Reroll, one Frequency and one scan; with DMF debug logging on, no `again`, `retrying`, `no recentre seen` or `resync` lines are expected. Then a local solo run at speed 1, and disable/enable during a stage transition.

## Open items

- NoBrainerDebug reads the frame solvers through `mod._frame_snapshot()` (read-only; keep it in step with module state when solvers change) and mirrors their `mod:debug` lines. `NoBrainer.lua` still initialises the old `mod._exp*`, `mod._drill*` and `mod._ds*` tables; nothing reads them any more.
- Remaining assumption shared with BetterBrainer: a minigame RPC arrives before a server state sent after it.
