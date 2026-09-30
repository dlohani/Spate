#!/usr/bin/env bash
# Tests for the release gate in ./build (require_release): a release needs a
# clean tree, HEAD on tag v$VERSION and no CASCADE_ALLOW_NO_UI. Runs ./build in
# a throwaway repo holding only what the version target needs. Each check
# prints "  not ok: <what>" on failure.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
rc=0
check() { # DESCRIPTION EXPECTED_STATUS ACTUAL_STATUS
  if [ "$2" != "$3" ]; then echo "  not ok: $1 (want $2, got $3)"; rc=1; fi
}
unset CASCADE_ALLOW_NO_UI

mkdir -p "$TMP/scripts/lib"
cp "$ROOT/build" "$ROOT/VERSION" "$TMP/"
cp "$ROOT"/scripts/lib/*.sh "$TMP/scripts/lib/"   # every library build sources
cd "$TMP"
git init -q
git config user.email t@t
git config user.name t
git config commit.gpgsign false
git config tag.gpgsign false
git add -A && git commit -qm init
VERSION="$(tr -d '[:space:]' < VERSION)"
gate() { ./build release version >/dev/null 2>&1; }

gate; check "untagged HEAD is refused" 2 $?
git tag v0.3.9
gate; check "HEAD on the wrong tag is refused" 2 $?
git tag -d v0.3.9 >/dev/null
git tag "v$VERSION"
gate; check "clean HEAD on tag v$VERSION is allowed" 0 $?
( export CASCADE_ALLOW_NO_UI=1; gate ); check "CASCADE_ALLOW_NO_UI=1 is refused even when tagged" 2 $?
: > untracked.txt
gate; check "an untracked file is refused" 2 $?
exit $rc
