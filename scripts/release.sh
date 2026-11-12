#!/bin/bash
# Builds the download: the universal Developer ID build from `scripts/bundle.sh dist`, notarized by
# Apple, with the ticket stapled so Gatekeeper accepts it offline, zipped as
# build/release/EverythingShortcut-<CFBundleShortVersionString>.zip.
# It refuses to start with uncommitted changes or when the tag v<version> exists, runs
# scripts/check.sh first, writes the dSYM as EverythingShortcut-<version>.dSYM.zip beside the zip,
# and tags the commit v<version> at the end. The tag is local until you push it.
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
DSYM_ZIP="$ROOT/build/release/EverythingShortcut-$VERSION.dSYM.zip"
TAG="v$VERSION"

# A release is exactly one commit. Uncommitted or untracked changes would ship with no record of them.
if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
  echo "error: the working tree has uncommitted changes; commit or stash them before a release" >&2
  git -C "$ROOT" status --short >&2
  exit 1
fi
# The tag is made at the end of a successful release, so an existing one means this version is out.
if git -C "$ROOT" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "error: the tag $TAG already exists; bump CFBundleShortVersionString in Support/Info.plist first" >&2
  exit 1
fi

# A missing profile fails here, before the build.
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null; then
  echo "error: notarytool cannot use the keychain profile '$PROFILE'; store it with" >&2
  echo "  xcrun notarytool store-credentials $PROFILE --team-id <your team id>" >&2
  exit 1
fi

# The same gates CI runs, before anything is signed.
"$ROOT/scripts/check.sh" >&2

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

# Kept beside the zip and never published: it symbolicates crash reports from this exact build.
rm -f "$DSYM_ZIP"
ditto -c -k --keepParent "$(dirname "$APP")/EverythingShortcut.app.dSYM" "$DSYM_ZIP"

git -C "$ROOT" tag -a "$TAG" -m "Release $VERSION"
echo "tagged $TAG; publish it with: git push origin $TAG" >&2
echo "$ZIP"
