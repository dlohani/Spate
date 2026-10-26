# Shared by the Makefile lib/cli targets: is release obfuscation on, is
# garble available, and what build command to run. Off by default; every
# build behaves exactly as today unless SPATE_OBFUSCATE=1 is set. Source
# it; POSIX sh (dash, bash 3.2, etc.) compatible -- no bash-only arrays,
# ${var:offset:len} or C-style for loops, so make's default /bin/sh runs it
# on every platform without a SHELL override.
#
# obf_seed needs the repo root to find VERSION and .git; callers set
# OBF_ROOT before sourcing (the Makefile passes $(CURDIR)). It defaults to
# the current directory, which is right when a script sources this from the
# repo root itself.

# obf_on: 0 only when SPATE_OBFUSCATE is exactly "1".
obf_on() {
  [ "${SPATE_OBFUSCATE:-}" = "1" ]
}

# obf_require_garble: a no-op when obfuscation is off. When it is on and
# garble is not on PATH, prints an install hint and exits 2 (a release build
# must fail loudly, never fall back to a plain, unobfuscated build).
obf_require_garble() {
  obf_on || return 0
  command -v garble >/dev/null 2>&1 && return 0
  echo "error: SPATE_OBFUSCATE=1 but garble is not on PATH." >&2
  echo "       Install it:  go install mvdan.cc/garble@latest" >&2
  echo "       Then ensure \$(go env GOPATH)/bin (usually \$HOME/go/bin) is on PATH." >&2
  exit 2
}

# obf_seed: the per-build garble seed (a base64 string, as garble -seed
# requires; only its first 8 bytes are used). SPATE_OBF_SEED overrides it
# verbatim; otherwise it is derived by hashing VERSION plus the git short
# SHA, so a release can be rebuilt identically but names differ across
# releases. Never a hardcoded literal seed in the repo.
obf_seed() {
  if [ -n "${SPATE_OBF_SEED:-}" ]; then
    printf '%s' "$SPATE_OBF_SEED"
    return 0
  fi
  local root version sha hex fmt i pair
  root="${OBF_ROOT:-.}"
  . "$root/scripts/lib/sha256.sh"
  version="$(tr -d '[:space:]' < "$root/VERSION" 2>/dev/null || true)"
  sha="$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo nogit)"
  hex="$(printf '%s-%s' "$version" "$sha" | sha256_file | awk '{print $1}' | cut -c1-16)"
  # 8 bytes: all garble -seed uses anyway. Build an octal-escaped byte
  # string (POSIX printf has \NNN, not the GNU-only \xHH) and base64 it.
  fmt=""
  i=1
  while [ "$i" -le 15 ]; do
    pair="$(printf '%s' "$hex" | cut -c"$i-$((i + 1))")"
    fmt="$fmt$(printf '\\%03o' "$((0x$pair))")"
    i=$((i + 2))
  done
  printf "$fmt" | base64
}

# go_build_cmd PROFILE [GOBIN]: the build command to run, printed to stdout.
# Off: "GOBIN build" -- GOBIN defaults to "go" but callers pass the
# Makefile's $(GO) so an override (e.g. `make GO=/path/to/go lib`) still
# takes effect, exactly like the plain build. On: garble; PROFILE "lib"
# adds -literals, anything else (e.g. "cli") gets only -tiny, to keep the
# CLI small. Callers append the same -ldflags/-buildmode/output/package
# args either way, and still honour CGO_ENABLED and CC.
go_build_cmd() {
  local profile="$1" gobin="${2:-go}"
  if ! obf_on; then
    printf '%s build' "$gobin"
    return 0
  fi
  if [ "$profile" = "lib" ]; then
    printf 'garble -literals -tiny -seed=%s build' "$(obf_seed)"
  else
    printf 'garble -tiny -seed=%s build' "$(obf_seed)"
  fi
}
