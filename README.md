# NoBrainer

Current release: **4.1.0**.

A Darktide Mod Framework (DMF) mod that assists with Darktide's minigames. NoBrainer is BetterBrainer, included as a git submodule, plus NoBrainer's own Smart Seed Reroll and Skitarius servo-skull command.

## Features

- **Decode Symbols:** timed automatic presses and upcoming-solution highlights. Optionally rerolls slow boards: every opening deals a new board, so a board expected to take clearly longer than reopening and playing a fresh one makes the terminal close and reopen. `Reroll Slow Boards` sets the most rerolls per hack (0-8, default 0 = off; 8 is fastest on average).
- **Smart Seed Reroll** (NoBrainer, default on): each terminal deals its boards from one seed. When NoBrainer knows that seed, rerolls are decided from the exact upcoming boards instead of the average board, and a board is rerolled only when the known next boards are expected to be faster. The host reads the seed; a client rebuilds it from the boards it has seen. Without a known seed, the average board is used. It shares the `Reroll Slow Boards` limit, so it does nothing while that is 0.
- **Decode Search:** matching-region highlights and an automatic solver. At speed 5 with `Skip Stage Transitions` (default off), the terminal closes and reopens right after each solved stage: the reopened session keeps the stage and starts at once with the cursor in the centre, instead of waiting for the 0.25-second transition.
- **Tree Drill:** correct-node highlights; movement and submission planned with the game's own node-selection rule.
- **Frequency:** directional arrows and direct submission of the target. At speed 5 it does not steer. When the board seed predicts targets 2 and 3 unambiguously and the server confirms it ran the session's first frame on its own input, all three tests are sent at once.
- **Balance:** latency-aware predictive steering.
- **Auspex Scan:** highlights scannable objects and confirms scans automatically while aimed at one.
- **Skitarius Servo Skull** (NoBrainer): orders an available hacking servo skull to the nearest hackable terminal within the command range (optionally only in line of sight).

Every solver decides once per input frame sent to the server. Against a remote server, Search and Drill press only after the server has shown it ran later, timely input, so lag costs time but not a wrong press.

Reopening (Symbols rerolls and Search transition skips) only acts on a decoder terminal the interactor already sees. It switches itself off for the rest of the mission after a refused or missing re-entry. Teammates see the auspex close and reopen.

The mod offers English, Simplified Chinese, Traditional Chinese and Russian localization. All settings are in the DMF options menu.

### Upgrading from 3.x

- Smart Seed Reroll keeps its setting and value. The `Reroll Slow Boards` limit now caps it, instead of a fixed two rerolls.
- Every other setting keeps its id and value; speeds saved by NoBrainer 3.1 and earlier on the old 1-10 scale are still migrated once.
- The Frequency, Scan and Balance solvers are now the BetterBrainer versions.

## Installation

1. Install Darktide Mod Framework using its normal installation workflow.
2. Deploy this mod so the installed directory is named `NoBrainer`.
3. Add `NoBrainer` to the installed `mod_load_order.txt`.
4. Launch Darktide and configure the mod from the DMF options menu.

Do not enable NoBrainer together with BetterBrainer or another mod that automates the same minigame input.

## Downloads

Download `NoBrainer.zip` from the [latest release](https://github.com/Vansinnet/NoBrainer/releases/latest). It contains one installed `NoBrainer` folder with its `.mod` manifest, its `scripts/` files and the `BetterBrainer/` scripts it runs. Do not use GitHub's automatically generated source-code archives for installation: they leave the submodule out.

## Development

The source mod lives in this repository root. BetterBrainer's files come from the `BetterBrainer` submodule, so clone with submodules:

```powershell
git clone --recurse-submodules https://github.com/Vansinnet/NoBrainer.git
# or, in an existing clone:
git submodule update --init
```

To take a newer BetterBrainer, move the submodule to that commit (`git -C BetterBrainer pull`, then commit `BetterBrainer`). Never edit files inside the submodule from this repository.

`tests/README.md` lists the offline suites. Release archives are not kept in version control; the GitHub release workflow builds them.

## Credits

- The solvers are BetterBrainer's, by the same author, included unchanged as a submodule.
- Simplified Chinese translation by EasyRain233.
- Traditional Chinese translation credits are retained in the localization source.

## License

Licensed under the [MIT License](LICENSE).
