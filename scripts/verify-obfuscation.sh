#!/usr/bin/env bash
# Verify that built Go artifacts are obfuscated: no cascade package paths in
# the symbol table or in the string table, and for a shared library exactly
# the C symbols listed in export/cshared/symbols. A release that failed to
# obfuscate must stop here, never ship plain.
#
#   scripts/verify-obfuscation.sh FILE...
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/go/bin:$HOME/go/bin:$PATH"
rc=0
want_exports="$(grep -cv '^[[:space:]]*\(#\|$\)' "$ROOT/export/cshared/symbols")"
for f in "$@"; do
  [ -f "$f" ] || { echo "verify-obfuscation: missing $f" >&2; rc=1; continue; }
  syms="$(go tool nm "$f" 2>/dev/null | grep -c 'cascade/internal\|cascade/cmd\|cascade/export' || true)"
  strs="$(strings "$f" | grep -c 'cascade/internal\|cascade/cmd\|cascade/export' || true)"
  if [ "$syms" != 0 ] || [ "$strs" != 0 ]; then
    echo "verify-obfuscation: $f is NOT obfuscated ($syms symbols, $strs strings name cascade packages)" >&2; rc=1
  fi
  case "$f" in
    *.dylib|*.so|*.dll)
      if command -v nm >/dev/null; then
        got="$(nm -gU "$f" 2>/dev/null | grep -c ' _\{0,1\}Cascade' || true)"
        [ "$got" = "$want_exports" ] || { echo "verify-obfuscation: $f exports $got Cascade* symbols, want $want_exports" >&2; rc=1; }
      fi ;;
  esac
  [ $rc = 0 ] && echo "verify-obfuscation: ok $f"
done
exit $rc
