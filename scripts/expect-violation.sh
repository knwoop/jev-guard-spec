#!/usr/bin/env bash
# Runs `quint run` with the given arguments and exits 0 only if a violation
# was found. Used where a violation is the expected result: the vulnerable
# guard, and the over-blocking check on the fixed guard.
set -uo pipefail
out="$(quint run "$@" 2>&1)"
status=$?
if printf '%s\n' "$out" | grep -q '^\[violation\]'; then
  printf '%s\n' "$out" | grep -E '^\[violation\]'
  exit 0
fi
printf '%s\n' "$out" | tail -5
echo "expected a violation but none was found (quint exit $status)" >&2
exit 1
