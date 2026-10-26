#!/usr/bin/env bash
# scripts/verify-obfuscation.sh must reject a plain build of the core and
# accept a binary that carries no spate package paths (hermetic: no garble).
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/go/bin:$HOME/go/bin:$PATH"
rc=0; bad() { echo "  not ok: $1"; rc=1; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
(cd "$ROOT" && go build -o "$T/plain" ./cmd/spate) || bad "build plain cli"
"$ROOT/scripts/verify-obfuscation.sh" "$T/plain" >/dev/null 2>&1 && bad "plain build accepted as obfuscated"
mkdir -p "$T/clean" && printf 'package main\nfunc main() {}\n' > "$T/clean/main.go" && printf 'module clean\n\ngo 1.22\n' > "$T/clean/go.mod"
(cd "$T/clean" && go build -o "$T/cleanbin" .) || bad "build clean binary"
"$ROOT/scripts/verify-obfuscation.sh" "$T/cleanbin" >/dev/null 2>&1 || bad "binary without spate paths rejected"
"$ROOT/scripts/verify-obfuscation.sh" "$T/does-not-exist" >/dev/null 2>&1 && bad "missing file accepted"
exit $rc
