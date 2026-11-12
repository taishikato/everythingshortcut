#!/bin/bash
# Every gate that needs no permission and no signing identity, in one command.
# CI runs it on every push and pull request, and scripts/release.sh runs it before it builds the download.
#
# usage: scripts/check.sh    exit 0 when every gate passes
set -euo pipefail
cd "$(dirname "$0")/.."

swift build
swift test
scripts/check-invariants.sh

# The DEBUG automation hook is compiled out of release builds. Prove it on a release binary.
# The symbols go through a variable, because `nm | grep -q` under pipefail can hide a match behind SIGPIPE.
swift build -c release --product EverythingShortcut
BIN="$(swift build -c release --show-bin-path)/EverythingShortcut"
SYMBOLS="$(nm -a "$BIN")"
if grep -q AutomationServer <<<"$SYMBOLS"; then
  echo "FAIL: the release binary contains the DEBUG automation hook (AutomationServer)"
  exit 1
fi
echo "ok: the release binary has no DEBUG automation hook"
