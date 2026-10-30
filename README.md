# everythingshortcut

Click anything on your Mac without touching the mouse.

Press ⇧⌘Space and every button, link, menu and Dock icon on your screen gets a short yellow label.
Type a label's letters and everythingshortcut clicks that item for you.

**[Download for macOS](https://everythingshortcut.com)** · [Try it in your browser](https://everythingshortcut.com/#demo)

## Who it's for

- Keyboard-first Mac users who already launch apps with Raycast or Alfred and still reach for the trackpad for the last few clicks.
- Vimium users who want the same labels outside the browser, in Finder, System Settings, Slack or the Dock.
- Anyone who would rather keep both hands on the keyboard, for speed or for comfort.

## What it does

- **Every window on screen, not just the front one.**
  Click a button in a window behind the one you're typing in, and that window comes forward like it would for a real click.
- **The menu bar and the Dock.**
  App menus, the icons on the right of the menu bar and the Dock all get labels.
- **Web pages.**
  Links and buttons in Chrome and in apps built with Electron get labels.
- **Any keyboard layout.**
  Labels type the same with Dvorak, or with Japanese input turned on.
- **Fast.**
  In testing, labels for a full screen appear in about a quarter of a second.

## Private and safe to leave running

- It has no network code.
  It reads the screen through macOS Accessibility, on your Mac, and nothing leaves it.
- Labels won't open while a password field is active, so letters meant for a label can't land in it.
- It is free and open source under the MIT License, so you can read the code you give Accessibility access to.

## Install

1. Download the zip from [everythingshortcut.com](https://everythingshortcut.com) and open it.
2. Move Everything Shortcut to your Applications folder and open it.
3. The setup window walks you through three steps: allow Accessibility, check the shortcut, and try one label.

It needs macOS 15 or later, on Apple silicon or Intel.
The download is signed with a Developer ID and notarized by Apple.

## Use it

| Key | What happens |
| --- | --- |
| ⇧⌘Space | Labels appear on everything you can click. |
| A label's letters | The item is clicked the moment you finish its label. |
| Backspace | Removes the last letter you typed. |
| Escape, ⇧⌘Space again, or a mouse click | Closes the labels. |

The app lives in the menu bar as a small "ES" icon and has no Dock icon.
Its menu opens Settings, where you can change the shortcut and turn on Launch at login.
If a crowded menu bar hides the icon behind the notch, open the app again from Applications to get to Settings.

## What doesn't get a label yet

- Some apps draw their own controls in a way macOS doesn't report as buttons, and those get no label.
- Open context menus and pop-up menus don't get labels yet.
- The first time you press the shortcut in Chrome or an Electron app after it launches, the page itself may get no labels.
  Press it again a couple of seconds later and they appear.

Found something else?
[Open an issue](https://github.com/taishikato/everythingshortcut/issues).

## Build from source

```sh
swift build
scripts/bundle.sh debug
open build/EverythingShortcut.app
```

[CONTRIBUTING.md](CONTRIBUTING.md) covers the tests, the end-to-end check, code signing and releases.
[docs/design.md](docs/design.md) explains how it works.

## License

[MIT](LICENSE)
