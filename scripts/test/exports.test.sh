#!/usr/bin/env bash
# Tests for scripts/export-symbols.sh and export/cshared/symbols.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GEN="$ROOT/scripts/export-symbols.sh"
rc=0
bad() { echo "  not ok: $1"; rc=1; }

want="$(grep -h '^//export ' "$ROOT"/export/cshared/*.go | awk '{print $2}' | sort)"
wantn="$(printf '%s\n' "$want" | wc -l | tr -d ' ')"
[ "$wantn" = "28" ] || bad "expected 28 //export directives, found $wantn"

mac="$("$GEN" macos 2>&1)" || bad "generator macos failed: $mac"
gotn="$(printf '%s\n' "$mac" | grep -c '^_Spate')"
[ "$gotn" = "$wantn" ] || bad "macos list has $gotn entries, //export count is $wantn"
[ "$(printf '%s\n' "$mac" | wc -l | tr -d ' ')" = "$wantn" ] || bad "macos list has non-symbol lines"
got="$(printf '%s\n' "$mac" | sed 's/^_//' | sort)"
[ "$got" = "$want" ] || bad "macos list names differ from //export names"

gnu="$("$GEN" gnu 2>&1)" || bad "generator gnu failed"
for n in $want; do
  printf '%s\n' "$gnu" | grep -q "^  $n;\$" || bad "gnu script missing $n"
done
printf '%s\n' "$gnu" | grep -q '^  \*;$' || bad "gnu script lacks local: *"

def="$("$GEN" def 2>&1)" || bad "generator def failed"
[ "$(printf '%s\n' "$def" | head -1)" = "EXPORTS" ] || bad "def must start with EXPORTS"
[ "$(printf '%s\n' "$def" | grep -c '^  Spate')" = "$wantn" ] || bad "def count mismatch"
exit $rc
