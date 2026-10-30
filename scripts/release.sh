#!/bin/bash
# Builds the download: the universal Developer ID build from `scripts/bundle.sh dist`, notarized by
# Apple, with the ticket stapled so Gatekeeper accepts it offline, zipped as
# build/release/EverythingShortcut-<CFBundleShortVersionString>.zip.
# Needs, once per machine, a notarytool keychain profile, stored with
#   xcrun notarytool store-credentials everything-shortcut --team-id <your team id>
# ES_NOTARY_PROFILE names another profile.
#
# usage: scripts/release.sh    prints the zip path on success
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="${ES_NOTARY_PROFILE:-everything-shortcut}"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$ROOT/Support/Info.plist")"
ZIP="$ROOT/build/release/EverythingShortcut-$VERSION.zip"

# A missing profile fails here, before the build.
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null; then
  echo "error: notarytool cannot use the keychain profile '$PROFILE'; store it with" >&2
  echo "  xcrun notarytool store-credentials $PROFILE --team-id <your team id>" >&2
  exit 1
fi

APP="$("$ROOT/scripts/bundle.sh" dist | tail -n 1)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ditto keeps the bundle's signature intact, which plain zip does not promise.
ditto -c -k --keepParent "$APP" "$WORK/submit.zip"
xcrun notarytool submit "$WORK/submit.zip" --keychain-profile "$PROFILE" --wait \
  --output-format json > "$WORK/result.json" || true
STATUS="$(plutil -extract status raw "$WORK/result.json" 2>/dev/null || echo unknown)"
if [ "$STATUS" != Accepted ]; then
  cat "$WORK/result.json" >&2
  if ID="$(plutil -extract id raw "$WORK/result.json" 2>/dev/null)"; then
    xcrun notarytool log "$ID" --keychain-profile "$PROFILE" >&2 || true
  fi
  echo "error: notarization ended with status $STATUS" >&2
  exit 1
fi

xcrun stapler staple "$APP" >&2
xcrun stapler validate "$APP" >&2

mkdir -p "$(dirname "$ZIP")"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# Check what a user gets: the app unpacked from the zip passes Gatekeeper as notarized.
ditto -x -k "$ZIP" "$WORK/unpacked"
codesign --verify --deep --strict "$WORK/unpacked/EverythingShortcut.app" >&2
spctl --assess --type execute --verbose=2 "$WORK/unpacked/EverythingShortcut.app" >&2

shasum -a 256 "$ZIP" >&2
echo "$ZIP"
