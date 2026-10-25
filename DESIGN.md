# NoBrainer design notes

## Structure (2026-10-25)

NoBrainer is BetterBrainer plus the Skitarius servo-skull command, Symbols reroll (with exact lookahead from the terminal's seed) and Search transition skip (user decision, 2026-10-25). BetterBrainer itself is 1.0.4 plus the Frequency pipeline; the shared solver design is in `mods/active/BetterBrainer/DESIGN.md`. This file covers what differs: the reopen controller and the two features that use it.

- `NoBrainer.lua`: BetterBrainer's core (`BetterBrainer.lua`) plus the reopen controller. It also has the ModID, path and data-file names changed, a one-time migration of 3.1-era speed settings (`_speed_schema_v2`), and the servo skull module, which `mod.update` calls every frame while the mod is enabled.
- `drill.lua`, `frequency.lua`, `balance.lua`, `scan.lua`: identical copies of BetterBrainer's modules. Keep them identical: change BetterBrainer first, then copy.
- `symbols.lua`, `search.lua`: BetterBrainer's modules plus Symbols reroll and Search transition skip. BetterBrainer's versions are the 1.0.4 files, so a change to those solvers is made in both mods.
- `servo_skull.lua`: NoBrainer's servo-skull command as a core module (`return function(ctx) ... end` with `update(dt, t)`, `reset`, `settings_changed`). It reads `ctx.settings`; its logic is unchanged from 3.2.0.
- `NoBrainer_data.lua`, `NoBrainer_localization.lua`: BetterBrainer's options and strings plus `decode_reroll_limit`, `enable_expedition_reopen` and the servo skull group, with NoBrainer's name and description.

Never enable NoBrainer and BetterBrainer together: both automate the same input.

## Decisions

- 2026-10-14 (user): replace every NoBrainer solver with BetterBrainer's current version. Keep the servo skull feature.
  - Removed with the old solvers: NoBrainer's Smart Seed Reroll, its own Frequency, Scan and Balance solvers, the legacy input route and its restart recovery.
  - Setting ids are shared with BetterBrainer, so saved values carry over; `enable_decode_smart_reroll` is no longer read.
- 2026-10-25 (user, after reviewing NoBrainer pull request 1 by Robert, Evasion3356): the Symbols reroll decides from the exact upcoming boards when the terminal's seed is known (Robert's Smart Seed Reroll, adapted without a new setting). Built in BetterBrainer first (65bc9c2, 918e161, d1883d0), then moved here.
- 2026-10-25 (user: "jag vill återgå i betterbrainer till 1.0.4 ... de är för starka"): Symbols reroll and Search transition skip are NoBrainer-only. BetterBrainer is back to 1.0.4 plus the Frequency pipeline.
- 2026-10-25 (user): both on by default in NoBrainer: `decode_reroll_limit` 8 (range 0-8) and `enable_expedition_reopen` on (it acts at expedition speed 5 only).
- Every reopen feature has a kill switch for the rest of the mission after any failure, like the Search pre-send and Drill holding. Failures cost time, never a wrong press.

## Reopen controller (`NoBrainer.lua`)
- Why: a decoder terminal's `decoding` interaction takes 0 s (`interaction_templates.lua:36-43`) and is allowed again 0.1 s after the last success while the minigame is inactive (`decoder_device_extension.lua:292-305`). Every entry runs `setup_game` on the server before that frame's input (`player_character_state_minigame.lua:138-148,376-402`).
  - Search keeps its board and stage, recentres the cursor and is in gameplay at once (`minigame_decode_search.lua:68-86`; `minigame_base.lua:34-36,82-92`). Reopening therefore replaces the 0.25 s transition (`minigame_decode_search.lua:163-165`) with a few frames.
  - Symbols builds a new board on every setup (`minigame_decode_symbols.lua:93-144`).
  - Drill cannot use this, because its setup resets the stage to 1 (`minigame_drill.lua:71-94`).
- How: a solver calls `ctx.reopen_ready(mg, t)`, then `ctx.request_reopen(mg)`. The controller then:
  1. Injects the ordinary ephemeral cancel (`action_two_pressed`, `player_character_state_minigame.lua:206,307-309`).
  2. On the local `on_exit`, suspends the solver instead of resetting it.
  3. Injects `interact_pressed` (`base_interaction.lua:57-59`) once the interactor would pick the terminal (`InteractorExtension._find_interaction_object`, `interactor_extension.lua:567-588`), `can_interact(terminal, "decoding")` holds, and 0.15 s have passed since the session started. That is 0.05 s of margin over the native gate.
  4. When the new session of the same minigame starts, resumes the solver (`module.resume`). Only after its own interact: before it, the same minigame is the old session replayed by a client correction (`on_enter_server_corrected_state` initializes the terminal again, `player_character_state_minigame.lua:127-148`), and is ignored. Seen in game 2026-10-25: "resumed 0.020s after the request" with no interact, then "session ended 0.000s after the resume, reopening switched off".
  While the reopen is in flight every routed action is neutral, so a held fire or jump key cannot act in the walking state.
- Precondition at request: the terminal is a `decoding` interactee with a decoder device, and the interactor already finds it as chosen or focus target. During the minigame it is only a focus target, because `interaction_allowed` is false while the minigame is active.
- Timing: the client's interactor runs before the character state machine in a fixed frame (`extension_system_configuration.lua:361,397`), and the interaction completes in the frame it starts (`interactor_extension.lua:325-397`). The sequence is: cancel frame, interact frame (the CSM enters minigame in the same frame), setup frame (that frame's input already counts). The server runs the same frames in order, so the client does not wait for any receipt.
- Failure: no new session within 1 s of the request, or a session lost within 1 s of a resume (rollback after a server rejection), switches reopening off until the next mission. "Lost" means without on_exit: a server correction swaps the state machine's state directly (`character_state_machine.lua:68-81`), while the player's own cancel, dodge or look-away exits through on_exit (`:133-148`) and keeps reopening on (2026-10-25: a manual cancel 0.69 s after a resume had switched it off in game, so later manual entries got no rerolls). A solver still in its old session gets `reopen_failed()`; a suspended one is reset.
- Side effects: the owner also receives the server's `rpc_minigame_sync_stop` for the old session after the new local start (`minigame_base.lua:172-181`). Client stop clears `_player_session_id` and `_action_held` only. The missing-owner path of `ctx.session_valid` already covers that, and every solver releases before pressing again. Teammates see the auspex close and reopen.

## Search transition skip (`search.lua`)
- At speed 5, with `enable_expedition_reopen`, a stage-advancing press below the last stage requests a reopen. Its cursor was confirmed as usual.
- On resume the solver plans the next stage from the centre at once. Until the stage receipt it uses the predicted stage, and it treats the displayed transition state as gameplay. The displayed cursor is ignored until the recentre receipt (`recentred[mg]`, set by the existing `set_cursor_position` hook), with the usual ack timeout.
- Presses still need the receipt stage, a confirmed cursor and the server input-state proof, so a prediction can never cause a wrong press.
- If the press is proven lost (the server ran later timely input and the stage did not advance), it plans the old stage again.
- Recentring also shortens the next path: 4.09 instead of 5.43 steps per board, and no 3-4 step paths (scratch simulation 2026-10-14).

## Symbols reroll (`symbols.lua`)
- At the first moment a fresh board can be pressed (stage 1, complete receipts), the solver computes its own time to the last press. The model is the press rule of `input()`: hit window less 30 ms, frame grid, two frames between presses, a third press waits for the first receipt.
- It rerolls while that time exceeds the reopen delay plus the optimal value of a fresh board with one reroll fewer, plus 0.15 s. The fresh-board value is a finite-horizon optimal stopping value over all 1512 equally likely target sequences, at the measured decision phase and receipt delay.
- The reopen delay starts at ping + 0.15 s and is then measured. The cap is `decode_reroll_limit` per hack.
- The scratch model with ping 0.06-0.2 s gives a mean board of 5.1 s, 4.0-4.2 s at cap 4 (1.5 rerolls on average) and 3.8-4.0 s at cap 8.
- Exact lookahead (from Robert's Smart Seed Reroll): every board a terminal deals follows from its seed (`minigame_decode_symbols.lua:103-140`, `table.lua:781-797`). When that seed is known, the solver deals the next `limit - rerolls` boards itself and values them backwards with the same keep-or-reroll rule, instead of the fresh-board value. Debug lines say `(seed)` or `(average)`.
  - Host: the minigame's `_seed` after setup is the next board's seed.
  - Client: no seed is synced. The server hands extension n `level_seed + n` (`minigame_system.lua:30-71`); safe hooks on `MinigameSystem.init` and `on_add_extension` count the client's own registrations from the `level_seed` in its init data (`gameplay_init_step_extensions.lua:133-136`). Level units register in `Level.units` order on both peers. The solver deals up to 256 boards from the terminal's first seed until one matches the received symbols and targets, so earlier openings by anyone are covered.
  - Unknown seed (no match, hooks registered mid-mission, minigame units spawned at runtime, hot reload): the average board decides, as before.

## Source contracts
| Use | Source path:line |
|---|---|
| Entry runs setup before input | `scripts/extension_systems/character_state_machine/character_states/player_character_state_minigame.lua:138-148,183-216,376-402` |
| Cancel and exit | `player_character_state_minigame.lua:206,270-342` (walking on cancel), `:87-125` (on_exit stops the minigame) |
| Re-entry | `scripts/extension_systems/character_state_machine/character_states/player_character_state_walking.lua:150-156`; `scripts/extension_systems/interaction/interactions/decoding_interaction.lua:11-34` |
| Interaction gate | `scripts/extension_systems/decoder_device/decoder_device_extension.lua:292-305`; `scripts/settings/interaction/interaction_templates.lua:36-43` |
| Interactor | `scripts/extension_systems/interaction/interactor_extension.lua:160-244,290-405,567-588,753-787`; `interactee_extension.lua:137-176`; `scripts/utilities/attack/player_unit_status.lua:40-44,276-285` |
| Search setup keeps stage | `scripts/extension_systems/minigame/minigames/minigame_decode_search.lua:68-86,150-166,203-257` |
| Symbols setup builds a board | `minigame_decode_symbols.lua:93-144,183-211` |
| RNG | `math.next_random`, `types/darktide/core.lua` (LCG identified in game, `types/SOURCES.md`) |
| Minigame seeds | `scripts/extension_systems/minigame/minigame_system.lua:30-71`; `scripts/foundation/managers/extension/extension_system_base.lua:94-114`; `gameplay_init_step_extensions.lua:133-136`; `scripts/game_states/game/state_gameplay.lua:29`; `minigame_base.lua:7-32` |

## Tests
- `tests/reopen_spec.lua` 21/21 (2026-10-25): Search transition skip, Symbols reroll (average board and exact boards from the server or a rebuilt client seed), a replayed old session before the re-entry, the player's own cancel right after a re-entry, a session lost without on_exit, and the Frequency pipeline. Other suites: speed 73/73, search 21/21, drill 36/36, scan markers 4/4, servo skull 4/4. Results and cases are in `mods/active/BetterBrainer/tests/README.md` history (before b67e52a) and in this repository's `tests/`.

## Runtime status
- 2026-10-14 (user, BetterBrainer build): Symbols reroll and Search transition skip reported working in game.
- 2026-10-25, BetterBrainer builds with these features (dt-cli logs, client of a mission server, limit 8): the client rebuilt the seed (`(seed)` on every decision). Three 60 s checks found two reopen bugs, both fixed (918e161, d1883d0). The last check: 15 rerolls and 6 kept boards, every resume after its own interact, no switch-off, rerolls again after manual cancels and re-entries.
- This NoBrainer build (defaults on, ported 2026-10-25), the servo skull module in its new form and the Frequency pipeline are not yet tested in game.
- Smallest test, as a client in a regular mission with default settings:
  1. Hack a Symbols terminal: slow boards are rerolled (the auspex closes and reopens), up to 8 times.
  2. At expedition speed 5, solve a Search terminal: the auspex closes and reopens after each stage below the last.
  3. As Skitarius with the hacking servo skull, walk within 25 m of a hackable terminal: the skull should be ordered to it.

## Open items
- 2026-10-14: `NoBrainerDebug` read the old solvers through `mod._frame_snapshot()`, which no longer exists. The companion needs updating before it can observe 4.x; it never ships.
- 2026-10-25: exact Symbols lookahead seen as a client in one session; a hot join and more missions are unobserved.
- 2026-10-25: NoBrainer pull request 1 is superseded by this port; it is still open and unanswered.
