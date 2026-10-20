# everything-shortcut

everything-shortcut is a macOS menu bar app that brings Vimium-style link hints to the whole screen.
Press Cmd-Shift-Space, and every visible clickable element gets a yellow label.
That covers background windows that are not covered, the frontmost app's menu bar, menu bar extras, and the Dock.
Type a label's letters to click its element.
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
Its icon comes from `es-dev icon`, which draws the app icon from the badge code on every build.

## Run

```sh
open build/EverythingShortcut.app
```

The app lives in the menu bar and has no Dock icon while its window is closed.
Its menu shows the Accessibility status, the shortcut and whether it registered, "Show Labels", "Settings…", and "Quit".
Without Accessibility, the first line is "Allow Accessibility…", which opens the window at that step.
The window changes the shortcut, which takes effect without a restart, shows whether Accessibility is allowed, and turns Launch at login on or off.
Opening the app again while it runs, for example with `open build/EverythingShortcut.app`, also shows the window.
That matters when macOS hides the status item behind the notch on a full menu bar.

## First launch

The app reads other apps' interfaces and posts clicks, so it needs Accessibility.
Open Everything Shortcut.
Its window lists three steps, and every step your Mac already satisfies is checked.

1. Accessibility.
   Press Return (Open System Settings) and turn on Everything Shortcut.
   The window comes back by itself.
2. Shortcut.
   ⇧⌘Space is checked when it works.
   Click it and press another chord to change it.
3. Try it.
   Press ⇧⌘Space, then type the yellow label on Click Me.

Press Return for Done, or click Skip Setup at any time.
After that, the window opens at launch only while Accessibility is off.
The window is also Settings.
Choose Settings… from the ⌨ icon in the menu bar, or open the app again, to come back.
If the menu bar is full, macOS hides the icon, and opening the app again is the way back.

The bundle id and the signing identity stay the same on every build, so the grant survives rebuilds.
An ad hoc signature would reset it on each build.

## Check it end to end

```sh
scripts/e2e.sh
```

The script bundles the DEBUG app, starts it with `--automation`, and runs `es-dev e2e` against two fixture windows, then against the app's own window.
It prints `VERIFIED` or `NOT VERIFIED` for each check and saves a screenshot of the badges under `build/e2e/`.
Run it unlocked, on a desktop Space, because a full-screen Space hides the fixture windows, and es-dev stops early with exit 2 when it sees either.
The automation hook exists only in DEBUG builds.

## Read more

- `docs/design.md` explains the architecture and its tradeoffs.
- `docs/research.md` collects the sources behind the design.
