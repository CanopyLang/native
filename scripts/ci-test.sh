#!/usr/bin/env bash
# ci-test.sh — the device-free regression gate for canopy/native. Runs the three layers of
# the mock-fabric test stack and fails the build if any does. This is what CI runs per commit
# (no emulator needed — the mock Fabric is byte-identical to the real host's mount surface).
#
#   1. canopy test tests/      — the Canopy-written component/css suite (via Native.Testing)
#   2. harness/run.js          — the §8 targeted-update guarantees on the counter app
#   3. harness/run-keyed.js    — the LIS keyed-reconciler correctness + move-minimality
#   4. harness/run-lazy.js     — `lazy`/thunk memoization actually short-circuits (regression)
#   5. harness/run-echo.js     — the native-module ABI round-trip
#
# Usage:  ./scripts/ci-test.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

echo "==> [1/5] canopy test tests/"
( cd "$ROOT/package" && canopy test tests/ ) || fail=1

echo
echo "==> [2/5] harness/run.js (targeted updates)"
node "$ROOT/harness/run.js" || fail=1

echo
echo "==> [3/5] harness/run-keyed.js (LIS reconciler)"
node "$ROOT/harness/run-keyed.js" || fail=1

echo
echo "==> [4/5] harness/run-lazy.js (lazy memoization)"
node "$ROOT/harness/run-lazy.js" || fail=1

echo
echo "==> [5/5] harness/run-echo.js (native-module ABI)"
node "$ROOT/harness/run-echo.js" || fail=1

echo
if [ "$fail" -eq 0 ]; then
  echo "ALL GREEN — canopy/native regression gate passed."
else
  echo "REGRESSION — one or more suites failed." >&2
fi
exit "$fail"
