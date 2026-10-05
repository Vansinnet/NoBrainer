# NoBrainer

Current release: **3.2.0**.

A Darktide Mod Framework (DMF) mod that assists with several in-game minigames.

## Features

- Decode Symbols highlights and automatic timed input, with an optional Smart Seed Reroll.
- Decode Search highlights matching regions and can solve the puzzle automatically.
- Tree Drill highlights correct nodes and can automate movement and confirmation.
- Frequency highlights the target and can automate steering and submission.
- Balance uses predictive steering assistance.
- Auspex Scan highlights eligible targets and can confirm scans automatically.
- Skitarius Servo Skull can automatically order an available servo skull to hack nearby terminals.

Decode Symbols, Decode Search and Drill use the same solvers as BetterBrainer 1.0.3: every decision is made once per input frame sent to the server, and against a remote server Search and Drill press only after the server has shown that it processed later, timely input, so lag costs time but not a wrong press. At speed 5, Search and Drill send the next stage's first move during the stage transition.

The mod offers English, Simplified Chinese, Traditional Chinese, and Russian localization. Feature settings can be changed in the DMF options menu.

## Installation

1. Install Darktide Mod Framework using its normal installation workflow.
2. Deploy this mod so the installed directory is named `NoBrainer`.
3. Add `NoBrainer` to the installed `mod_load_order.txt`.
4. Launch Darktide and configure the mod from the DMF options menu.

Do not enable NoBrainer together with another mod that automates the same minigame input, including BetterBrainer.

## Downloads

Download `NoBrainer.zip` from the [latest release](https://github.com/Vansinnet/NoBrainer/releases/latest). It contains one installed `NoBrainer` folder with its `.mod` manifest, required `scripts/` files, README and MIT license. Do not use GitHub's automatically generated source-code archives for installation.

## Development

The source mod lives in this repository root. Run the workspace validation from the Darktide mods workspace:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "tools\validate.ps1" -Path "mods\active\NoBrainer"
```

Release archives are intentionally excluded from version control. Build releases only from the validated mod directory using the workspace release workflow.

## Credits

- Simplified Chinese translation by EasyRain233.
- Traditional Chinese translation credits are retained in the localization source.

## License

Licensed under the [MIT License](LICENSE).
