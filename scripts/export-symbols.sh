#!/bin/sh
# Turns export/cshared/symbols (one C symbol name per line, the single source
# of truth; must match the //export directives in export/cshared/*.go) into a
# linker export list on stdout.
#
#   scripts/export-symbols.sh macos   ld64 -exported_symbols_list (leading _)
#   scripts/export-symbols.sh gnu     GNU ld version script (Linux)
#   scripts/export-symbols.sh def     module-definition file (Windows/mingw)
#
# POSIX sh; no bashisms.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SYMS="$ROOT/export/cshared/symbols"
[ -r "$SYMS" ] || { echo "export-symbols: cannot read $SYMS" >&2; exit 1; }
names() { grep -v '^[[:space:]]*\(#\|$\)' "$SYMS"; }
case "${1:-}" in
  macos) names | sed 's/^/_/' ;;
  gnu)
    echo '{'
    echo ' global:'
    names | sed 's/^\(.*\)$/  \1;/'
    echo ' local:'
    echo '  *;'
    echo '};'
    ;;
  def)
    echo 'EXPORTS'
    names | sed 's/^/  /'
    ;;
  *) echo "usage: export-symbols.sh macos|gnu|def" >&2; exit 2 ;;
esac
