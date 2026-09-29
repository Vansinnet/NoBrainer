# Changelog

## [3.1.6] - 2026-09-29
### Added
- **Search and Drill fast exit**: After the local minigame reports completion, NoBrainer sends one normal cancel input to skip the native outro wait (0.25s for Search, 0.6s for Drill). Exit uses the game's own cancel path, so completion, objective progress, and scanner teardown are handled natively. Always on while the matching auto-solve setting is enabled; Decode Symbols, Frequency, and Balance already exit on completion.

### Fixed
- **Servo-skull hack target check**: Replaced the removed `SmartTagExtension:is_particular_target_type("hack")` call with a direct `_target_type == "hack"` comparison. The method was removed from the current game source while the `_target_type` field remains, so the old call would fail and break servo-skull auto-hack target search.

## [3.1.5] - 2026-09-08
### Changed
- **Frequency state ownership**: Removed duplicate module initialization and consolidated identical timing-state resets without changing session, restart, or pacing behavior.
- **Matching state handling**: Replaced temporary cursor and target tables with scalar coordinates while preserving pending movement, server acknowledgement, and submit settling.

### Performance
- **Input movement routing**: Matching, Drill, and Frequency now return their existing movement vectors directly instead of immediately copying them into new vectors.
- **Servo Skull target search**: Skips actor and line-of-sight work for candidates that cannot beat the nearest visible target, and avoids actor-position work when line of sight is disabled.
- **Auspex Scan polling**: Reuses the current weapon action already read during the update instead of repeating component-proxy reads.

## [3.1.4]
### Changed
- **Decode Symbols predicted reroll synchronization**: A rerolled client board can skip the generic 120ms stability wait when its fresh start time, stage 1, all 28 symbols, and all four targets exactly match the seed-predicted board. Incomplete or mismatched replication retains the existing fail-closed synchronization path.
- **Decode Symbols exact client retry valuation**: Before a measured restart sample exists, a seed-verified client decision now values a retry from the network round-trip floor plus the existing restart synchronization margin instead of the conservative 750ms fallback. Host and statistical decisions retain the fallback, while completed retries continue to replace and adapt the estimate from observed cancel-to-board timing.

### Fixed
- **Decode Symbols high-ping consecutive rerolls**: A temporary client state correction that reopens the same terminal before the authoritative stop acknowledgement no longer resets an in-progress cancel. Its duplicate local stop is ignored until the server stop arrives, preserving the predicted board and remaining reroll count through consecutive retries.

## [3.1.2] - 2026-08-19
### Added
- **Simplified Chinese localization**: Added a complete `zh-cn` translation and manual Simplified Chinese language option. Credits to EasyRain233 for providing a translation! Automatic mode uses the translation when Darktide's language is set to Simplified Chinese.

## [3.1.1] - 2026-08-18
### Added
- **Russian localization**: Added a complete Russian translation and manual Russian language option. Automatic mode uses the Russian translation when Darktide's language is set to Russian.

## [3.1] - 2026-08-17
### Added
- **Decode Symbols smart seed reroll**: Added an optional Smart Seed Reroll setting that can cancel and retry up to two slow stage-1 layouts before auto-solving. Host play predicts future layouts directly from the isolated minigame seed; network clients use only seed candidates that reproduce the full current symbol and target layout exactly, with finite-horizon statistical stopping as a fallback. Client forecasts include measured submit-to-stage acknowledgement delay and current network RTT, while restart cost is learned separately from the full cancel-to-stable-board path. Retries use normal networked cancel and interaction input, wait for the authoritative stop acknowledgement, reacquire the same terminal, and fail closed on stale synchronization, ownership changes, invalid targets, or timeout.
- **Smart reroll expected time saving**: A deterministic Monte Carlo simulation of 2,000,000 paired trials sampled all 1,512 legal target layouts with continuous realized cursor phases while applying the runtime policy's 32-phase future-board valuation, 0.5-second minimum net-saving threshold, and maximum of two retries. At the client's 0.2-second minimum stage-ready delay, exact seed prediction reduced the 5.545-second no-reroll mean by 0.645 seconds (11.63%) with the cold 0.75-second restart cost and by 0.720 seconds (12.99%) with a 0.630-second learned cost. A 0.30-second stage-ready delay with the cold restart cost still saved 0.641 seconds (11.55%). Future target layouts are known in exact mode, while future start phases remain unknown and are phase-averaged as in the runtime policy.

## [3.0.2] - 2026-08-04
### Changed
- **Matching speed 5 movement pacing**: The next movement pulse can now fire immediately after the full server-synchronized cursor coordinate acknowledges the previous move, restoring the practical speed of version 2.2.1 without removing pending-move, stale-session, stage, or timeout safeguards. Timed-out movement also resets submit settling before retrying from the latest fresh snapshot.

### Fixed
- **Matching high-latency restart recovery**: A delayed server stop from a cancelled Matching session can no longer permanently clear a newer local solver session. Recovery is bounded to the original restart window and only re-arms from the same active local `PlayerCharacterStateMinigame`, scanner view, and fresh gameplay snapshot, preserving stale-input protection during real exits, stuns, ownership changes, and mission transitions.
- **Shared high-latency restart safeguards**: Drill, Balance, and Frequency now distinguish an argumentful local cancel from the delayed argumentless server stop that can cross a quick restart. Recovery is restricted to the same local minigame instance, active scanner view, gameplay state, and an unextended 1.2-second window; completion, ownership transfer, stun/state exit, setting changes, timeout, and round cleanup remain fail-closed.
- **Restart stop ordering**: When the delayed argumentless server stop arrives before the player re-enters Drill, Balance, or Frequency, it now consumes the pending restart marker so the following local start arms normally instead of waiting for a second stop that will never arrive.
- **Drill high-latency restart recovery**: Drill re-arms only from a coherent current stage, cursor, target, selection, and search snapshot. Centered idle stages, the correct node, and valid intermediate selected nodes are supported, while normal starts retain the stricter stage-1 reset gate and all pending movement, submit pulses, cooldowns, and settle state are discarded before recovery.
- **Balance high-latency restart recovery**: Balance remains inactive until two fresh post-stop server positions arrive with a plausible sample interval. It rebuilds position and velocity from those samples after clearing command history, pending samples, prediction, correction, RTT, and safety state, preventing stale or zero-velocity steering from crossing the restart boundary.
- **Frequency high-latency restart recovery**: Frequency remains inactive during a quick restart until the delayed server stop is observed, followed by a fresh ordered board, stage-1, and target synchronization. The full normal startup delay and all movement, reaction, confirmation, cooldown, and submit gates then restart from clean state.

## [3.0.1] - 2026-08-01
### Fixed
- **Drill client startup synchronization**: Drill auto-solve now observes the server-replicated stage-1 reset directly when search state is cleared, instead of relying solely on the next UI sample to see the brief centered cursor state. This prevents held movement input during startup from moving the cursor before readiness is armed and permanently disabling automation, while preserving the existing stale-session and ownership safeguards.

## [3.0.0] - 2026-07-30
### Removed
- **Practice Mode**: Removed the practice controller, simulated minigames, selector and practice views, keybind, settings, localization, input routing, and runtime integration.
- **Expedition auto-marking**: Removed automatic Expedition POI, vault, and extraction marking together with its settings and localization. Decode Search highlighting, auto-solve, and the `expedition_solve_speed` setting remain available.
- **Permanent debug system**: Removed the debug setting, chat output, rate limiting, run tracking, route diagnostics, telemetry, counters, and debug-only allocations across every runtime module. Development diagnostics now live in the separate `NoBrainerDebug` companion and are not included in NoBrainer releases.
- **Balance speed setting**: Removed the misleading Balance speed slider because Balance has a fixed progression time and the gentle predictive profile already completes reliably.

### Changed
- **Lightweight runtime**: Reduced the mod's Lua source from 8,934 to 4,079 lines, a 54.3% reduction, while retaining minigame solution highlights, configurable auto-solve pacing, Auspex scanning, servo-skull auto-hack, and Balance automation.
- **Protected-call cleanup**: Removed 11 redundant `pcall` wrappers from update dispatch, gameplay time, scanner-template loading, minigame UI sampling, scan visuals, and network timing. Expected lifecycle absence now uses explicit timer, state, extension, and host checks, reducing per-frame protected-call and exception overhead while preserving DMF callstacks for unexpected failures. The focused Decode Search stop wrapper remains for its confirmed destroyed-extension teardown race.
- **Servo-skull attempt state**: Replaced the mixed diagnostic state with a minimal functional order state and added recovery when a confirmed tag disappears before hacking begins.
- **Auto-solve speed scale**: Replaced the old 1-10 speed sliders for Matching, Drill, and Frequency with a maintainable 1-5 scale. Speed 1 is the default paced profile, while speed 5 preserves the fastest solver decisions. Intermediate levels apply deterministic pacing to the same solver instead of separate algorithms, random skips, or deliberate wrong input.
- **Matching pacing range**: Made Matching speed 1 approximately 30% shorter than the previous speed 1 profile and distributed speeds 2-4 linearly across the reduced pacing range. Every speed now uses the same diagonal routing and server-confirmed movement synchronization, while speed 5 retains the fastest submit pacing.
- **Fixed Balance controller**: Balance now always uses 35% normal predictive gain. Boundary safety corrections still use full strength.

### Fixed
- **Decode Symbols high-latency restart recovery**: A delayed client stop after an immediate cancel and restart now preserves the pending synchronization wait, and the active local minigame state can re-arm the solver while replicated ownership is temporarily unavailable. This prevents Decode Symbols auto-solve from remaining inactive after a high-latency restart without allowing stale board input.

### Compatibility
- **Updating from earlier versions**: Existing removed settings, including `balance_solve_speed`, are safely ignored and older string-based solve-speed values are still migrated for the remaining configurable solvers. Fully exit Darktide before installing this update; updating through Ctrl+Shift+R is not supported because removed Practice Mode class replacements can remain in memory until restart.
- **Speed setting migration**: Existing numeric 1-10 values for Matching, Drill, and Frequency are migrated once to the new 1-5 scale. Previous speed 10 becomes speed 5, old Human becomes speed 1, and old Inhuman becomes speed 5. Balance keeps its existing enable setting but no longer reads its retired speed value.

## [2.2.1] - 2026-07-25
### Fixed
- **Drill submit synchronization**: Movement input is now blocked while a submitted stage waits for server confirmation or the existing timeout. This prevents a late cursor snapshot from triggering another movement and duplicate submit before the stage RPC arrives.

## [2.2.0] - 2026-07-23
### Added
- **Skitarius servo-skull auto-hack**: Added an enabled-by-default option that automatically orders the hacking servo skull to the nearest available minigame. Command range is configurable from 5 to 100 metres and defaults to the servo skull ability's normal 25-metre targeting range. Line of sight is required by default, with an option to allow orders through walls, floors, and ceilings. Targets and replicated state are checked every 50ms, pending orders prevent duplicate requests, failed confirmations use a separate retry delay, and structured diagnostics track selection, server confirmation, hacking state, tag removal, and completion.
- **Practice Mode selector**: The Practice Mode hotkey now opens an in-game selector for Decode Symbols, Decode Search, Drill, Frequency, and Balance. Minigame selection has been removed from mod options and the selector retains the latest choice for the current session.
- **Traditional Chinese coverage**: Added `zh-tw` localization for all new Servo Skull options and tooltips, the updated Practice hotkey behavior, and every label and description in the Practice selector.
- **Practice auspex presentation**: Practice minigames now use a real handheld auspex with the stock wield, focus, and scanner-display flow in the Psykanium. The Mourningstar continues to use the standalone presentation.

### Changed
- **Practice Balance fidelity**: Practice Balance now uses the stock push, disruption, speed, movement, and sound constants and follows the stock position-before-force update order. Progress pauses outside the valid radius instead of being lost, while the standalone practice run retains its 20 seconds of accumulated in-bounds training time.

## [2.1.0] - 2026-07-22
### Changed
- **Central input routing performance**: Active automation now classifies primary, movement, and scan actions before dispatch and invokes only the relevant solver routes in their existing order. This removes the per-query Matching movement closure and avoids unrelated view, time, manager, vector, and random-work paths without changing input precedence, synthetic release behavior, solve-speed pacing, or server-confirmation gates.
- **Minigame hot-path allocations**: Decode Symbols now passes sweep duration directly and skips idle gameplay-time reads, while Matching and Drill reuse their previous-cursor snapshots. Matching also draws its four target highlights without a temporary index table, and Drill updates the existing highlight color instead of allocating another table each frame.
- **Scan polling performance**: Local player unit-data, weapon-action, and scanning components are cached for the current player-unit lifetime and invalidated on unit changes and existing cleanup paths. Highlight bookkeeping counts and repeated no-line-of-sight debug payloads are now built only when debug output is enabled.
- **Balance runtime overhead**: Inactive Balance sessions now return before update-state writes. Speed 10 keeps all RTT, observer, command-replay, prediction, and safety control state active while collecting forecast, residual, packet, ping, stall, and aggregate statistics only during an active debug run; attaching debug mid-run starts a fresh diagnostic interval.
- **Expedition auto-mark polling**: Disabled auto-mark cleanup now runs on setting and lifecycle transitions instead of every mod update.
- **Balance speed 10 controller**: Replaced the frame-derived PD path with an RTT-aware predictive controller that samples synchronized positions directly, estimates hidden velocity, replays delayed input commands, compensates for the game's outward force, and applies disruption-aware safety braking. Speeds 1-9 are unchanged.
- **Balance diagnostics**: Added packet timing, observer innovation, timestamp-matched forecast error, controller saturation, measured/predicted radius, safety headroom, boundary-stall, and aggregate completion metrics for tuning dedicated-server runs.
- **Matching speed 10 submit**: Submit now fires on the next stable gameplay tick after the server-synchronized cursor reaches the target, instead of adding the normal 0.20-second post-move guard and 0.10-second settle delay. Movement sync locks, retry timeouts, stage transitions, and speeds 1-9 are unchanged, while structured diagnostics expose the selected submit mode and every sync, settle, and submit phase for both paths.
- **Matching duplicate routing**: When the target symbol grid appears in multiple valid board positions, the solver now locks onto the match requiring the fewest diagonal movement pulses from the current cursor. This reduces server-acknowledged movement cycles without changing movement synchronization or submit timing.
- **Matching route diagnostics**: Debug output now records every valid duplicate with its diagonal/Manhattan score, the old first-match baseline, the chosen target, planned and saved movement steps, and a bounded stage summary of sent, acknowledged, and unacknowledged movement pulses.
- **Matching debug lifecycle clarity**: Pre-session view sampling no longer emits false missing-target warnings, valid board synchronization is reported as a wait state, the post-final-stage sentinel is reported as completion pending, and every full expected-coordinate acknowledgement emits an indexed `move_acked` event. Route summaries now distinguish their start and final cursor positions.
- **Drill speed 10 synchronization**: Movement now sends one target pulse and waits for the server-synchronized cursor and selected index before allowing another input. Submit independently waits for the server search state and still fires immediately when the game's mandatory 0.50-second search completes; the 0.60-second stage transition and speed 1-9 pacing are unchanged.

### Fixed
- **Scan local-player lifecycle isolation**: Auspex init, wield, unwield, and destroy callbacks now ignore remote-player equipment, preventing a teammate's scanner lifecycle from refreshing or clearing the local auto-scan state.
- **Expedition handler cleanup**: Auto-mark cleanup now releases the cached navigation handler, preventing a stale mission reference and repeated disabled-state cleanup after an Expedition handler has been observed.
- **Servo-skull minigame ownership race**: A remote start on the same Decode Symbols, Decode Search, Drill, Frequency, or Balance instance now immediately clears the previously armed local solver, while remote starts on different devices remain isolated. This prevents stale synthetic input when a Skitarius servo skull wins a simultaneous interaction.
- **Matching high-latency movement sync**: Pending movement now clears only when the server-synchronized cursor reaches the full expected coordinate. Intermediate per-axis or stale cursor RPCs remain blocked and are diagnosed separately, preventing overlapping movement pulses and target overshoot under high latency.
- **Drill high-latency input duplication**: Pending target movement and submitted stages now remain locked until their server RPC or bounded timeout arrives, preventing repeated node selections and duplicate submit pulses under high latency. Cursor acknowledgement accounts for the RPC's observed 1/128 coordinate quantization while still requiring the exact selected target index.
- **Balance movement leakage**: Balance corrections now require an active scanner or practice view, preventing stale auto-balance input from moving the player after minigame ownership changes or the view closes.
- **Frequency and Decode Symbols stale sessions**: Added durable local-session and active-view gates so later UI/state sampling cannot re-arm synthetic input after ownership has transferred.

## [2.0.8] - 2026-07-12
### Changed
- **Balance restart tracking**: Balance input now waits for the local minigame start before routing corrections and initializes position tracking from the current resumed cursor position, preventing a false velocity spike on the first sample after an interruption.
- **Matching restart synchronization**: Decode Search movement and submit routing now require an active local minigame session and wait 0.20 seconds after each start, preventing stale pre-start cursor samples from triggering an incorrect move or submit after an interruption.
- **Drill restart synchronization**: Drill movement, submit pulses, and the local-server fallback now require an active local session and the synchronized stage-1 baseline before acting. Drill submit pulses also apply the intended 80ms press before the 120ms release, without adding a fixed startup delay.
- **Decode Symbols diagnostics**: Decode timing logs now distinguish the solver's trigger lead/grace from the game's actual target half-width, report the remaining margin to the target edge, identify local input-edge acceptance separately, report server-synchronized stage success or misses, and retain the final completed stage in cleanup output.
- **Debug message capacity**: Increased the global debug output limit from 100 to 300 visible messages per 30 seconds for longer diagnostic captures.

### Fixed
- **Decode Symbols restart input**: Interrupted Decode Symbols runs now wait for a stable stage-1 snapshot of the minigame instance, synchronized start time, and target before submitting again. Unexpected snapshot changes re-arm synchronization and cancel stale synthetic input, while a safe first-pass target can still be submitted immediately after the short stability check. Only the Ingame input service reserves networked submit attempts, and the intended 80ms press is followed by the 120ms release. Existing submit timeout and retry behavior remains as a fallback.
- **Scan restart input**: Interrupted scans now clear their synthetic hold as soon as scan confirmation ends and allow the same target to be selected again immediately, while completed targets remain suppressed until the scanner selects a different target. This prevents stale holds from blocking retries and client synchronization delay from triggering a redundant scan after success.

### Credits
- To adamigo50 for some feedback during gameplay!

## [2.0.7] - 2026-07-11
### Added
- **Traditional Chinese localization**: Added a complete `zh-tw` translation by SyuanTsai and a language selector at the top of the mod options. Automatic mode follows the game's language with English fallback, while English and Traditional Chinese can be selected manually when automatic detection does not work. Manually selecting Traditional Chinese does not load the game's Chinese font; Darktide must also use Traditional Chinese or translated text may appear as squares.

### Changed
- **Scan diagnostics**: Successful automatic scans now end with an explicit `succeeded` event from the game's confirmed scan path, and repeated identical scan input route overrides are logged only once per scan attempt.

## [2.0.6] - 2026-07-09
### Changed
- **Minigame diagnostics**: Expanded the existing rate-limited debug output with structured start, sample, wait, blocked, input, submit, cleanup, missing-data, and server/client reasons across Matching, Decode Symbols, Drill, Frequency, Balance, Scan, and Expedition Map.

### Fixed
- **Remote minigame lifecycle interference**: Drill, Frequency, and Balance now only arm solver lifecycle state for the local player and only accept `stop` / `complete` cleanup from the matching active instance, preventing teammates' minigames from resetting local solver state.
- **Idle debug spam**: Normal gameplay input polling, inactive scan zones, and unavailable Expedition handlers no longer emit recurring blocked messages. Missing scan systems and the loss of a previously active Expedition handler remain diagnostic.

## [2.0.5] - 2026-07-04
### Added
- **Expedition auto-mark extraction fallback**: Added an optional setting to mark the extraction point after all opportunities are complete when there is no exit/vault target available.

### Changed
- **Expedition auto-mark**: Restored automatic Expedition Map POI/vault marking as an optional feature. It remains disabled by default and respects manual marks.
- **Minigame auto-solvers**: Matching, Drill, Frequency, and Decode Symbols now use short-lived fresh snapshots instead of long-lived live minigame references for input routing, matching the Balance solver's stale-safe model.
- **Decode Search auto-submit timing**: Reduced the fresh on-target settle window from 0.20s to 0.10s and the post-move submit guard from 0.30s to 0.20s so Matching submits sooner after the cursor reaches the correct solution.

### Fixed
- **Decode Search stop crash**: Guarded Matching cleanup against a destroyed `MinigameExtension` teardown race that could crash when closing or restarting an Expedition Matching minigame.
- **Stale minigame state**: Drill auto-solve now keeps sampling even when Drill highlighting is disabled, and Matching/Decode Symbols cleanup only clears state for the active sampled minigame instance.

## [2.0.4] - 2026-07-03
### Fixed
- **Remote minigame interference**: Decode Search (Matching) and Decode Symbols now ignore remote/stale minigame instances that do not belong to the local player. Matching `stop` / `complete` cleanup is also limited to the active solver instance, preventing other players' expedition minigames from clearing NoBrainer state mid-solve.

## [2.0.3] - 2026-07-02
### Fixed
- **Decode Search stop hook warning**: Merged the `MinigameDecodeSearch.stop` cleanup into the existing hook so NoBrainer no longer registers both `hook` and `hook_safe` on the same method, preventing DMF's `Attempting to rehook active hook [stop] with different obj or hook_type` startup warning.

## [2.0.2] - 2026-07-01
### Changed
- **Decode Search submit settle**: Reduced `SEARCH_SUBMIT_SETTLE` from 0.35s to 0.20s so auto-submit triggers sooner after the cursor reaches the correct match while still keeping a short safety settle window.

### Fixed
- **Decode Search stop crash**: Guarded `MinigameDecodeSearch.stop()` against invalid minigame units so the solver skips the vanilla `lua_minigame_stop` flow event when the terminal unit has already been destroyed, preventing `UnitReference is not valid` crashes during Matching cleanup.

## [2.0.1] - 2026-07-01
### Fixed
- **Decode Search auto-submit**: Fixed a submit-state guard that treated a fresh stage with no pending synthetic submit as a stage change, causing the solver to move onto the correct match but never send the auto-press.

## [2.0.0] - 2026-06-28
### Added
- **NoBrainer folder pathing**: Mod folder and load paths use `NoBrainer`, matching the internal DMF ModID and release folder name.
- **Debug message system**: New `enable_debug_messages` checkbox setting. All minigame solvers now report internal state through throttled, deduplicated, copy-friendly debug messages (`mod._debug`, `mod._debug_throttle`, `mod._debug_change`, `mod._debug_event`). Debug output is disabled by default and globally rate-limited to 100 visible messages per 30 seconds.
- **PlayerUnitInputExtension hook**: Input routing now covers both `InputService._get` / `_get_simulate` and `PlayerUnitInputExtension.get`. This enables proper `move` / `move_controller` Vector3 routing for Decode Search, Drill, and Balance auto-solvers, instead of relying only on the four discrete directional action overrides.
- **Central input router hardening**: All auto-solvers now pass through a shared `mod._route_input()` that uses `_apply_route()` — each solver returning `nil` preserves the previous result, preventing a broken solver from propagating `nil` through the input chain. Balance activity checks are nil-safe.
- **Runtime callback isolation**: Internal update/cleanup callbacks are isolated with `pcall`, so one failing module callback cannot prevent the rest of the mod from cleaning up. Each failure is logged once through DMF.
- **Safe gameplay time access**: Runtime paths now use `mod._time()` for guarded `Managers.time:time(...)` access, avoiding transition-time callback errors when the gameplay clock is unavailable.
- **Decode Search submit settle**: After the cursor reaches the target, the solver waits 0.35s (`SEARCH_SUBMIT_SETTLE`) before submitting. This prevents false submits when the cursor is still settling from a move.
- **Decode Search move sync/pending**: Tracks pending moves (`_exp_pending_move`) with a 0.8s timeout to avoid sending duplicate move inputs before RPC sync confirms the cursor position. Moves are blocked during pending sync.
- **Decode Search after-move delay**: 0.30s delay (`SEARCH_AFTER_MOVE_DELAY`) after any cursor movement before allowing submit, preventing premature submission.
- **Decode Search match cache invalidation**: Hooks `MinigameDecodeSearch.generate_board` and `set_symbols` to clear the target match cache and pending/submit state.
- **Drill server-side fallback**: `on_update` now calls `MinigameDrill:on_action_pressed()` directly when running as server (Solo Play / Psykanium) and the search ring is full with the correct target selected. Normal client routing via input pulses remains for online play.
- **Drill stale-instance guard**: `_drill_active_mg()` prefers the minigame instance from the visible Drill view. The server fallback only runs when the server instance and view instance agree on the current correct target (`_same_solution()`), preventing submission on an invisible or stale target.
- **Practice minigame auspex view**: Practice minigames now run inside a scanner/auspex-style UI view instead of only as invisible backend minigame state, making practice closer to the real in-game presentation.

### Changed
- **Settings access hardened**: Hot-path setting reads go through `mod._N(id, fallback, min, max)` which validates numeric type, clamps to range, and provides a clean fallback. `mod._speed_scale()` now uses `_N()` internally.
- **Lifecycle cleanup upgraded**: Disable, unload, Ctrl+Shift+R reload, and gameplay exit now reset solver/runtime state consistently across all minigames. New `on_unload` handler tears down all state. New `_on_runtime_reset` event lets modules clean up on disable/unload.
- **Decode Symbols auto-solve**: `PRESS_LEAD` increased to 0.095 (from 0.065) for earlier press timing. Release timing now uses `mod._ds_press_until + RELEASE_DURATION` instead of independent timing. New `PlayerCharacterStateMinigame._update_input` hook provides a server-fallback path that calls `minigame:action()` and handles animation events directly. Expanded hold actions: accepts `interact_primary_hold` and `jump_held` alongside `action_one_hold` and `interact_hold`.
- **Decode Search / Matching auto-solve**: Target matching cache invalidated on board/symbol changes. Movement and submit timers clamped to 0 with `math.max`. Submit state cleaned on stop/complete/round exit. Cursor movement routed through both `InputService` and `PlayerUnitInputExtension`. Setting change (`enable_expedition_auto_solve`) triggers full cleanup.
- **Tree Drill auto-solve**: Movement and submit cooldowns clamped with `math.max`. `_drill_active_mg()` prefers view instance. `_is_gameplay()` state check added. Debug reporting for all solver decisions. Setting change cleanup added.
- **Frequency auto-solve**: Input-driven submission via new `_frequency()` function in input.lua using press/release pulses through `action_one_hold` / `interact_hold` / `interact_primary_hold` / `jump_held`. Movement routing through input for client-side play. Server-only axis steering in `on_update` (avoids duplicate client movement). `_freq_on_target` uses `pcall` and `_is_gameplay()` guard. Submit timing managed by `_freq_try_submit()`. Timers clamped with `math.max`.
- **Scan helper**: Scan highlight/outline setter wrapped in `pcall` guards. `has_system` check before accessing `mission_objective_zone_system`. Lifecycle expanded to hook `AuspexScanningEffects.wield` and `destroy`. Registers for `disabled`, `unload`, and `setting_changed` cleanup events. Input state reset includes `mod._current_action`.
- **Balance auto-solve**: New `_reset_balance_tracking()` resets tracked position, velocity, and EMA on start/stop/complete/disable/unload/round exit. Input hook now returns `Vector3(x, y, 0)` for `move`/`move_controller` actions. Debug reporting for active state. Setting change (`enable_balance`) triggers tracking reset.
- **Practice mode**: Practice view paths load from `NoBrainer`. Input state (`_practice_action_held`, `_practice_action_name`, `_practice_frame_axis`) is reset when closing practice. Practice opens blocked with debug message. `enable_practice` setting change closes active session. Closes on `disabled` and `unload` events. `_play_wwise` nil-safe on world manager.
- **Expedition auto-mark**: All navigation-handler method calls wrapped in `pcall`. New activity grace (5s) and registry stability grace (2s) before first mark. 3s mark cooldown between marks. Validates target still exists in registry before marking. Handles `mark_level_by_player` return values. Player lookup nil-safe with `game_session` check. State cleared on `disabled`/`unload`. Debug reporting for all decisions.

### Fixed
- **Stale solver state after transitions**: Auto-solver holds, release windows, cooldowns, previous cursor positions, scan state, and balance state are no longer left active after mission exit, disable, or unload.
- **Timer underflow edge cases**: Decode Search, Drill, and Frequency timers now clamp to `0` with `math.max(x - dt, 0)` instead of `x - dt` which could drift negative.
- **Input edge safety**: Auto-solvers no longer risk propagating an invalid route result through the rest of the input chain — each solver returning `nil` preserves the current value.
- **Drill submit in Solo Play**: Drill auto-solve now has a local-server submit fallback that calls `MinigameDrill:on_action_pressed()` directly when the ring is full and the selected target is correct. Only runs when server and view instances agree on the current target.
- **Scan stale highlights after unwield/destroy**: Highlights and auto-hold state are now cleared on `AuspexScanningEffects.wield`, `destroy`, mod disable, and mod unload — not just on `unwield`.

### Compatibility
- **Mod options unchanged**: All existing settings remain the same: highlights, auto-solvers, speed sliders, expedition auto-mark, and practice options. One new setting added: `enable_debug_messages` (default off).
- **Settings compatibility preserved**: `new_mod("NoBrainer", ...)` is unchanged internally, so users keep their existing NoBrainer settings.

## [1.6.3] - 2026-06-27
### Fixed
- **Decode Search (Matching) — robust submit pulse**: Auto-solve could move the cursor to the correct 4-symbol match but fail to submit until the player manually pressed once. Matching now uses an explicit 80ms press + 120ms release pulse and retries within 1.2s if the stage does not advance. Prevents stale-held-input issues and lock-up on high ping or with input-interception mods such as Skitarius.

## [1.6.2] - 2026-06-26
### Changed
- **Decode Symbols — deterministic scheduler replaces UI-triggered arming**: The old solver hooked `is_on_target` (called by the view during `draw_widgets`) to set `_ds_armed`, then pressed on the next input poll. This depended on frame ordering between UI update, input polling, and minigame state. The new scheduler calculates target center mathematically from `start_time`, `current_stage`, `_decode_targets`, and `sweep_duration` — the same data the server uses — and schedules the press independently of the UI cycle. Lower CPU, zero frame-order dependency, identical timing model as the engine.

- **Decode Symbols — explicit press/release pulse**: `mod._ds_input` returns `true` for 80ms then `false` for 120ms after a press, creating a clean rising edge followed by a release that re-arms the game's `_action_held` state machine. Prevents stale-held-input issues.

- **Decode Symbols — snappier visual timing**: `PRESS_LEAD` increased to `0.065` and `PRESS_GRACE` reduced to `0.060`, shifting the synthetic press slightly earlier while keeping the timing window inside the safe target center zone.

- **Decode Symbols — stage-lock against double-submit**: Tracks `_ds_submitted_stage` and refuses to press again on the same stage until the server RPC sets a new `current_stage`. Falls back to a 1.2s timeout if no RPC arrives.

### Fixed
- **Decode Symbols — fail-closed on missing data**: Returns original input (no synthetic press) if `start_time`, `stage`, `target`, `items_per_stage`, or `sweep_duration` is missing or invalid. The old `_ds_on_target` would return `false` and the input hook would pass through — effectively the same behaviour, but the new guard is explicit and covers all edge cases before attempting a press.

### Removed
- **NoBrainer.lua — orphaned `_ds_cooldown` field**: No longer read or written by the new decode-symbols scheduler.

## [1.6.1] - 2026-06-25
### Changed
- **Speed slider calibration — Decode Search, Drill, Balance**: `5` now maps to the old "Human speed" feel, `10` is the fastest practical speed, `1` is slower than old Human. Migration updated so existing `"Human"` → `5`, `"Inhuman"` → `10`.
- **Decode Search — diagonal movement**: Auto-solver now moves diagonally toward the target instead of one axis at a time, solving puzzles in fewer steps.
- **Balance — new speed profile system**: Instead of a single scale, each speed level has its own blend of EMA lag, deadzone, skip chance, and PD gains. `5` feels like old Human, `10` holds the dot near-center with live data and velocity-aware braking, `1` is noticeably slower than Human.
- **Balance — PD velocity bug fixed**: `_bal_correction()` now receives actual axis velocity instead of `0`. The D term now correctly dampens outward movement and brakes inward drift.
- **Decode Search & Drill — initial cooldown removed**: Auto-solver starts moving immediately when the minigame opens. (Drill still applies an initial cooldown matching the speed setting to prevent instant snap-to-target at non-max speeds.)
- **Decode Search, Drill & Balance — default speeds**: Decode Search `3` → `5`, Drill `3` → `5`, Balance `2` → `5` to match the new `5 = old Human` baseline.

### Fixed
- **Decode Search & Drill — manual WASD blocked during auto-solver cooldown**: Input hooks returned `0` for `move_left/right/forward/backward` during cooldown, making manual cursor control appear dead while auto-solve was paused. Now returns the original input value so manual WASD passes through.
- **Decode Search & Drill — `on_axis_set` zeroing input during cooldown**: Both hooks called `func(self, t, 0, 0)` under cooldown, suppressing any manual move that reached the engine. Removed — the engine now always receives the axis as-is; cooldown is enforced only by the InputService hook skipping synthetic overrides.
- **Decode Search — startup delay re-added by 1.6.0**: The 1.6 speed migration code set an initial `_exp_move_cooldown` in `MinigameDecodeSearch.start`, causing a multi-second delay before the first auto-move. Removed — cooldown is only set after an actual cursor position change.

### Added
- **Balance `_bal_correction()`** — New sign-aware PD function that outputs signed correction values. Positive values push left/forward, negative push right/backward, enabling the input hook to apply corrections in the correct direction.

### Removed
- **`mod._bal_axis()`** — Replaced by `_bal_correction()` with correct velocity handling and signed output.
- **Balance `lazy` variable** — Unused dead code in old `_bal_axis()`.
- **Balance old `mod._speed_scale("balance_solve_speed")` calls** — Replaced by dedicated `_balance_profile()` with per-speed parameters.

## [1.6.0] - 2026-06-24
### Added
- **Expedition POI Auto-Mark** — Automatically marks the nearest opportunity (objective) on the expedition map without pulling out the auspex. Polls every second; when the marked POI is completed, marks the next nearest. Manual marks are respected (auto-mark pauses), manual unmarks are respected (skips that POI). Only targets opportunities — exits and extractions are never touched. Optional: auto-mark vault when all POIs are done. Default: off, notifications on.
- **Speed slider (1–10)** — All four auto-solve speed settings (Decode Search, Tree Drill, Frequency, Balance) now use a numeric slider from 1 (slowest) to 10 (instant) instead of the old "Human speed" / "Inhuman speed" dropdown. 10 levels instead of 2. Old "Human speed" → 3, old "Inhuman speed" → 10.
- **Balance speed scale** — `mod._speed_scale(id)` converts slider value (1–10) to a 0–1 scale used by all solvers for smooth interpolation of timing, strength, and noise parameters.

### Changed
- **Balance solver — rewritten to scale-based**: Old code checked `speed == "human"` / `"inhuman"` with fixed constants. New code uses the slider's 0–1 scale to smoothly interpolate PD gain (0.3–1.0), EMA lag (0.02–0.50), lazy deadzone (0.15–0.40), skip chance (0–20%). At speed 1 it's sluggish with visible lag; at speed 10 it holds center perfectly.
- **Frequency solver — rewritten to direct API calls**: Old code hooked `InputService._get` for `action == "move"`, but the game never calls `_get("move")` — movement is composed from four cached directional inputs. This meant frequency auto-solve was **non-functional**. Now calls `mg:on_axis_set()` for steering and `mg:test_frequency()` (server) / `mg:on_action_pressed()` (client) for submission from `on_update`.
- **Drill solver — reverted to InputService overrides**: Direct API calls (`mg:on_axis_set()`) don't work for Drill because `MinigameDrill.on_axis_set` bails on client. Reverted to InputService-override approach: `_drill` in the input hook overrides `move_right`/`move_left`/`move_forward`/`move_backward` through the character state machine to the server's `on_axis_set`. Cursor movement works both offline and online.
- **Drill — cooldown moved to InputService throttling**: Per-move cooldown was in `on_axis_set` hook (no effect online). Now enforced in `_drill` input hook: during cooldown, directional overrides return 0. Cursor position tracking in `on_update` sets cooldown when cursor changes via RPC-synced `cursor_position()`.
- **Decode Search — submission cleanup**: `on_update_exp` called `mg:on_action_pressed(t)` (no-op on client) and set `_exp_submitted_stage`, blocking the working InputService path. Removed submission logic from `on_update_exp` — `_expedition` now handles all pressing.

### Fixed
- **Drill & Decode Search — cursor teleporting**: When cooldown blocked `on_axis_set`, `_last_axis_set`/`_last_move` weren't updated. First unblocked call had `dt ≈ cooldown_duration`, causing instant jump to target. Fixed by calling `func(self, t, 0, 0)` during cooldown to update timestamps without moving.
- **Darktide patch compatibility — `player_slot_by_level_marked` removed**: Navigation handler API renamed from singular `player_slot_by_level_marked` to plural `player_slots_by_level_marked`. Returns `(table, count)` instead of `slot_or_nil`. All expedition map code updated.
- **Darktide patch compatibility — stale Vector3**: `POSITION_LOOKUP[unit]` returns stale Vector3 references. Expedition map now uses `Unit.world_position(unit, 1)` for fresh positions.

### Removed
- **Frequency `_freq_press_until`, `_freq_release_until`, `_freq_speed`**: No longer needed since the solver uses direct API calls.
- **Decode Symbols `_ds_count` and `_ds_cool`**: Old integer-counter state machine (replaced by `_ds_armed` boolean in 1.4.6, vestigial code remained).
- **`_bal.speed` string field**: Replaced by `bal.scale` numeric field.

## [1.5.0] - 2026-06-19
### Added
- **Practice Mode** — Standalone overlay for manual minigame training without auto-solvers. Press F10 to open in Mourningstar or Psykanium (not available during missions). Supports all five minigames: Decode Symbols, Decode Search (Matching), Tree Drill, Frequency Matching, and Train (Balance). Auto-solvers are disabled during practice; highlights and visual aids are suppressed so you train with the same information as the real game. Each practice session tracks your completion time and reports it in chat (e.g. "Finished Tree Drill in 12.45 seconds!").

### Details
- **Decode Symbols practice** — Sweeping cursor, press to lock in the correct column. Same timing window as the real game. Plays success/fail sounds and reports completion time.
- **Decode Search (Matching) practice** — Grid-based matching puzzle with 250ms cursor movement delay matching the real game. Move to a region and press to check the pattern.
- **Tree Drill practice** — Cursor snaps between target circles using angular targeting (±60° cone). Move to aim, press to start the scan timer, press again to confirm when the ring fills. Wrong answers play fail sound and stay on the same stage.
- **Frequency Matching practice** — Waveform matching with dt-based input. Move your waveform to overlap the target waveform, then press to submit. Keyboard input uses 0.4× sensitivity for precise control. Wrong answers advance back one stage with a new random target.
- **Train (Balance) practice** — Continuous real-time balancing challenge. Outward push force stronger near center, random disruptions every 1.6s, hard wall at radius 1.02. Progression takes ~20 seconds of cumulative time inside the zone. Harder than the real game (push ratio 2.2×, disruption power 1.0, interval 1.6s).
- **Movement blocking** — Character does not move while using WASD during practice. Input is routed to the minigame only.
- **Settings** — Enable/disable practice mode (default: off), choose minigame type, rebind toggle key (default: F10).
- **Sound effects** — All practice minigames play real game sounds via direct Wwise events: selection, progress, fail, frequency adjust, balance stall alerts.
- **Location restriction** — Practice mode only activates in the Mourningstar hub and Psykanium. Attempting to open it in a mission shows a chat message.

## [1.4.7] - 2026-06-15
### Fixed
- **Decode Symbols — Edge-column misses at moderate ping**: `prec = 0.3` left only 100ms margin between detection-window edge and game-window edge at edge columns (1, 7). Users at ~100ms one-way latency hitting the window boundary experienced "just barely hits it, goes back up" glitches. Reverted to `prec = 0.35` — 0.1s window centered with 117ms margin at edges, reliable up to ~234ms RTT at any column position.

## [1.4.6] - 2026-06-15
### Fixed
- **Decode Search (Matching) — Duplicate submit under RPC latency**: After auto-submitting a correct match, the server's RPC takes 50–150ms to advance the stage. During this window `_current_stage` is unchanged on the client, so `_expedition` could attempt a duplicate submit on the same stage. Now tracks `_exp_submitted_stage` to prevent re-submission until the RPC confirms the stage has advanced.
- **Decode Symbols — Missed presses under latency**: Pre-press cursor verification in the input hook caused false negatives — the 16ms gap between the view's `is_on_target` call and the input poll was enough for the cursor to leave the detection window at 30fps or high latency. Removed the pre-press check entirely; the centered detection window and 150ms cooldown are sufficient to prevent double-presses.

### Changed
- **Decode Symbols — Simplified state machine**: Replaced `_ds_count` (integer counter) with `_ds_armed` (boolean). Removed `_ds_count_same()` helper, removed `_ds_mg` reference (no longer needed without pre-press), dropped unused `off` parameter from `_ds_on_target`. Input hook is now 11 lines; `is_on_target` hook is 6 lines.
- **Decode Symbols — Detection window**: `prec` constant changed from 0.35 to 0.3 for a standardised 0.13s window centered in the game's 0.333s window. Same ping reliability, no magic numbers.

## [1.4.5] - 2026-06-14
### Fixed
- **Decode Symbols — Online timing accuracy**: Detection window was the full 0.333s game window, making the press point random within the column. On high ping (>100ms RTT), presses detected near the window edge arrived at the server after the cursor had already left the game's validation window, causing misses. Now uses a centered `prec = 0.35` filter (0.1s window centered in the game's 0.333s window), ensuring detection always occurs close to center with maximum ping margin in both directions. Reliable up to ~280ms RTT.
- **Decode Symbols — Double-presses at high ping**: With the wide window, 150ms cooldown expired while the cursor was still in view, triggering re-detection of already-solved rows before the server RPC updated `_current_stage`. Fixed with `_ds_pending_stage` / `_ds_pressed_stage` stage tracking: the input hook refuses to press for a stage it has already pressed, and the guard clears automatically when `set_current_stage` RPC arrives.
- **Decode Symbols — Pre-press cursor verification**: The `_ds_mg` reference (set in `start`) is passed to the input hook so it can call `_ds_on_target` immediately before pressing — if the cursor has already left the window, no press occurs and the cursor continues sweeping.

### Changed
- **Decode Symbols — Removed 40ms sustained press**: Press is now single-frame (previously was 40ms `_ds_press_deadline`). Removes 40ms of additional latency that compounded with network delay. Dead code cleaned: `DS_PRESS_HOLD`, `DS_PRESS_GAP`, `_ds_press_window()`, `_ds_cool()`, and deadline tracking removed from `on_update`.
- **Decode Symbols — Removed FixedFrame clock**: Reverted `_calculate_cursor_time` to use the view's `t` parameter (`gameplay_time`) instead of `FixedFrame.get_latest_fixed_time()`. The FixedFrame approach was 16-30ms stale on clients, causing late detection that added to ping latency. Removed `require("scripts/utilities/fixed_frame")` dependency.
- **Decode Symbols — Tooltip**: Updated to note ~280ms ping reliability so users on very high-ping servers can disable auto-solve.

## [1.4.3] - 2026-06-14
### Fixed
- **Decode Search (Matching) — Human speed**: Cooldown was set on every `on_axis_set` call, including zero-input and on-target frames, causing up to 1.875s of wasted dead time at the start of each stage. On small 2×2 boards this made auto-move appear non-functional. Fixed by only setting cooldown when `on_axis_set` actually changes the cursor position.
- **Defense-in-depth**: `mod._exp_move_cooldown` is now initialized in `NoBrainer.lua` alongside all other state, and all reads are nil-guarded.
- **Drill — Human speed**: Same cooldown bug as Decode Search — `on_axis_set` set cooldown on every call, including zero-input frames. Fixed by only setting `_drill_move_cooldown` when cursor position actually changes.
- **Defense-in-depth**: `mod._drill_move_cooldown` initialized in `NoBrainer.lua` alongside other state.
### Changed
- **Balance (Train) — Inhuman mode**: Increased damping coefficient (Kd 0.89→0.95) and added light inward-velocity damping to prevent center overshoot. Tighter control, less wobble.
### Performance
- Balance human-EMA gated behind `st.timer > 0` so it stops after the minigame ends.
- Decode Symbols input: `time("gameplay")` moved after `_ds_count`/`_ds_cooldown` guards.
- `_decode_layout` returns cached table instead of allocating per frame.
- Frequency highlight: `math.rad()` constants moved to module level.
- Input hook skips all 7 solvers via `_any_minigame_active()` gate when no minigame is active.
- Input hook: global references (`Managers`, `math.*`) localized to module scope.

## [1.4.1] - 2026-06-14
### Fixed
- **Auspex Scan — Stale highlights**: When the auspex minigame completed, the mod's 1-second refresh loop kept re-applying `set_scanning_outline(true)` and `set_scanning_highlight(true)` on scannable objects even after no scanning zone was active — leaving highlighted objects visible to the mod user that no one else could see. Fixed by guarding the highlight refresh with `sys:any_active_scanning_zone()`. Highlights are now cleared immediately when the scanning zone is no longer active.

## [1.4.0] - 2026-06-13
### Added
- **Frequency Matching** — Directional arrows highlight which way to push the waveform toward the correct target.
- **Frequency Matching — Auto-Solve**: Automatically steers the waveform to the target and submits. Two speed modes: Inhuman (instant) and Human (delayed reactions with natural wobble).
### Fixed
- **Decode Search (Expedition) (Human speed)** — `_exp_move` no longer computes movement vector during cooldown. Early-return on `_exp_move_cooldown > 0` saves ~10 table-lookups per frame while movement is blocked by `on_axis_set`.
- **Balance (Train)** — Online play caused velocity spikes from RPC bursts, making the Inhuman solver oscillate between edges. Raw velocity is now clamped at ±10 (was ±50) and EMA-smoothed (alpha 0.30) so a single burst cannot saturate the D-term.

## [1.3.0] - 2026-06-09

### Added
- **Auspex Scan — Auto-Scan**: Holds the scan action for the full 1s duration automatically.
- **Auspex Scan — Scannable refresh**: Scannable objects list refreshed every 1s so new targets get highlights.

### Fixed
- **Auspex Scan — Unwield cleanup**: Highlights removed when scanner is put away.
- **Auspex Scan — Auto-Scan stalling**: Replaced `_completed_scanning` override with a time-based hold. Keeps `action_one_hold=true` for 1.15s so the game's 1s confirm timer completes naturally.
- **Auspex Scan — Shared table reference**: `scannable_units()` returns a static table cleared every frame. Mod now copies data into its own table.
- **Auspex Scan — is_active guard**: Input hooks check `is_active()` before triggering.
- **Auspex Scan — Weapon-action guard**: Input simulation checks `current_action == "action_scan"`.
- **Auspex Scan — Alive guard**: `_set_hl` checks `Unit.alive(unit)` before accessing extensions.
- **Auspex Scan — Debounce cooldown**: 300ms debounce prevents re-trigger from LOS flicker.
- **Auspex Scan — State cleanup**: `last_target`, `_scan_auto_pending`, and cooldown cleared on weapon change.
- **Decode Symbols — Online timing**: The `is_on_target` view hook receives `gameplay_time` but the game's `_decode_start_time` uses the `FixedFrame` clock synced between client and server. These clocks diverge online (30-100ms), so the cursor position computed by the mod was off by that amount — causing presses too early or too late. Now uses `FixedFrame.get_latest_fixed_time()` to compute the exact same cursor position the server validates against. Also added a pre-press verification in the input hook that double-checks the cursor is still in the target window before pressing, eliminating edge-column misses and "click randomly" behaviour.
- **Decode Search (Expedition)** — Cursor now moves one axis at a time instead of diagonal. Diagonal movement skipped over columns too quickly.

## [1.2.0] - 2026-06-10

### Added
- **Auto-Balance Speed** setting — "Inhuman speed" (instant) or "Human speed" (delayed reaction with noise). Default: Human speed.

### Fixed
- **Decode Symbols** detection window was ~0.2s instead of the game's 0.333s — `prec = 0.2` artificially narrowed both sides of the formula. Now matches `MinigameDecodeSymbols.is_on_target` exactly.
- **Decode Symbols** cooldown row 2 failure — final press cooldown was only 60ms, too short for the server RPC to update `_current_stage` before the cursor swept past the next row. Now 150ms.
- **Decode Symbols** network race — `_ds_stage_done` guard caused permanent lock when stage bounced back (e.g., 3→4→3). Fixed with auto-clear and unconditional `set_current_stage` clear.
- **Decode Symbols** interact-bleed — player's `interact` from opening the minigame leaked into auto-solve. Input hook now clears and returns original value so `_action_held` initialises correctly.
- **Decode Symbols** highlight crash — `mg:current_stage()` could return `nil` in race between `start` and `setup_game`. Added nil-guard.
- **Balance** failed on multi-click runs due to fixed strain modifier interaction.

### Changed
- **Decode Symbols** press timing: hold 40ms, gap 60ms between multi-presses, cooldown 150ms.
- Removed `_ds_networked()` — timing constants now work identically for network and singleplayer.

### Removed
- **Expedition (Decode Search) — Auto-Solve Speed** setting (hardcoded to Human speed internally).

## [1.1.0] - 2026-06-08

### Added
- **Auto-Solve Speed** setting for Expedition (Decode Search) puzzle — choose between "Inhuman speed" (instant, as before) and "Human speed" (1.875 seconds per cursor move). Default: Human speed.
- **Auto-Solve Speed** setting for Drill (Tree) puzzle — choose between "Inhuman speed" (instant, as before) and "Human speed" (2 seconds per cursor move). Default: Human speed.

### Changed
- Drill puzzle movement is now throttled via `MinigameDrill.on_axis_set` hook instead of InputService, ensuring the game's internal move system works correctly with the speed limiter.
- Expedition puzzle movement is now throttled via `MinigameDecodeSearch.on_axis_set` hook for the same reason.

### Removed
- **Drill Step Delay** setting from mod options (hardcoded to 150ms internally).
