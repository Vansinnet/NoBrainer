# NoBrainer design notes

## Structure (4.0.0)

NoBrainer is BetterBrainer plus the Skitarius servo-skull command (user decision, 2026-10-14). Design, mechanisms and source contracts of the solvers are in `mods/active/BetterBrainer/DESIGN.md`; this file covers only what differs.

- `NoBrainer.lua`: BetterBrainer's core (`BetterBrainer.lua`). It has the ModID, path and data-file names changed, a one-time migration of 3.1-era speed settings (`_speed_schema_v2`), and the servo skull module, which `mod.update` calls every frame while the mod is enabled.
- `symbols.lua`, `search.lua`, `drill.lua`, `frequency.lua`, `balance.lua`, `scan.lua`: identical copies of BetterBrainer's modules. Keep them identical: change BetterBrainer first, then copy.
- `servo_skull.lua`: NoBrainer's servo-skull command as a core module (`return function(ctx) ... end` with `update(dt, t)`, `reset`, `settings_changed`). It reads `ctx.settings`; its logic is unchanged from 3.2.0.
- `NoBrainer_data.lua`, `NoBrainer_localization.lua`: BetterBrainer's options and strings plus the servo skull group, with NoBrainer's name and description.

Never enable NoBrainer and BetterBrainer together: both automate the same input.

## Decisions

- 2026-10-14 (user): replace every NoBrainer solver with BetterBrainer's current version. Keep the servo skull feature.
  - Removed with the old solvers: Smart Seed Reroll (superseded by `decode_reroll_limit`), NoBrainer's own Frequency, Scan and Balance solvers, the legacy input route and its restart recovery.
  - Setting ids are shared with BetterBrainer, so saved values carry over; `enable_decode_smart_reroll` is no longer read.
- Defaults as in BetterBrainer: `decode_reroll_limit` 0 and `enable_expedition_reopen` off (user decision 2026-10-14).

## Runtime status

- In game: BetterBrainer's Symbols reroll and Search transition skip were reported working by the user on 2026-10-14.
- NoBrainer 4.0.0 itself, the servo skull module in its new form, and the Frequency pipeline are not yet tested in game.
- Smallest test, as a client in a regular mission:
  1. Hack a terminal with each solver you meet.
  2. As Skitarius with the hacking servo skull, walk within 25 m of a hackable terminal: the skull should be ordered to it.

## Open items

- 2026-10-14: `NoBrainerDebug` read the old solvers through `mod._frame_snapshot()`, which no longer exists. The companion needs updating before it can observe 4.0.0; it never ships.
