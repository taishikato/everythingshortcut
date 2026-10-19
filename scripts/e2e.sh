#!/bin/bash
# End-to-end run from any shell, including one without Accessibility.
# Needs, once per machine: Accessibility granted to build/EverythingShortcut.app in
# System Settings > Privacy & Security > Accessibility. es-dev exits 2 with that instruction otherwise.
#
# usage: scripts/e2e.sh    exit 0 when every check prints VERIFIED
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/e2e"

APP="$("$ROOT/scripts/bundle.sh" debug | tail -n 1)"
swift build --package-path "$ROOT" --product es-dev >&2
ES_DEV="$(swift build --package-path "$ROOT" --show-bin-path)/es-dev"
mkdir -p "$OUT"

# A running copy would hold the trigger chord, and the new one could not register it.
pkill -x EverythingShortcut || true
for _ in $(seq 50); do pgrep -x EverythingShortcut >/dev/null || break; sleep 0.1; done

# `open` makes the app its own TCC-responsible process, so its grant applies and not this shell's.
open -n "$APP" --args --automation
trap 'pkill -x EverythingShortcut || true' EXIT

"$ES_DEV" windows > "$OUT/windows.txt"
"$ES_DEV" e2e --out "$OUT"
