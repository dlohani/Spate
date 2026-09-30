# Shared by the Makefile lib/cli targets: is release obfuscation on, is
# garble available, and what build command to run. Off by default; every
# build behaves exactly as today unless CASCADE_OBFUSCATE=1 is set. Source it;
# bash 3.2 compatible.

# obf_on: 0 only when CASCADE_OBFUSCATE is exactly "1".
obf_on() {
  [ "${CASCADE_OBFUSCATE:-}" = "1" ]
}

# obf_require_garble: a no-op when obfuscation is off. When it is on and
# garble is not on PATH, prints an install hint and exits 2 (a release build
# must fail loudly, never fall back to a plain, unobfuscated build).
obf_require_garble() {
  obf_on || return 0
  command -v garble >/dev/null 2>&1 && return 0
  echo "error: CASCADE_OBFUSCATE=1 but garble is not on PATH." >&2
  echo "       Install it:  go install mvdan.cc/garble@latest" >&2
  echo "       Then ensure \$(go env GOPATH)/bin (usually \$HOME/go/bin) is on PATH." >&2
  exit 2
}

# obf_seed: the per-build garble seed (a base64 string, as garble -seed
# requires; only its first 8 bytes are used). CASCADE_OBF_SEED overrides it
# verbatim; otherwise it is derived by hashing VERSION plus the git short
# SHA, so a release can be rebuilt identically but names differ across
# releases. Never a hardcoded literal seed in the repo.
obf_seed() {
  if [ -n "${CASCADE_OBF_SEED:-}" ]; then
    printf '%s' "$CASCADE_OBF_SEED"
    return 0
  fi
  local root version sha hex fmt i
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  . "$root/scripts/lib/sha256.sh"
  version="$(tr -d '[:space:]' < "$root/VERSION" 2>/dev/null || true)"
  sha="$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo nogit)"
  hex="$(printf '%s-%s' "$version" "$sha" | sha256_file | awk '{print $1}')"
  hex="${hex:0:16}"   # 8 bytes: all garble -seed uses anyway
  fmt=""
  for ((i = 0; i < ${#hex}; i += 2)); do
    fmt="$fmt\\x${hex:i:2}"
  done
  printf "$fmt" | base64
}

# go_build_cmd PROFILE: the build command to run, printed to stdout. PROFILE
# is "lib" (garble -literals -tiny) or anything else, e.g. "cli" (garble
# -tiny, no -literals, to keep the CLI small). Plain "go build" when
# obfuscation is off. Callers append the same -ldflags/-buildmode/output/
# package args either way, and still honour CGO_ENABLED and CC.
go_build_cmd() {
  local profile="$1"
  if ! obf_on; then
    printf 'go build'
    return 0
  fi
  if [ "$profile" = "lib" ]; then
    printf 'garble -literals -tiny -seed=%s build' "$(obf_seed)"
  else
    printf 'garble -tiny -seed=%s build' "$(obf_seed)"
  fi
}
