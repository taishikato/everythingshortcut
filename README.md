# everything-shortcut

everything-shortcut is a macOS menu bar app that brings Vimium-style link hints to the whole screen.
Press Cmd-Shift-Space, and every visible clickable element gets a yellow letter badge.
That covers background windows that are not covered, the frontmost app's menu bar, menu bar extras, and the Dock.
Type a badge's letters to click its element.
Escape, the trigger again, or any mouse click cancels, and Backspace removes one letter.

## Requirements

- macOS 15 or later.
- Xcode with Swift 6.2 or later.
- A code signing identity for the app bundle.
  `scripts/bundle.sh` uses `Apple Development: Taishi Kato (3J26NQ6DYQ)` unless `ES_SIGNING_IDENTITY` names another.

## Build

```sh
swift build
swift test
scripts/check-invariants.sh
scripts/bundle.sh debug      # or release
```

`scripts/bundle.sh` writes `build/EverythingShortcut.app` and signs it last.

## Run

```sh
open build/EverythingShortcut.app
```

The app lives in the menu bar and has no Dock icon.
Its menu shows the Accessibility status, the trigger chord and whether it registered, "Show hints", "Settings…", and "Quit".
Settings changes the trigger chord, which takes effect without a restart, shows the Accessibility and trigger status, and turns Launch at login on or off.
Opening the app again while it runs, for example with `open build/EverythingShortcut.app`, also shows Settings.
That matters when macOS hides the status item behind the notch on a full menu bar.

## Grant Accessibility once

The app reads other apps' interfaces and posts clicks, so it needs Accessibility.
On first launch it shows the system prompt.

1. Open System Settings, then Privacy & Security, then Accessibility.
2. Turn on EverythingShortcut.

The bundle id and the signing identity stay the same on every build, so the grant survives rebuilds.
An ad hoc signature would reset it on each build.

## Check it end to end

```sh
scripts/e2e.sh
```

The script bundles the DEBUG app, starts it with `--automation`, and runs `es-dev e2e` against two fixture windows.
It prints `VERIFIED` or `NOT VERIFIED` for each check and saves a screenshot of the badges under `build/e2e/`.
Run it unlocked, on a desktop Space, because a full-screen Space hides the fixture windows, and es-dev stops early with exit 2 when it sees either.
The automation hook exists only in DEBUG builds.

## Read more

- `docs/design.md` explains the architecture and its tradeoffs.
- `docs/research.md` collects the sources behind the design.
