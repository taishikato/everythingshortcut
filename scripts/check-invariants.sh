#!/bin/bash
# Fails when a single-source-of-truth rule from docs/design.md is broken.
# usage: scripts/check-invariants.sh    exit 0 when every rule holds
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0
check() {
  if [ -n "$2" ]; then
    echo "FAIL: $1"
    echo "$2" | sed 's/^/  /'
    fail=1
  else
    echo "ok: $1"
  fi
}

# Hits from grep -rn, minus lines that are only a comment and minus the one file allowed to match.
code_hits() {
  local pattern="$1" allowed="$2"
  grep -rnE "$pattern" Sources --include='*.swift' \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' \
    | { if [ -n "$allowed" ]; then grep -v "^$allowed:"; else cat; fi; } \
    || true
}

check "no @unchecked anywhere" \
  "$(grep -rn '@unchecked' Sources Tests --include='*.swift' || true)"

check "HintCore imports nothing" \
  "$(grep -rnE '^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]' Sources/HintCore || true)"

roles_file=Sources/HintCore/RoleTable.swift
roles=$(grep -oE '^[[:space:]]+"AX[A-Za-z]+": \.' "$roles_file" | grep -oE 'AX[A-Za-z]+' | sort -u | paste -sd '|' -)
if [ -z "$roles" ]; then
  check "role table parses" "no role keys found in $roles_file"
else
  check "AX role strings appear only in RoleTable.swift" "$(code_hits "\"($roles)\"" "$roles_file")"
fi
check "no kAX role constants, roles come from the table" "$(code_hits 'kAX[A-Za-z]+Role\b' "")"

check "the AppKit flip appears only in Geometry.swift" \
  "$(code_hits '[A-Za-z_.]+[[:space:]]*-[[:space:]]*\([^()]*\+[^()]*[hH]eight[[:space:]]*\)' Sources/HintCore/Geometry.swift)"

check "AX IPC calls appear only in Scan.swift" \
  "$(code_hits 'AXUIElement(Copy[A-Za-z]*|PerformAction|Set[A-Za-z]*)[[:space:]]*\(' Sources/EverythingShortcut/Scan.swift)"

exit $fail
