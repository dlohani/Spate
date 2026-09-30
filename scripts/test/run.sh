#!/usr/bin/env bash
# Runs every scripts/test/*.test.sh in its own shell; exit 1 if any fails.
#   scripts/test/run.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0
for t in "$ROOT"/scripts/test/*.test.sh; do
  name="$(basename "$t" .test.sh)"
  if bash "$t"; then
    echo "ok   $name"
  else
    echo "FAIL $name"
    fail=1
  fi
done
exit $fail
