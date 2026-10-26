#!/usr/bin/env bash
# Tests for scripts/lib/obfuscate.sh. Each check prints "  not ok: <what>" on failure.
set -u
export PATH="/opt/homebrew/bin:/usr/local/go/bin:$HOME/go/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export OBF_ROOT="$ROOT"
. "$ROOT/scripts/lib/obfuscate.sh"
rc=0
check() { # DESCRIPTION EXPECTED_STATUS ACTUAL_STATUS
  if [ "$2" != "$3" ]; then echo "  not ok: $1 (want $2, got $3)"; rc=1; fi
}

# obf_on
( unset SPATE_OBFUSCATE; obf_on ); check "unset is off" 1 $?
( SPATE_OBFUSCATE=0 obf_on );      check "0 is off" 1 $?
( SPATE_OBFUSCATE=true obf_on );   check "true is off" 1 $?
( SPATE_OBFUSCATE=1 obf_on );      check "1 is on" 0 $?

# obf_require_garble: on and garble missing -> exit 2 with an install hint.
# Simulated with PATH cleared rather than by uninstalling garble.
out="$(SPATE_OBFUSCATE=1 PATH=/nonexistent obf_require_garble 2>&1)"; st=$?
check "require_garble exits 2 when on and garble is missing" 2 $st
case "$out" in *"go install mvdan.cc/garble"*) ;; *) echo "  not ok: install hint mentions go install mvdan.cc/garble"; rc=1 ;; esac

# Hermetic "present" case: a stub garble on a temp PATH, found via command -v
# exactly like the real one; never the machine's own garble.
FAKE="$(mktemp -d)"; trap 'rm -rf "$FAKE"' EXIT
printf '#!/bin/sh\nexit 0\n' > "$FAKE/garble"; chmod +x "$FAKE/garble"
( SPATE_OBFUSCATE=1 PATH="$FAKE:$PATH" obf_require_garble >/dev/null 2>&1 ); check "require_garble passes when on and garble is on PATH" 0 $?
( unset SPATE_OBFUSCATE; PATH=/nonexistent obf_require_garble >/dev/null 2>&1 ); check "require_garble is a no-op when off, even without garble" 0 $?

# go_build_cmd PROFILE [GOBIN]: prints the plain command when off, garble
# when on; -literals only for the lib profile; off honours a GOBIN argument
# (so `make GO=/path/to/go lib` still uses that go binary).
cmd="$(unset SPATE_OBFUSCATE; go_build_cmd lib)"
case "$cmd" in "go build") ;; *) echo "  not ok: off prints plain go build (lib) (got: $cmd)"; rc=1 ;; esac
cmd="$(unset SPATE_OBFUSCATE; go_build_cmd cli)"
case "$cmd" in "go build") ;; *) echo "  not ok: off prints plain go build (cli) (got: $cmd)"; rc=1 ;; esac
cmd="$(unset SPATE_OBFUSCATE; go_build_cmd lib /path/to/go)"
case "$cmd" in "/path/to/go build") ;; *) echo "  not ok: off honours the GOBIN argument (got: $cmd)"; rc=1 ;; esac

cmd="$(SPATE_OBFUSCATE=1 SPATE_OBF_SEED=deadbeef go_build_cmd lib)"
case "$cmd" in garble\ -literals\ -tiny\ -seed=deadbeef\ build) ;; *) echo "  not ok: on prints garble -literals -tiny (lib) (got: $cmd)"; rc=1 ;; esac
case "$cmd" in *-literals*) ;; *) echo "  not ok: lib profile carries -literals"; rc=1 ;; esac

cmd="$(SPATE_OBFUSCATE=1 SPATE_OBF_SEED=deadbeef go_build_cmd cli)"
case "$cmd" in garble\ -tiny\ -seed=deadbeef\ build) ;; *) echo "  not ok: on prints garble -tiny (cli) (got: $cmd)"; rc=1 ;; esac
case "$cmd" in *-literals*) echo "  not ok: cli profile must not carry -literals"; rc=1 ;; esac

# obf_seed: derived from VERSION + git short SHA when SPATE_OBF_SEED is unset,
# stable across calls, and overridable.
s1="$(unset SPATE_OBF_SEED; obf_seed)"
s2="$(unset SPATE_OBF_SEED; obf_seed)"
check "seed is stable across calls" "$s1" "$s2"
[ -n "$s1" ]; check "derived seed is non-empty" 0 $?
s3="$(SPATE_OBF_SEED=my-custom-seed obf_seed)"
check "SPATE_OBF_SEED overrides the derived seed" "my-custom-seed" "$s3"

exit $rc
