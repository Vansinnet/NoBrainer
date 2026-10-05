# NoBrainer 3.2.0

## Changes

- Decode Search, Drill and Decode Symbols now use BetterBrainer 1.0.3's frame-based solvers, integrated with NoBrainer's existing settings and features.
- Search and Drill wait for the server to have processed later, timely input before submitting after movement. Search waits for recentring on reopen; Drill gains improved aim planning, acknowledgement and lost-move recovery, including the origin-target fix.
- At speed 5, Search and Drill send the next stage's first move during the transition. Symbols uses the full native hit window with a 30 ms margin and up to two presses awaiting receipts.
- Smart Seed Reroll is retained and adapted to the new Symbols solver.
- Frequency waits for fresh opening receipts and starts sooner at higher speeds. After an interrupted scan, a different target can be acquired immediately while the same target retains its retry delay.
- Read-only solver snapshots support the separate development companion. NoBrainerDebug is not included or required.

Settings, defaults, ranges and translations are unchanged. Do not enable NoBrainer and BetterBrainer together.

## Installation

Download **NoBrainer.zip** from this release. Extract the `NoBrainer` folder into the game's mods directory and keep `NoBrainer` in `mod_load_order.txt`. Darktide Mod Framework is required. GitHub's automatic source-code archives are not installation packages.

## Validation and runtime coverage

- Release date: 2026-10-05. Authoritative source: `mods/active/NoBrainer/`; installed folder and ModID: `NoBrainer`. Manifest script/data/localization paths resolve under that folder; package list is empty and there is no debug-tool dependency.
- Offline tests rerun with Windows LuaJIT 2.1.1703358377 against Darktide 1.13.0 Lua source: Search 21/21, Drill 36/36, speed/receipt cases 56/56, NoBrainer integration 7/7, scan retry 3/3 (**123 passed, zero failed**). The speed suite skips 17 BetterBrainer-only Frequency/Scan cases. These are mocked offline results, not in-game measurements. The earlier reroll phase harness results are recorded in `tests/README.md`.
- Settings/localization check: 59 references resolve and format successfully in English, Simplified Chinese, Traditional Chinese and Russian.
- The normal `tools/release-mod.ps1 -Mod NoBrainer -OutputDirectory releases/NoBrainer-v3.2.0` check ran LuaLS at Warning level and failed with **240 warnings**: 239 undeclared/injected dynamic `mod._*` fields, including the new snapshot field, plus the pre-existing `NoBrainer_input.lua:150` scanner `tonumber` type warning. That assignment is unchanged, is guarded by a successful conversion and reads the scanner's numeric `confirm_time`. The nonzero LuaLS result is reviewed and accepted for this release, as in 3.1.7; it is not a clean Warning-level pass.
- Build command after reviewing the report: `powershell -NoProfile -ExecutionPolicy Bypass -File tools/release-mod.ps1 -Mod NoBrainer -OutputDirectory releases/NoBrainer-v3.2.0 -SkipLuaLS`. The canonical wrapper passed LuaJIT loading and secondary `luac55.exe -p` checks for **all 13 runtime Lua files plus the manifest**. LuaLS was already run and reviewed; the successful build invocation skips only that repeated gate.
- Core hook signatures and input/server-state flow were rechecked against current 1.13.0 `human_input_handler.lua:169-215,232-283`, `player_character_state_minigame.lua:87-125,138-217`, `input_service.lua:421-474`, `player_unit_data_extension.lua:984-991,1022-1061`, `authoritative_player_input_handler.lua:124-201`, and DMF `core/hooks.lua:195-205`. Concrete minigame receipt signatures and current RPC calls were checked in the minigame implementations and `minigame_system.lua:133-195`. Existing deferred engine contracts remain in workspace `types/CONTRACTS.md`; no engine API contract changed during release preparation.
- Optional solver logging remains gated through DMF debug logging. No temporary commands, probes or captures were added.
- **User-tested in game:** on 2026-10-05 the user confirmed that all new changes work. Exact game build, mission, network role, settings and lifecycle coverage were not specified. The agent did not independently inspect a deployed/running build; this is the user's in-game result for NoBrainer, not an inference from BetterBrainer or the offline tests.
- Remaining context-specific coverage, if not already covered by that test: dedicated-server client at speed 5, Search including reopen, Drill, Symbols with Smart Seed Reroll on/off, Frequency and scan; then solo at speed 1 and disable/re-enable at a stage transition. Menu/hub/options, Psykanium/host/solo, reload, exit/next mission and cleanup/performance coverage are unspecified. Native transport ordering (minigame receipts before subsequent server state), prediction/rollback and lifecycle behavior are not independently verified. See `DESIGN.md`.

## Archive inspection and hashes

- Local archive: `releases/NoBrainer-v3.2.0/NoBrainer.zip`, built by the canonical Standard profile.
- All 16 ZIP entries were listed and reviewed: one `NoBrainer/` root containing `NoBrainer.mod`, 13 required `scripts/mods/NoBrainer/*.lua` files, `README.md` and `LICENSE`. Every path uses `/`. Each uncompressed entry's SHA-256 was independently compared to its authoritative source file: **16/16 match**.
- Tests, CHANGELOG, DESIGN, this release record, PUBLISHING, Git/GitHub metadata, workspace types/tools, backups, captures, generated bytecode, LuaExec and NoBrainerDebug are excluded. Source symlinks/reparse points and secret-bearing payload filenames are rejected by the wrapper.
- Source-file manifest: `releases/NoBrainer-v3.2.0/NoBrainer.source.sha256` (also attached to the GitHub release). Archive hash record: `releases/NoBrainer-v3.2.0/NoBrainer.zip.sha256` (also attached).

SHA-256 (`NoBrainer.zip`):

```text
0F907B0FB4E8BA844650848C627326A3ADF65F5805265346B3CAB5A2107E8411
```

Source: https://github.com/Vansinnet/NoBrainer/tree/v3.2.0. The release tag points to the source commit containing this record; runtime source includes commits `a8b43f3` and `8b4479f`.

Rollback: install the retained [3.1.7 release](https://github.com/Vansinnet/NoBrainer/releases/tag/v3.1.7); its source is commit `e5499d6`. The installed folder and settings ModID are unchanged.
