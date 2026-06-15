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
#   6. harness/run-command.js  — the __fabric_command imperative-op seam + async round-trip
#   7. harness/run-reload.js   — the DEV-3 runtime state seam: _Platform_live{getModel,setModel,
#                                managers} + _Platform_shutdown are opt-in-only (inert without
#                                globalThis._Platform_devSeam), round-trip a model, and shutdown
#                                clears the handle so a reload does not double-subscribe.
#   8. harness/bench.js        — the median-frame-cost regression guard (RND-3 timings) + the AND-8
#                                scalar fast-path guard: the dominant per-frame mutations (text/value/
#                                opacity) must take __fabric_updatePropScalar (no JSON marshalling),
#                                and each scenario's p50 must not regress past the baseline tolerance.
#                                NOTE: the absolute ns are x86_64/CI numbers; the real arm64 per-frame-ms
#                                ledger (AND-8 Phase A) is a device task — see plans/independent/AND-8.md.
#   9. check-rn-coupling.sh    — the RN coupling guard (jsi/Hermes/Yoga frozen to an allowlist;
#                                no RCTBridge/TurboModule/fbjni/MountingManager) — see docs/rn-coupling.md
#  10. check-release-bundle-security.sh — RB-3 device-free release-load safety guard: the
#                                /data/local/tmp dev override is DEBUG-gated and the integrity
#                                check is fail-closed (throws) only in release.
#
# Usage:  ./scripts/ci-test.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

echo "==> [1/10] canopy test tests/"
( cd "$ROOT/package" && canopy test tests/ ) || fail=1

echo
echo "==> [2/10] harness/run.js (targeted updates)"
node "$ROOT/harness/run.js" || fail=1

echo
echo "==> [3/10] harness/run-keyed.js (LIS reconciler)"
node "$ROOT/harness/run-keyed.js" || fail=1

echo
echo "==> [4/10] harness/run-lazy.js (lazy memoization)"
node "$ROOT/harness/run-lazy.js" || fail=1

echo
echo "==> [5/10] harness/run-echo.js (native-module ABI)"
node "$ROOT/harness/run-echo.js" || fail=1

echo
echo "==> [6/10] harness/run-command.js (imperative-command seam)"
node "$ROOT/harness/run-command.js" || fail=1

echo
echo "==> [7/10] harness/run-reload.js (DEV-3 state seam: _Platform_live / _Platform_shutdown)"
node "$ROOT/harness/run-reload.js" || fail=1

echo
echo "==> [8/10] harness/bench.js (median-frame-cost + AND-8 scalar fast-path guard)"
# The AND-8 scalar fast-path guard + the lazy short-circuit guard are TIMING-INDEPENDENT (they
# exit 1 on a logic failure regardless of CPU speed). The median-frame-cost p50 gate, however, is
# run here back-to-back AFTER the six suites above, so this process tree is under sustained load —
# the bench's own header warns that ns figures are machine/load-dependent. We therefore run the CI
# perf gate at a WIDE 100% tolerance: it still catches the regressions the gate exists for (an
# algorithmic O(n)->O(n^2) reconciler blowup is 5-50x at N=200), without flaking on the 1.5-2x CPU
# jitter a loaded shared runner shows. For a true perf signal, run `node harness/bench.js --baseline
# harness/bench-baseline.json` standalone on a quiet box (default 25% tolerance). The real arm64
# per-frame-ms ledger (AND-8 Phase A) is a device task — see plans/independent/AND-8.md.
node "$ROOT/harness/bench.js" --baseline "$ROOT/harness/bench-baseline.json" --tolerance 1.0 || fail=1

echo
echo "==> [9/10] check-rn-coupling.sh (RN coupling guard)"
bash "$ROOT/scripts/check-rn-coupling.sh" || fail=1

echo
echo "==> [10/10] check-release-bundle-security.sh (RB-3 release-load safety guard)"
bash "$ROOT/scripts/check-release-bundle-security.sh" || fail=1

echo
if [ "$fail" -eq 0 ]; then
  echo "ALL GREEN — canopy/native regression gate passed."
else
  echo "REGRESSION — one or more suites failed." >&2
fi
exit "$fail"
