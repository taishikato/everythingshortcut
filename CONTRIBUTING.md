# Contributing

Issues and pull requests are welcome.
For a larger change, open an issue first so we can agree on the approach.
[docs/design.md](docs/design.md) explains the architecture and its tradeoffs, and [docs/research.md](docs/research.md) collects the sources behind it.

## Requirements

- macOS 15 or later.
- Xcode with Swift 6.2 or later.
- Optionally, an Apple Development signing identity, so the Accessibility grant survives rebuilds.

## Build and test

```sh
swift build
swift test
scripts/check-invariants.sh
scripts/bundle.sh debug      # or release
open build/EverythingShortcut.app
```

`swift test` covers the pure core and needs no permissions.
`scripts/check-invariants.sh` fails when a single-source-of-truth rule from the design doc breaks.
`scripts/bundle.sh` writes `build/EverythingShortcut.app` and signs it last.
Its icon comes from `es-dev icon`, which draws the app icon from the badge code on every build.

## Code signing and Accessibility

The app reads other apps' interfaces and posts clicks, so it needs Accessibility.
macOS ties that grant to the bundle id and the signing identity.

`scripts/bundle.sh` signs with `ES_SIGNING_IDENTITY` when it is set, else with the first Apple Development identity in your keychain.
Either keeps the grant across rebuilds.
With neither, it signs ad hoc and warns, and macOS asks for Accessibility again after every build.

## Check it end to end

```sh
scripts/e2e.sh
```

The script bundles the DEBUG app, starts it with `--automation`, and runs `es-dev e2e` against two fixture windows, then against the app's own window.
It prints `VERIFIED` or `NOT VERIFIED` for each check and saves a screenshot of the badges under `build/e2e/`.
The first run needs Accessibility granted to `build/EverythingShortcut.app` in System Settings.
Run it unlocked, on a desktop Space, because a full-screen Space hides the fixture windows, and es-dev stops early with exit 2 when it sees either.
It types real keystrokes, so leave the keyboard and mouse alone while it runs.
The automation hook exists only in DEBUG builds.

## Release

```sh
scripts/release.sh
```

The script builds a universal (Apple silicon and Intel) release bundle with `scripts/bundle.sh dist`, signs it with a Developer ID Application identity and the hardened runtime, notarizes it, staples the ticket, and writes `build/release/EverythingShortcut-<version>.zip`.
It takes the version from `CFBundleShortVersionString` in `Support/Info.plist`, so bump that and `CFBundleVersion` first.
`ES_DIST_IDENTITY` picks another signing identity.

Notarization needs a notarytool keychain profile, stored once per machine:

```sh
xcrun notarytool store-credentials everything-shortcut --team-id <your team id>
```

`ES_NOTARY_PROFILE` names another profile.

The zip is published only on [everythingshortcut.com](https://everythingshortcut.com), not on GitHub Releases.
