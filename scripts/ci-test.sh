#!/usr/bin/env bash
# ci-test.sh — the device-free regression gate for canopy/native. Runs the three layers of
# the mock-fabric test stack and fails the build if any does. This is what CI runs per commit
# (no emulator needed — the mock Fabric is byte-identical to the real host's mount surface).
#
#   1. canopy test tests/      — the Canopy-written component/css suite (via Native.Testing)
#   2. harness/run.js          — the §8 targeted-update guarantees on the counter app
#   3. harness/run-batch.js    — RND-7 batched binary marshalling: drives the REAL element+animator
#                                stack under all three seam modes (off / Stage-A JSON / Stage-B binary)
#                                and proves (a) the final view tree + per-op mutation log are
#                                byte-identical across modes through boot AND taps, (b) the collapse
#                                invariant — each frame's whole op stream arrives as exactly ONE
#                                __fabric_applyBatch (zero per-mutation host calls; a no-op frame = 0
#                                batches), and (c) the binary protocol round-trips multibyte UTF-8.
#   4. harness/run-keyed.js    — the LIS keyed-reconciler correctness + move-minimality
#   5. harness/run-lazy.js     — `lazy`/thunk memoization actually short-circuits (regression)
#   6. harness/run-echo.js     — the native-module ABI round-trip
#   7. harness/run-command.js  — the __fabric_command imperative-op seam + async round-trip
#   8. harness/run-reload.js   — the DEV-3 runtime state seam: _Platform_live{getModel,setModel,
#                                managers} + _Platform_shutdown are opt-in-only (inert without
#                                globalThis._Platform_devSeam), round-trip a model, and shutdown
#                                clears the handle so a reload does not double-subscribe.
#   9. harness/run-reload-typehash.js — DEV-8 true state-preserving Fast Refresh + Model type-hash
#                                fallback: native.js's reload seam stamps the OLD bundle's structural
#                                Model type-hash into the capture carrier and, on remount, compares it
#                                with the NEW bundle's __canopy_model_typehash. EQUAL → restore the live
#                                model (state preserved across reload); DIFFERENT → keep the fresh init
#                                model + post a 'Model changed' notice (no crash). Drives the REAL counter
#                                bundle through the full reload loop twice (compatible + incompatible)
#                                plus the backward-compat (no hash on either side → preserve) path.
#  10. harness/bench.js        — the median-frame-cost regression guard (RND-3 timings) + the AND-8
#                                scalar fast-path guard: the dominant per-frame mutations (text/value/
#                                opacity) must take __fabric_updatePropScalar (no JSON marshalling),
#                                and each scenario's p50 must not regress past the baseline tolerance.
#                                NOTE: the absolute ns are x86_64/CI numbers; the real arm64 per-frame-ms
#                                ledger (AND-8 Phase A) is a device task — see plans/independent/AND-8.md.
#  11. check-rn-coupling.sh    — the RN coupling guard (jsi/Hermes/Yoga frozen to an allowlist;
#                                no RCTBridge/TurboModule/fbjni/MountingManager) — see docs/rn-coupling.md
#  12. check-release-bundle-security.sh — RB-3 device-free release-load safety guard: the
#                                /data/local/tmp dev override is DEBUG-gated and the integrity
#                                check is fail-closed (throws) only in release.
#  13. harness/run-coalesce.js  — the AND-9 Cmd/Sub completion coalescing + latest-wins backpressure
#                                policy (executable spec of CanopyCompletionScheduler): a 1000-event
#                                burst within one frame batches into ONE main-Looper post (bounded
#                                backlog), no FINAL value is dropped, and an opt-in stream collapses
#                                to its newest frame. The Java class is unit-tested on the JVM
#                                (:app:testDebugUnitTest CanopyCompletionSchedulerTest); this is the
#                                device-free CI gate that the policy did not drift.
#  14. harness/run-list-perf.js — the RND-6 windowing proof: Native.List wraps each windowed row's
#                                renderItem in VirtualDom.lazy, so a scroll that does not cross a row
#                                boundary diffs to ZERO Fabric ops and off-window rows are never
#                                mounted. Drives the REAL compiled examples/listtest bundle (1000
#                                rows) end-to-end against the mock Fabric, AND instruments the walker
#                                directly to prove the lazy wrap stops per-row renderItem re-invocation
#                                (the discriminator). Builds the listtest bundle first if absent.
#  15. check-vendor-pins.sh     — RNV-8 cross-platform RN-version grep-guard: the one react-native
#                                release must be pinned identically across the iOS Podfile, the baked
#                                C++ ABI pin, vendor.lock.json, and the Android CMakeLists. A one-sided
#                                bump (e.g. Podfile only) goes red. Pure grep + jq, no device.
#  16. check-abi.sh             — RNV-2/RNV-8 headless Hermes/JSI ABI gate: re-extracts the pinned
#                                libhermes' bytecode version and proves it equals the baked C++ pin +
#                                vendor.lock.json + the boot path. Needs the vendored libhermes.so on
#                                disk (a fresh clone restores it via scripts/fetch-vendor.sh); SKIPPED
#                                with a notice if it is absent so the gate stays offline-runnable.
#  17. harness/perf-bar.js      — the RND-9 ratified competitive perf bar. Gates the COMMITTED ledger
#                                (harness/perf-ledger.json — real canopy device + walker numbers) against
#                                the owner-signed multipliers (harness/perf-bar.json) vs React Native
#                                0.76.9: list jank <=1.2x RN & <=5% dropped, tap-to-paint <= RN+4ms,
#                                cold TTI <=1.3x RN (advisory until CMP-8 .hbc), peak RSS <=1.5x RN, and
#                                the HARD device-free no-op-frame = 0 host mutations. The no-op-frame +
#                                dropped-frame gates are RN-independent and always enforced; the
#                                RN-relative rows are reported but do NOT block while the RN reference is
#                                unverified (RN 0.76.9 is not installed here) — a soft reference must
#                                never gate a build. A --selftest proves the gate logic device-free.
#  18. check-hermes-cabi.sh     — RNV-4 Hermes runtime-factory seam guard + C-ABI capability probe:
#                                proves BOTH boot sites (Android CanopyHostJni.cpp, iOS
#                                CanopyHostViewController.mm) create the runtime through the ONE
#                                factory canopy::makeRuntime() (CanopyHermes.cpp) and no longer name
#                                makeHermesRuntime() directly, and that CanopyHermes.cpp wraps both
#                                backends (C++ makeHermesRuntime + the stable C-vtable
#                                makeHermesABIRuntimeWrapper/get_hermes_abi_vtable) behind
#                                CANOPY_HERMES_CABI. ALSO probes the vendored libhermes.so for the
#                                C-ABI export (the RNV-6 gate): ADVISORY only — the RN-bundled .so
#                                ships only the C++ factory today, so the default backend stays (A);
#                                the probe flips to "available" the day a standalone Hermes is
#                                vendored. Pure grep + nm/python, no device.
#
# Usage:  ./scripts/ci-test.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

echo "==> [1/18] canopy test tests/"
( cd "$ROOT/package" && canopy test tests/ ) || fail=1

echo
echo "==> [2/18] harness/run.js (targeted updates)"
node "$ROOT/harness/run.js" || fail=1

echo
echo "==> [3/18] harness/run-batch.js (RND-7 batched binary marshalling: equivalence + collapse invariant)"
node "$ROOT/harness/run-batch.js" || fail=1

echo
echo "==> [4/18] harness/run-keyed.js (LIS reconciler)"
node "$ROOT/harness/run-keyed.js" || fail=1

echo
echo "==> [5/18] harness/run-lazy.js (lazy memoization)"
node "$ROOT/harness/run-lazy.js" || fail=1

echo
echo "==> [6/18] harness/run-echo.js (native-module ABI)"
node "$ROOT/harness/run-echo.js" || fail=1

echo
echo "==> [7/18] harness/run-command.js (imperative-command seam)"
node "$ROOT/harness/run-command.js" || fail=1

echo
echo "==> [8/18] harness/run-reload.js (DEV-3 state seam: _Platform_live / _Platform_shutdown)"
node "$ROOT/harness/run-reload.js" || fail=1

echo
echo "==> [9/18] harness/run-reload-typehash.js (DEV-8 state-preserving Fast Refresh + Model type-hash fallback)"
# DEV-8: native.js's reload seam now compares the OLD bundle's structural Model type-hash (stamped
# into the capture carrier) against the NEW bundle's __canopy_model_typehash, restoring the live
# model on an EQUAL hash (true state-preserving Fast Refresh) and falling back to a fresh init +
# a 'Model changed' notice on a DIFFERENT one (no crash). Drives the REAL counter bundle through the
# full reload loop twice (compatible + incompatible) plus the backward-compat (no-hash → preserve)
# path. The bundle is rebuilt above if absent; canopy-native is on PATH.
if [ ! -f "$ROOT/examples/counter/build/canopy.bundle.js" ]; then
  echo "    (building examples/counter bundle — not present)"
  canopy-native build "$ROOT/examples/counter" || fail=1
fi
node "$ROOT/harness/run-reload-typehash.js" || fail=1

echo
echo "==> [10/18] harness/bench.js (median-frame-cost + AND-8 scalar fast-path guard)"
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
echo "==> [11/18] check-rn-coupling.sh (RN coupling guard)"
bash "$ROOT/scripts/check-rn-coupling.sh" || fail=1

echo
echo "==> [12/18] check-release-bundle-security.sh (RB-3 release-load safety guard)"
bash "$ROOT/scripts/check-release-bundle-security.sh" || fail=1

echo
echo "==> [13/18] harness/run-coalesce.js (AND-9 completion coalescing + backpressure)"
node "$ROOT/harness/run-coalesce.js" || fail=1

echo
echo "==> [14/18] harness/run-list-perf.js (RND-6 Native.List windowing: lazy rows → zero off-window work)"
# Part 1 drives the REAL compiled examples/listtest bundle; build it if the artifact is absent so
# CI is self-contained (mirrors run-compiled.js's counter-bundle prereq). canopy-native is on PATH.
if [ ! -f "$ROOT/examples/listtest/build/canopy.bundle.js" ]; then
  echo "    (building examples/listtest bundle — not present)"
  canopy-native build "$ROOT/examples/listtest" || fail=1
fi
node "$ROOT/harness/run-list-perf.js" || fail=1

echo
echo "==> [15/18] check-vendor-pins.sh (RNV-8 cross-platform RN-version pin guard)"
bash "$ROOT/scripts/check-vendor-pins.sh" || fail=1

echo
echo "==> [16/18] check-abi.sh (RNV-2/RNV-8 Hermes/JSI ABI gate)"
# Needs the vendored libhermes.so on disk. A fresh clone restores it via scripts/fetch-vendor.sh;
# keep the regression gate offline-runnable by SKIPPING (not failing) when the .so is absent.
if [ -f "$ROOT/host/android/vendor/lib/arm64-v8a/libhermes.so" ]; then
  bash "$ROOT/scripts/check-abi.sh" || fail=1
else
  echo "    SKIP — vendored libhermes.so absent (run scripts/fetch-vendor.sh to enable this gate)."
fi

echo
echo "==> [17/18] harness/perf-bar.js (RND-9 ratified competitive perf bar)"
# Two layers, both device-free: (a) --selftest proves the gate LOGIC (no-op-frame is hard,
# RN-relative rows are advisory while the RN reference is unverified, the multipliers are wired
# from perf-bar.json); (b) the gate itself evaluates the COMMITTED ledger (real canopy device +
# walker numbers) against the ratified bar. The no-op-frame + dropped-frame gates are RN-independent
# and DO block; the RN-relative rows are reported but do not block until a real rn.json lands.
node "$ROOT/harness/perf-bar.js" --selftest || fail=1
node "$ROOT/harness/perf-bar.js" || fail=1

echo
echo "==> [18/18] check-hermes-cabi.sh (RNV-4 Hermes runtime-factory seam + C-ABI capability probe)"
# Proves the RNV-4 seam is wired (both boot sites create the runtime via canopy::makeRuntime() and
# no longer name makeHermesRuntime() directly; CanopyHermes.cpp wraps both backends behind
# CANOPY_HERMES_CABI). The C-ABI capability probe of the vendored libhermes.so is ADVISORY (the
# RN-bundled .so ships only the C++ factory today — backend (A) stays the default until RNV-6
# vendors a standalone Hermes that exports get_hermes_abi_vtable). Pure grep + nm/python, no device.
bash "$ROOT/scripts/check-hermes-cabi.sh" || fail=1

echo
if [ "$fail" -eq 0 ]; then
  echo "ALL GREEN — canopy/native regression gate passed."
else
  echo "REGRESSION — one or more suites failed." >&2
fi
exit "$fail"
