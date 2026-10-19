#!/bin/bash
# Builds build/EverythingShortcut.app and signs it with the stable development identity.
# The same CFBundleIdentifier and signing identity on every build keep the TCC Accessibility
# grant across rebuilds. Ad hoc signing would reset it each time.
#
# usage: scripts/bundle.sh [debug|release]    prints the bundle path on success
set -euo pipefail

CONFIG="${1:-debug}"
IDENTITY="${ES_SIGNING_IDENTITY:-Apple Development: Taishi Kato (3J26NQ6DYQ)}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/EverythingShortcut.app"

swift build --package-path "$ROOT" -c "$CONFIG" --product EverythingShortcut >&2
BIN="$(swift build --package-path "$ROOT" -c "$CONFIG" --show-bin-path)/EverythingShortcut"

mkdir -p "$ROOT/build"
STAGE="$(mktemp -d "$ROOT/build/.stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/EverythingShortcut.app/Contents/MacOS"
cp "$BIN" "$STAGE/EverythingShortcut.app/Contents/MacOS/EverythingShortcut"
cp "$ROOT/Support/Info.plist" "$STAGE/EverythingShortcut.app/Contents/Info.plist"
plutil -lint "$STAGE/EverythingShortcut.app/Contents/Info.plist" >&2

# Signing comes last, because any change to the bundle after it breaks the seal.
codesign --force --timestamp=none --sign "$IDENTITY" "$STAGE/EverythingShortcut.app" >&2
codesign --verify --strict "$STAGE/EverythingShortcut.app" >&2

# Swap in the finished bundle in one rename, so a failed build never leaves a half-written app.
rm -rf "$APP"
mv "$STAGE/EverythingShortcut.app" "$APP"
echo "$APP"
