#!/bin/bash
# Builds the app bundle and signs it.
#
# debug and release write build/EverythingShortcut.app for this Mac's architecture, signed with
# ES_SIGNING_IDENTITY, else the first Apple Development identity in the keychain, else ad hoc.
# The same CFBundleIdentifier and a stable identity on every build keep the TCC Accessibility
# grant across rebuilds. Ad hoc signing resets it each time.
#
# dist writes build/dist/EverythingShortcut.app, a universal release build signed with
# ES_DIST_IDENTITY, else the first Developer ID Application identity, with the hardened runtime
# and secure timestamp that notarization needs. scripts/release.sh notarizes it.
#
# usage: scripts/bundle.sh [debug|release|dist]    prints the bundle path on success
set -euo pipefail

MODE="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# The SHA-1 of the first valid code signing identity whose name starts with $1, or nothing.
# A hash, unlike a name, stays unambiguous when a renewed certificate shares the old one's name.
first_identity() {
  security find-identity -v -p codesigning \
    | sed -nE "s/^ *[0-9]+\) ([0-9A-F]{40}) \"$1.*\"\$/\1/p" \
    | head -n 1
}

case "$MODE" in
  debug | release)
    CONFIG="$MODE"
    ARCHS=()
    OUT="$ROOT/build"
    IDENTITY="${ES_SIGNING_IDENTITY:-$(first_identity 'Apple Development: ')}"
    if [ -z "$IDENTITY" ]; then
      IDENTITY=-
      echo "warning: no Apple Development identity, signing ad hoc; macOS asks for Accessibility again after each build" >&2
    fi
    SIGN_FLAGS=(--timestamp=none)
    ;;
  dist)
    CONFIG=release
    ARCHS=(--arch arm64 --arch x86_64)
    OUT="$ROOT/build/dist"
    IDENTITY="${ES_DIST_IDENTITY:-$(first_identity 'Developer ID Application: ')}"
    if [ -z "$IDENTITY" ]; then
      echo "error: no Developer ID Application identity in the keychain; set ES_DIST_IDENTITY to one" >&2
      exit 1
    fi
    SIGN_FLAGS=(--options runtime --timestamp)
    ;;
  *)
    echo "usage: scripts/bundle.sh [debug|release|dist]" >&2
    exit 64
    ;;
esac

APP="$OUT/EverythingShortcut.app"

# The bash 3.2 that ships with macOS treats an empty array as unbound under set -u, hence the guard.
build() {
  swift build --package-path "$ROOT" -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} "$@"
}

build --product EverythingShortcut >&2
build --product es-dev >&2
BIN_DIR="$(build --show-bin-path)"

mkdir -p "$OUT"
STAGE="$(mktemp -d "$OUT/.stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/EverythingShortcut.app/Contents/MacOS" "$STAGE/EverythingShortcut.app/Contents/Resources"
cp "$BIN_DIR/EverythingShortcut" "$STAGE/EverythingShortcut.app/Contents/MacOS/EverythingShortcut"
cp "$ROOT/Support/Info.plist" "$STAGE/EverythingShortcut.app/Contents/Info.plist"
plutil -lint "$STAGE/EverythingShortcut.app/Contents/Info.plist" >&2

# es-dev draws the icon from the badge code on every build, so the bundle's icon cannot drift from the code.
"$BIN_DIR/es-dev" icon "$STAGE/AppIcon.iconset" >&2
iconutil -c icns "$STAGE/AppIcon.iconset" -o "$STAGE/EverythingShortcut.app/Contents/Resources/AppIcon.icns"

# Signing comes last, because any change to the bundle after it breaks the seal.
codesign --force "${SIGN_FLAGS[@]}" --sign "$IDENTITY" "$STAGE/EverythingShortcut.app" >&2
codesign --verify --strict "$STAGE/EverythingShortcut.app" >&2

# Swap in the finished bundle in one rename, so a failed build never leaves a half-written app.
rm -rf "$APP"
mv "$STAGE/EverythingShortcut.app" "$APP"
echo "$APP"
