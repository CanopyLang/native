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
#  11. harness/run-coalesce.js  — the AND-9 Cmd/Sub completion coalescing + latest-wins backpressure
#                                policy (executable spec of CanopyCompletionScheduler): a 1000-event
#                                burst within one frame batches into ONE main-Looper post (bounded
#                                backlog), no FINAL value is dropped, and an opt-in stream collapses
#                                to its newest frame. The Java class is unit-tested on the JVM
#                                (:app:testDebugUnitTest CanopyCompletionSchedulerTest); this is the
#                                device-free CI gate that the policy did not drift.
#  12. harness/run-list-perf.js — the RND-6 windowing proof: Native.List wraps each windowed row's
#                                renderItem in VirtualDom.lazy, so a scroll that does not cross a row
#                                boundary diffs to ZERO Fabric ops and off-window rows are never
#                                mounted. Drives the REAL compiled examples/listtest bundle (1000
#                                rows) end-to-end against the mock Fabric, AND instruments the walker
#                                directly to prove the lazy wrap stops per-row renderItem re-invocation
#                                (the discriminator). Builds the listtest bundle first if absent.
#  13. check-vendor-pins.sh     — RNV-8 cross-platform RN-version grep-guard: the one react-native
#                                release must be pinned identically across the iOS Podfile, the baked
#                                C++ ABI pin, vendor.lock.json, and the Android CMakeLists. A one-sided
#                                bump (e.g. Podfile only) goes red. Pure grep + jq, no device.
#  14. check-abi.sh             — RNV-2/RNV-8 headless Hermes/JSI ABI gate: re-extracts the pinned
#                                libhermes' bytecode version and proves it equals the baked C++ pin +
#                                vendor.lock.json + the boot path. Needs the vendored libhermes.so on
#                                disk (a fresh clone restores it via scripts/fetch-vendor.sh); SKIPPED
#                                with a notice if it is absent so the gate stays offline-runnable.
#
# Usage:  ./scripts/ci-test.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

echo "==> [1/14] canopy test tests/"
( cd "$ROOT/package" && canopy test tests/ ) || fail=1

echo
echo "==> [2/14] harness/run.js (targeted updates)"
node "$ROOT/harness/run.js" || fail=1

echo
echo "==> [3/14] harness/run-keyed.js (LIS reconciler)"
node "$ROOT/harness/run-keyed.js" || fail=1

echo
echo "==> [4/14] harness/run-lazy.js (lazy memoization)"
node "$ROOT/harness/run-lazy.js" || fail=1

echo
echo "==> [5/14] harness/run-echo.js (native-module ABI)"
node "$ROOT/harness/run-echo.js" || fail=1

echo
echo "==> [6/14] harness/run-command.js (imperative-command seam)"
node "$ROOT/harness/run-command.js" || fail=1

echo
echo "==> [7/14] harness/run-reload.js (DEV-3 state seam: _Platform_live / _Platform_shutdown)"
node "$ROOT/harness/run-reload.js" || fail=1

echo
echo "==> [8/14] harness/bench.js (median-frame-cost + AND-8 scalar fast-path guard)"
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
echo "==> [9/14] check-rn-coupling.sh (RN coupling guard)"
bash "$ROOT/scripts/check-rn-coupling.sh" || fail=1

echo
echo "==> [10/14] check-release-bundle-security.sh (RB-3 release-load safety guard)"
bash "$ROOT/scripts/check-release-bundle-security.sh" || fail=1

echo
echo "==> [11/14] harness/run-coalesce.js (AND-9 completion coalescing + backpressure)"
node "$ROOT/harness/run-coalesce.js" || fail=1

echo
echo "==> [12/14] harness/run-list-perf.js (RND-6 Native.List windowing: lazy rows → zero off-window work)"
# Part 1 drives the REAL compiled examples/listtest bundle; build it if the artifact is absent so
# CI is self-contained (mirrors run-compiled.js's counter-bundle prereq). canopy-native is on PATH.
if [ ! -f "$ROOT/examples/listtest/build/canopy.bundle.js" ]; then
  echo "    (building examples/listtest bundle — not present)"
  canopy-native build "$ROOT/examples/listtest" || fail=1
fi
node "$ROOT/harness/run-list-perf.js" || fail=1

echo
echo "==> [13/14] check-vendor-pins.sh (RNV-8 cross-platform RN-version pin guard)"
bash "$ROOT/scripts/check-vendor-pins.sh" || fail=1

echo
echo "==> [14/14] check-abi.sh (RNV-2/RNV-8 Hermes/JSI ABI gate)"
# Needs the vendored libhermes.so on disk. A fresh clone restores it via scripts/fetch-vendor.sh;
# keep the regression gate offline-runnable by SKIPPING (not failing) when the .so is absent.
if [ -f "$ROOT/host/android/vendor/lib/arm64-v8a/libhermes.so" ]; then
  bash "$ROOT/scripts/check-abi.sh" || fail=1
else
  echo "    SKIP — vendored libhermes.so absent (run scripts/fetch-vendor.sh to enable this gate)."
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "ALL GREEN — canopy/native regression gate passed."
else
  echo "REGRESSION — one or more suites failed." >&2
fi
exit "$fail"
