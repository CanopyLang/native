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
#   3b. harness/run-jsthread.js — RND-8 off-UI-thread marshalling (builds on RND-7). The JS/Hermes
#                                runtime moves to a DEDICATED thread; a frame's view writes are shipped
#                                to the UI thread as ONE flat binary batch per frame (BatchSink ->
#                                applyBatchOnUi -> runUiBatch). Drives the REAL element+animator stack in
#                                off-UI-thread mode and proves: (A) the JS thread makes ZERO direct view
#                                writes (tree empty until the UI drain), (B) a drained run is byte-identical
#                                to the inline binary path, (C) DECORRELATION — N frames produced while the
#                                UI thread is busy queue without blocking JS, then one drain applies them
#                                all, and (D) one cross-thread message per non-empty frame (no-op = 0).
#                                The on-device run is `setprop debug.canopy.jsthread 1` (assembleDebug +
#                                emulator) — see plans/dependent/RND-8.md.
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
#   9b. harness/run-reload-recovery.js — DEV-11 reload-FAILURE recovery + source-map piping: native.js
#                                records the last-known-good model on a host global (survives the reload
#                                re-eval), __canopy_recoverLastGood restores it (type-hash gated) so a
#                                failed reload recovers to the prior good state instead of a fatal red-box,
#                                the symbolicator cache resets on every re-boot, and __canopy_setSourcemap
#                                pipes the WS map so a post-reload red-box resolves against the new map.
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
#  19. check-ios-devloop.sh     — DEV-12 iOS dev-loop parity gate: the iOS host can't be compiled off
#                                macOS, so this STRUCTURAL gate proves device-free that the iOS dev loop
#                                (CanopyHostViewController -reloadWithBundle: + the
#                                NSURLSessionWebSocketTask CanopyDevClient + the debug CanopyDevBootstrap)
#                                is the faithful twin of the Android-validated DEV-4/DEV-6 loop: the same
#                                __canopy_captureState/_teardown/_remount reload seam + Elm reset + re-boot
#                                onto the cached root, the same five-frame wire protocol, the same
#                                cleartext-allowlist ranges (with the ATS NSAllowsLocalNetworking platform
#                                belt), and an XCTest pinning the pure decision layer. Pure grep, no device.
#  20. harness/run-reload-perf.js — the DEV-10 reload-diff perf gate (builds on DEV-8 + RND-1). A
#                                state-preserving reload re-DIFFS only the changed subtree. PART 1 drives
#                                the REAL compiled listtest bundle (1000 lazy rows) through the full DEV-8
#                                reload loop (capture → teardown → re-eval → re-boot onto the SAME root →
#                                remount) and proves the unchanged-list reload re-diffs to ZERO row work
#                                (0 create / 0 row update / 0 structural — the §8 reload criterion at 1000
#                                rows), inside a 1s budget. PART 2 drives the REAL walker directly with a
#                                large keyed list of lazy rows and changes EXACTLY ONE row across the
#                                reload, asserting across N ∈ {50,200,1000} that create==0, update==1,
#                                structural==0 and renderItem re-invokes exactly once — the cost is
#                                CONSTANT in N (O(changed), not O(N)). PART 3 times the re-diff under
#                                budget and proves the budget is hostage to the lazy fix (RND-1): an EAGER
#                                list re-renders all N rows on the same one-row reload, the lazy list
#                                re-renders one. Reuses the listtest bundle built for step 14.
#  21. check-ios-validation-ledger.sh — IOS-6 FULL Part-5 iOS validation-ledger gate: the iOS host
#                                can't be compiled off macOS, so this STRUCTURAL gate proves device-free
#                                that EVERY Part-5 gate (render/events/ScrollView/TextInput/Image/Switch/
#                                Modal/BeforeAfter/anim/each C1 capability/streaming) has its load-bearing
#                                seam present in the host, mirrors the Android device-validated ledger,
#                                and is covered by the XCUITest (CanopyHostValidationTests.swift) + the
#                                ObjC++ XCTest (CanopyValidationLedgerTests.mm). Also cross-checks that
#                                every capability the iOS caps[] names exists on the Android side (neither
#                                platform drifts ahead). Pure grep, no device/Mac. The real Simulator
#                                ledger run is host/ios/PART5-LEDGER.md + §5 of host/ios/BUILD-AND-VALIDATE.md.
#  22. check-ios-capability-parity.sh — IOS-7 iOS<->Android capability parity gate: closes the
#                                capability divergence. The iOS host can't be compiled off macOS, so this
#                                STRUCTURAL gate proves device-free that for EVERY Android JniModule
#                                capability (host/android/.../modules/<Name>Module.java) there is a
#                                registered, protocol-conformant iOS twin Canopy<Name>Module.mm — it
#                                adopts <CanopyModule> (or subclasses CanopyStreamingModuleBase), reports
#                                the matching -moduleName, handles every method its .can wire contract
#                                calls, and is wired into CanopyModuleHost.mm's registerAll caps[]. So an
#                                app loses NO capability on iOS (Vibration/Battery/DeviceInfo/NetInfo/
#                                Haptics/Brightness + the prior set). Pure grep, no device/Mac; the real
#                                per-twin dispatch is exercised on a Simulator by CanopyHostUITests + the
#                                device-free CanopyCapabilityParityTests.mm XCTest.
#  23. check-ios-command-seam.sh — IOS-8 imperative-command seam gate: the iOS half of the ONE shared
#                                imperative seam, reconciled with AND-3 (one __fabric_command global, one
#                                CanopyHost::command virtual, one __callId -> __commandResult JS path). The
#                                iOS host can't be compiled off macOS, so this STRUCTURAL gate proves
#                                device-free that the ONE seam exists, no second __fabric_callMethod global
#                                crept in, and the iOS command() override (focus/blur/measure/scrollTo/
#                                scrollToIndex + parseCallId/measureResultJson/mergeCallId) is the faithful
#                                twin of Android's AND-4. The pure marshalling is also pinned device-free by
#                                CanopyValidationLedgerTests.mm; the UIKit behaviours run on a Simulator.
#  24. harness/run-stress.js   — RND-10 reconciler stress/fuzz, promoted by RND-11 to a HARD per-commit
#                                gate: thousands of seeded random mutations over depth-30/breadth-5000
#                                keyed trees, asserting (per frame) no-crash + a structural oracle +
#                                child-order + handle identity + diff==rebuild + no-handle-leak, PLUS the
#                                move-minimality scaling assertion (full reverse of N keyed children ==
#                                exactly N-1 inserts — the deterministic guard that an O(n)->O(n^2)
#                                reconciler regression cannot land). The structural counterpart to the
#                                bench.js p95 timing gate. Run --quick here; full sweep is standalone via
#                                scripts/perf-regression-gate.sh. Device-free.
#  25. check-ios-perf-gate.sh  — RND-11 iOS per-commit perf-gate mirror: the iOS host can't be compiled
#                                off macOS, so this STRUCTURAL gate proves device-free that the iOS perf
#                                path is wired to the SAME per-commit gate (the four shared walker gates
#                                over package/external/native.js — the SAME JS the iOS host boots, so
#                                there is no second iOS reconciler to time) AND the SAME relative-baseline
#                                discipline (df-ios-trace-summary.mjs -> perf-report.js --baseline
#                                harness/perf-baselines/<device>.json; jank% additive points + p95
#                                frame-time multiple, never an absolute ms). One gate, both platforms.
#  26. check-cross-platform-vectors.sh — IOS-9 shared cross-platform test-vector suite anti-drift gate.
#  27. check-ios-release-archive.sh — IOS-10 iOS release-archive config gate (the iOS analog of AND-2):
#                                the iOS host can't be ARCHIVED off macOS, so this STRUCTURAL gate proves
#                                device-free that the CONFIG=Release device archive path is complete + App-
#                                Store-clean — CanopyHostRelease.entitlements flips aps-environment to
#                                production (otherwise == the Debug set), project.yml wires it to the
#                                Release config with Automatic signing + an INJECTED (never-committed) Team
#                                ID + bitcode off, the -Os archive keeps the registry-reached registrations
#                                (-ObjC/-all_load so the +load module regs + weak Core ML factory survive
#                                dead-strip), Info.plist ENFORCES ATS (no NSAllowsArbitraryLoads; only the
#                                inert dev-loop NSAllowsLocalNetworking belt), ExportOptions.plist is the
#                                app-store-connect/automatic/uploadSymbols export config with no committed
#                                team, and remote-build.sh has the archive+export driver. Pure bash + grep +
#                                python3 plistlib. The real signed .ipa is Mac-and-paid-Apple-account-gated.
#  28. check-ios-testflight.sh — IOS-11 iOS TestFlight upload-pipeline gate (builds on IOS-10): the upload
#                                is Mac + paid-Apple-account-gated (xcrun altool is macOS-only; the ASC API
#                                key needs a real App Store Connect app record), so this STRUCTURAL gate
#                                proves device-free that the pipeline PRODUCING the upload is wired +
#                                fail-closed + leak-free — remote-build.sh has the validate/testflight/
#                                release subcommands uploading the IOS-10 .ipa via `altool --upload-app`
#                                with the ASC API-key flags (--apiKey/--apiIssuer, never an Apple-ID
#                                password), the upload preflights the three ASC creds + dies LOUD if any
#                                is missing + deletes the staged .p8 after the run, the export channel is
#                                app-store-connect, .gitignore blocks *.p8/private_keys (and no .p8 or
#                                literal Key/Issuer ID is tracked), the ios-build CI job has a TestFlight
#                                upload step gated on the ASC secrets, and docs/ios-testflight.md spells
#                                out the Apple-account+Mac requirements. Pure bash + grep + python3 plistlib.
#  29. check-ios-storekit2.sh    — L-I5 iOS StoreKit 2 paywall gate (the iOS twin of L-A4 Play Billing).
#  29b. check-beforeafter-parity.sh — L-I4 before/after WIPE compositor parity suite (shared math corpus).
#  30. check-ios-lumen-e2e.sh   — L-I6 iPhone lumen-restore E2E PARITY gate: the SAME L-A6 lumen-restore
#                                spine runs green on a real iPhone via XCUITest (testID ->
#                                accessibilityIdentifier). The iOS host can't compile off macOS + there is
#                                no iPhone here, so this STRUCTURAL gate proves device-free that the native
#                                XCUITest spec (CanopyLumenRestoreUITests.swift) drives the WHOLE
#                                pick->restore->compare->share->save->loop spine by testID, asserts the
#                                SAME testIDs + screen copy as the Android Appium spec (e2e/lumen-restore.mjs),
#                                the Appium spec is now platform-neutral (caps.mjs fork + iOS-branched
#                                PHPicker/share-sheet edges so it runs on the XCUITest Appium driver too),
#                                and the iOS fixture is byte-identical to the Android canonical one. The real
#                                Simulator/iPhone run is the Swift file (steps at its top + BUILD-AND-VALIDATE
#                                §5.8). Pure bash + grep.
#
# The per-commit PERF gate proper (RND-11) is steps 5/10/14/24 here, packaged standalone as
# scripts/perf-regression-gate.sh: bench.js --gate-p95 (p50+p95 baseline gate) + run-lazy (RND-1
# short-circuit) + run-list-perf (RND-6 windowing) + run-stress (RND-10 fuzz/scaling). A measured bar
# is only credible if a regression FAILS the build — these four make it so.
#
# Usage:  ./scripts/ci-test.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

echo "==> [1/25] canopy test tests/"
( cd "$ROOT/package" && canopy test tests/ ) || fail=1

echo
echo "==> [2/25] harness/run.js (targeted updates)"
node "$ROOT/harness/run.js" || fail=1

echo
echo "==> [3/25] harness/run-batch.js (RND-7 batched binary marshalling: equivalence + collapse invariant)"
node "$ROOT/harness/run-batch.js" || fail=1

echo
echo "==> [3b/25] harness/run-jsthread.js (RND-8 off-UI-thread marshalling: equivalence + decorrelation)"
# RND-8 builds on RND-7: the JS/Hermes runtime moves to a DEDICATED thread and a frame's view writes
# are marshalled to the UI thread as ONE flat binary batch per frame (the device path: __fabric_applyBatch
# BatchSink -> CanopyHostJni.applyBatchOnUi -> main Looper -> runUiBatch -> canopyApplyBinaryBatch). This
# drives the REAL element+animator stack against the mock in off-UI-thread mode (the sink COPIES each
# frame's buffer to a UI-side queue; drainUiBatches models the UI thread replaying it) and proves: (A) the
# JS thread makes ZERO direct view writes (the tree is empty until the UI drain), (B) a drained off-UI-thread
# run is byte-identical to the inline binary path (tree + op log) through boot AND taps, (C) the
# DECORRELATION property — N frames can be produced on the JS thread while the UI thread is busy, the
# buffers queue without blocking JS, and one late drain applies them all to the identical final tree, and
# (D) one cross-thread message per non-empty frame (a no-op frame ships zero). Device-free; the on-device
# run is gated behind `setprop debug.canopy.jsthread 1` (assembleDebug + emulator) — see plans/dependent/RND-8.md.
node "$ROOT/harness/run-jsthread.js" || fail=1

echo
echo "==> [4/25] harness/run-keyed.js (LIS reconciler)"
node "$ROOT/harness/run-keyed.js" || fail=1

echo
echo "==> [5/25] harness/run-lazy.js (lazy memoization)"
node "$ROOT/harness/run-lazy.js" || fail=1

echo
echo "==> [6/25] harness/run-echo.js (native-module ABI)"
# run-echo drives the Echo example bundle (Echo.send -> Native.Module.call -> __canopy_call); it
# exits 2 if that bundle is absent. On a fresh CI runner only examples/counter is pre-built, so
# build the echo bundle here if missing (canopy-native is on PATH; deps are linked + `canopy setup`).
if [ ! -f "$ROOT/examples/echo/build/canopy.bundle.js" ]; then
  echo "    (building examples/echo bundle — not present)"
  canopy-native build "$ROOT/examples/echo" || fail=1
fi
node "$ROOT/harness/run-echo.js" || fail=1

echo
echo "==> [7/25] harness/run-command.js (imperative-command seam)"
node "$ROOT/harness/run-command.js" || fail=1

echo
echo "==> [8/25] harness/run-reload.js (DEV-3 state seam: _Platform_live / _Platform_shutdown)"
node "$ROOT/harness/run-reload.js" || fail=1

echo
echo "==> [9/25] harness/run-reload-typehash.js (DEV-8 state-preserving Fast Refresh + Model type-hash fallback)"
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
echo "==> [9b/25] harness/run-reload-recovery.js (DEV-11 reload-FAILURE recovery + source-map piping)"
# DEV-11: a reload whose new bundle throws must NOT leave a dead program on a fatal red-box. native.js's
# reload seam now records the last-known-good model (captureState, taken while the old good program is
# still live) on a host global that survives the whole-bundle re-eval, and __canopy_recoverLastGood
# restores it (type-hash gated) onto the re-evaled last-good bundle — so the user lands back where they
# were. It also resets the symbolicator cache on every re-boot + exposes __canopy_setSourcemap so a
# post-reload red-box resolves against the RELOADED program's map. Drives the REAL counter bundle
# through boot → advance → failed reload (prior tree/snapshot survive) → recover → successful reload
# (baseline advances) → source-map re-point. Reuses the bundle built/rebuilt for step 9.
if [ ! -f "$ROOT/examples/counter/build/canopy.bundle.js" ]; then
  echo "    (building examples/counter bundle — not present)"
  canopy-native build "$ROOT/examples/counter" || fail=1
fi
node "$ROOT/harness/run-reload-recovery.js" || fail=1

echo
echo "==> [10/25] harness/bench.js (median-frame-cost + AND-8 scalar fast-path guard + RND-11 p95 gate)"
# The AND-8 scalar fast-path guard + the lazy short-circuit guard are TIMING-INDEPENDENT (they
# exit 1 on a logic failure regardless of CPU speed). The frame-cost gate, however, is run here
# back-to-back AFTER the suites above, so this process tree is under sustained load — the bench's own
# header warns that ns figures are machine/load-dependent. So the p50 (median) gate runs at a WIDE
# 100% tolerance: it still catches what it exists for (an algorithmic O(n)->O(n^2) reconciler blowup
# is 5-50x at N=200) without flaking on the 1.5-2x CPU jitter a loaded shared runner shows.
# RND-11's --gate-p95 catches a tail-frame regression that leaves the median flat (a slow path firing
# 1-in-20 frames, an alloc that triggers GC). But the TAIL is noisier than the median on a loaded
# shared runner — strictly MORE run-to-run variance than the p50 — so gating it tight here (the old
# 10%) flaked CI on pure jitter (e.g. scalarFastPath p95 +12%) without catching a real regression.
# On the DEVICE-FREE gate the p95 therefore runs at the SAME wide 100% as the p50: it still backstops
# the gross O(n)->O(n^2) tail blowup (5-50x at N=200) it exists for, without flaking. The TIGHT 10%
# p95 (RND-11's headline) lives in the standalone scripts/perf-regression-gate.sh, meant for a
# quiet/dedicated CI machine class with a re-recorded baseline; the real arm64 per-frame-ms ledger
# (AND-8 Phase A) is the device task — see plans/independent/AND-8.md.
node "$ROOT/harness/bench.js" --baseline "$ROOT/harness/bench-baseline.json" \
  --tolerance 1.0 --gate-p95 --p95-tolerance 1.0 || fail=1

echo
echo "==> [11/25] check-rn-coupling.sh (RN coupling guard)"
bash "$ROOT/scripts/check-rn-coupling.sh" || fail=1

echo
echo "==> [12/25] check-release-bundle-security.sh (RB-3 release-load safety guard)"
bash "$ROOT/scripts/check-release-bundle-security.sh" || fail=1

echo
echo "==> [13/25] harness/run-coalesce.js (AND-9 completion coalescing + backpressure)"
node "$ROOT/harness/run-coalesce.js" || fail=1

echo
echo "==> [14/25] harness/run-list-perf.js (RND-6 Native.List windowing: lazy rows → zero off-window work)"
# Part 1 drives the REAL compiled examples/listtest bundle; build it if the artifact is absent so
# CI is self-contained (mirrors run-compiled.js's counter-bundle prereq). canopy-native is on PATH.
if [ ! -f "$ROOT/examples/listtest/build/canopy.bundle.js" ]; then
  echo "    (building examples/listtest bundle — not present)"
  canopy-native build "$ROOT/examples/listtest" || fail=1
fi
node "$ROOT/harness/run-list-perf.js" || fail=1

echo
echo "==> [15/25] check-vendor-pins.sh (RNV-8 cross-platform RN-version pin guard)"
bash "$ROOT/scripts/check-vendor-pins.sh" || fail=1

echo
echo "==> [16/25] check-abi.sh (RNV-2/RNV-8 Hermes/JSI ABI gate)"
# Needs the vendored libhermes.so on disk. A fresh clone restores it via scripts/fetch-vendor.sh;
# keep the regression gate offline-runnable by SKIPPING (not failing) when the .so is absent.
if [ -f "$ROOT/host/android/vendor/lib/arm64-v8a/libhermes.so" ]; then
  bash "$ROOT/scripts/check-abi.sh" || fail=1
else
  echo "    SKIP — vendored libhermes.so absent (run scripts/fetch-vendor.sh to enable this gate)."
fi

echo
echo "==> [17/25] harness/perf-bar.js (RND-9 ratified competitive perf bar)"
# Two layers, both device-free: (a) --selftest proves the gate LOGIC (no-op-frame is hard,
# RN-relative rows are advisory while the RN reference is unverified, the multipliers are wired
# from perf-bar.json); (b) the gate itself evaluates the COMMITTED ledger (real canopy device +
# walker numbers) against the ratified bar. The no-op-frame + dropped-frame gates are RN-independent
# and DO block; the RN-relative rows are reported but do not block until a real rn.json lands.
node "$ROOT/harness/perf-bar.js" --selftest || fail=1
node "$ROOT/harness/perf-bar.js" || fail=1

echo
echo "==> [18/25] check-hermes-cabi.sh (RNV-4 Hermes runtime-factory seam + C-ABI capability probe)"
# Proves the RNV-4 seam is wired (both boot sites create the runtime via canopy::makeRuntime() and
# no longer name makeHermesRuntime() directly; CanopyHermes.cpp wraps both backends behind
# CANOPY_HERMES_CABI). The C-ABI capability probe of the vendored libhermes.so is ADVISORY (the
# RN-bundled .so ships only the C++ factory today — backend (A) stays the default until RNV-6
# vendors a standalone Hermes that exports get_hermes_abi_vtable). Pure grep + nm/python, no device.
bash "$ROOT/scripts/check-hermes-cabi.sh" || fail=1

echo
echo "==> [19/25] check-ios-devloop.sh (DEV-12 iOS dev-loop parity gate)"
# DEV-12: the iOS host can't be compiled off macOS, so this STRUCTURAL gate proves device-free that
# the iOS dev loop (CanopyHostViewController -reloadWithBundle: + the NSURLSessionWebSocketTask
# CanopyDevClient + the debug CanopyDevBootstrap) is the faithful twin of the Android-validated
# DEV-4/DEV-6 loop: the same __canopy_captureState/_teardown/_remount reload seam + Elm reset +
# re-boot onto the cached root, the same five-frame wire protocol, the same cleartext-allowlist
# ranges (with the ATS NSAllowsLocalNetworking platform belt), and an XCTest that pins the pure
# decision layer. Pure grep, no device/Mac. A real Simulator reload run is in host/ios/README-ios.md.
bash "$ROOT/scripts/check-ios-devloop.sh" || fail=1

echo
echo "==> [20/25] harness/run-reload-perf.js (DEV-10 reload-diff perf gate: O(changed), not O(N))"
# DEV-10 builds on DEV-8 (the state-preserving reload seam) + RND-1/RND-6 (the lazy short-circuit).
# PART 1 drives the REAL compiled listtest bundle through the full reload loop, so it needs the same
# listtest bundle step 14 builds; build it here too if it is somehow absent (standalone-runnable), and
# canopy-native is on PATH. PARTS 2-3 drive the bare walker (no bundle). The whole gate is device-free.
if [ ! -f "$ROOT/examples/listtest/build/canopy.bundle.js" ]; then
  echo "    (building examples/listtest bundle — not present)"
  canopy-native build "$ROOT/examples/listtest" || fail=1
fi
node "$ROOT/harness/run-reload-perf.js" || fail=1

echo
echo "==> [21/25] check-ios-validation-ledger.sh (IOS-6 FULL Part-5 iOS validation-ledger gate)"
# IOS-6: the iOS host can't be compiled off macOS, so this STRUCTURAL gate proves device-free that
# EVERY Part-5 gate (render/events/ScrollView/TextInput/Image/Switch/Modal/BeforeAfter/anim/each C1
# capability/streaming) has its load-bearing seam present in the host, mirrors the Android
# device-validated ledger, and is covered by the XCUITest (CanopyHostValidationTests.swift) + the
# ObjC++ XCTest (CanopyValidationLedgerTests.mm) — plus a parity cross-check that every capability the
# iOS caps[] names exists on the Android side. Pure grep, no device/Mac. The real Simulator ledger run
# is host/ios/PART5-LEDGER.md + §5 of host/ios/BUILD-AND-VALIDATE.md.
bash "$ROOT/scripts/check-ios-validation-ledger.sh" || fail=1

echo
echo "==> [22/25] check-ios-capability-parity.sh (IOS-7 iOS<->Android capability parity gate)"
# IOS-7: closes the iOS<->Android capability divergence — every Android JniModule capability
# (Vibration/Battery/DeviceInfo/NetInfo/Haptics/Brightness + the prior set) now has a registered,
# protocol-conformant iOS twin (Canopy<Name>Module.mm), so an app loses NO capability on iOS. The
# iOS host can't be compiled off macOS, so this STRUCTURAL gate proves device-free that for every
# Android <Name>Module.java there is an iOS Canopy<Name>Module.mm that adopts <CanopyModule> (or the
# streaming base), names itself correctly, handles every .can method, and is wired into registerAll's
# caps[]. Pure grep, no device/Mac. The real per-twin dispatch is exercised on a Simulator by
# host/ios/Tests/CanopyHostUITests + the device-free CanopyCapabilityParityTests.mm XCTest.
bash "$ROOT/scripts/check-ios-capability-parity.sh" || fail=1

echo "==> [22b/28] check-ios-restore-coreml.sh (L-I3 iOS RestoreEngine Core ML / ANE gate)"
# L-I3: the iOS RestoreEngine runs the ESPCN photo super-resolution on Apple's Neural Engine via
# Core ML (CanopyRestoreEngineModule.mm). Neither the iOS host (CoreML/Xcode link) nor Core ML
# inference (Apple-only) can run off macOS, so this STRUCTURAL gate proves device-free that the path
# is complete + self-consistent: the ESPCN->Core ML converter (convert_restore.py) exists and
# validates topology, the previously-dead weak symbol CanopyMakeCoreMLRestoreModule is strongly
# defined, the module is a real Core ML capability (MLComputeUnitsAll/predictionFromFeatures), the
# .mm MLMultiArray IO shapes match the converter's [1,1,224,224]->[1,1,672,672] model IO, the shipped
# restore.mlpackage is a well-formed Core ML package whose proto declares the same input/output dims,
# and project.yml copies it into the .app. The converter's arithmetic equivalence to the Android ORT
# path was verified by the rebuild (max abs err 1.5e-6 vs the ONNX reference); the real ANE inference
# is exercised on a device by host/ios/Tests/CanopyHostUITests + the device-free
# CanopyCapabilityParityTests.mm RestoreEngine XCTest legs.
bash "$ROOT/scripts/check-ios-restore-coreml.sh" || fail=1

echo "==> [23/25] check-ios-command-seam.sh (IOS-8 imperative-command seam gate)"
# IOS-8: the iOS half of the ONE shared imperative-command seam — reconciled with AND-3 so there is
# exactly one global (__fabric_command), one host virtual (CanopyHost::command), and one JS routing
# path (__callId -> __commandResult). The iOS host's command() override (focus/blur/measure/scrollTo/
# scrollToIndex) is the line-for-line twin of Android's AND-4 CanopyHost.java::command. The iOS host
# can't be compiled off macOS, so this STRUCTURAL gate proves device-free that the ONE seam exists,
# that no second __fabric_callMethod global crept in, and that the iOS ops + the pure marshalling
# (parseCallId/measureResultJson/mergeCallId) match Android. The pure marshalling is ALSO pinned by an
# XCTest (CanopyValidationLedgerTests.mm); the UIKit behaviours run on a Simulator (CanopyHostValidationTests.swift).
bash "$ROOT/scripts/check-ios-command-seam.sh" || fail=1

echo
echo "==> [23b/28] check-ios-marshalling.sh (IOS-12 iOS hot-path marshalling gate)"
# IOS-12: the iOS half of the per-frame marshalling fast-path — the iOS twin of AND-8 (the single-scalar
# __fabric_updatePropScalar fast path) and RND-7 (the per-frame binary __fabric_applyBatch). The shared
# installer (CanopyFabric.cpp) + the ONE reconciler the iOS host boots (package/external/native.js) are
# platform-neutral and already exercised device-free by harness/run-batch.js + bench.js. What is
# PLATFORM-SPECIFIC and uncompilable off macOS is the iOS CanopyHost override that realizes the win on
# UIKit views: updatePropScalar applying text/value/opacity WITHOUT an NSJSONSerialization round-trip,
# and the 3-arg createView registering a batched view at the JS-CHOSEN handle (without it, every
# post-create op in a batched frame would miss views_ and silently no-op — batched rendering would draw
# nothing on iOS). This STRUCTURAL gate proves device-free that both overrides exist, funnel through ONE
# shared createAt, mirror the Android-validated host (CanopyHost.java updatePropScalar/createViewWithHandle),
# and are wired to the shared ABI + walker; the pure key→property + batch-handle decision is pinned by
# CanopyValidationLedgerTests.mm. Pure bash + grep, no device/Mac. The real on-Simulator render/tap run
# is host/ios/PART5-LEDGER.md + BUILD-AND-VALIDATE.md.
bash "$ROOT/scripts/check-ios-marshalling.sh" || fail=1

echo
echo "==> [24/25] harness/run-stress.js (RND-10 reconciler stress/fuzz — RND-11 hard gate)"
# RND-11 promotes the RND-10 stress/fuzz suite to a HARD per-commit gate (it previously ran only
# standalone). Drives the REAL package/external/native.js walker through thousands of seeded random
# mutations over depth-30/breadth-5000 keyed trees and asserts, every frame: no-crash + a structural
# oracle (built WITHOUT the walker) + child-order + handle identity + diff==rebuild + no-handle-leak,
# PLUS the move-minimality scaling assertion (a full reverse of N keyed children costs exactly N-1
# inserts — the deterministic guard that an O(n)->O(n^2) reconciler regression can never land). This is
# the structural/correctness counterpart to bench.js's p95 timing gate. --quick keeps the per-commit
# cost bounded (the full sweep is run standalone via scripts/perf-regression-gate.sh). Device-free.
node "$ROOT/harness/run-stress.js" --quick || fail=1

echo
echo "==> [25/27] check-ios-perf-gate.sh (RND-11 iOS per-commit perf-gate mirror)"
# RND-11: mirror the per-commit perf gate into the iOS harness. The iOS host can't be compiled off
# macOS, so this STRUCTURAL gate proves device-free that the iOS perf path is wired to the SAME
# per-commit gate (the four shared walker gates over package/external/native.js — the SAME JS the iOS
# host boots, so there is no second iOS reconciler to time) AND the SAME relative-baseline discipline:
# the iOS device frame-trace lane (df-ios-trace-summary.mjs -> perf-report.js --baseline
# harness/perf-baselines/<device>.json) is gated relatively (jank% additive points, p95 frame-time
# multiple), never by an absolute millisecond — one gate, both platforms. Pure grep + node --selftest.
bash "$ROOT/scripts/check-ios-perf-gate.sh" || fail=1

echo
echo "==> [26/27] check-cross-platform-vectors.sh (IOS-9 shared cross-platform test-vector suite)"
# IOS-9: the durable anti-drift control for master-plan Risk R5 (two hand-maintained hosts drift; the
# only signal today is a device crash). ONE platform-neutral corpus
# (host/shared/test-vectors/layout-vectors.json) of (component, props, expected Yoga frames + style
# effects) runs on BOTH hosts' REAL Yoga — Android instrumentation (CanopyLayoutVectorTest.java, real
# libyoga.so, emulator-validated here) + iOS XCTest (CanopyLayoutVectorTests.mm, real Yoga pod, Mac).
# The device runs are env-gated, so this STRUCTURAL gate proves device-free that the suite is wired and
# cannot silently rot: the canonical corpus == the Android test-APK copy byte-for-byte, an INDEPENDENT
# oracle (validate-vectors.js) reproduces every expected frame/color, both runners load the corpus and
# normalize the deliberate Android(px)/iOS(points) divergence the right way, and every geometric style
# key the corpus uses is handled by BOTH production applyStyle mappings. Pure bash + grep + node.
bash "$ROOT/scripts/check-cross-platform-vectors.sh" || fail=1

echo
echo "==> [27/28] check-ios-release-archive.sh (IOS-10 iOS release-archive config gate)"
# IOS-10: the iOS analog of AND-2 (the Android signed-release config). The iOS host can't be ARCHIVED
# off macOS, so this STRUCTURAL gate proves device-free that the CONFIG=Release device archive path is
# complete + App-Store-clean: the production entitlements (aps-environment=production, otherwise == the
# Debug set), project.yml's Automatic-signing + injected-Team-ID + bitcode-off + dead-strip-safe
# (-ObjC/-all_load) Release block, the ATS-enforced Info.plist (no blanket cleartext), ExportOptions.plist
# (app-store-connect/automatic/uploadSymbols, no committed team), and the remote-build.sh archive+export
# driver. Pure bash + grep + python3 plistlib. The real signed .ipa is Mac + paid-Apple-account-gated.
bash "$ROOT/scripts/check-ios-release-archive.sh" || fail=1

echo
echo "==> [28/28] check-ios-testflight.sh (IOS-11 iOS TestFlight upload-pipeline gate)"
# IOS-11: the TestFlight upload that builds on IOS-10's signed .ipa. The upload itself is Mac + paid-
# Apple-account-gated (xcrun altool is macOS-only; the ASC API key needs a real App Store Connect app
# record), so this STRUCTURAL gate proves device-free that the pipeline that PRODUCES the upload is
# wired + fail-closed + leak-free: remote-build.sh's validate/testflight/release subcommands upload the
# IOS-10 .ipa via `altool --upload-app` with the ASC API-key flags (never an Apple-ID password), the
# upload preflights the three ASC creds + dies loud if any is missing + deletes the staged .p8, the
# export channel is app-store-connect, .gitignore blocks *.p8/private_keys (and no key material is
# tracked), the ios-build CI job has a secret-gated TestFlight step, and docs/ios-testflight.md spells
# out the Apple-account + Mac requirements. Pure bash + grep + python3. The real upload is Mac-gated.
bash "$ROOT/scripts/check-ios-testflight.sh" || fail=1

echo
echo "==> [28b/29] check-ios-storekit2.sh (L-I5 iOS StoreKit 2 paywall gate)"
# L-I5: the iOS twin of L-A4 (Play Billing) — a StoreKit 2 non-consumable (lifetime_unlock) → a verified
# entitlement → the Lumen paywall gate. StoreKit 2 (Product/Transaction/VerificationResult) is a
# Swift-only async/await API, so the store logic lives in CanopyBillingStoreKit2.swift and
# CanopyBillingModule.mm forwards the one-shots to it (with a StoreKit-1 / fake-store fallback so the
# paywall always renders a price). The iOS host can't be COMPILED off macOS (StoreKit + Xcode are
# Apple-only), so this STRUCTURAL gate proves device-free that the whole paywall is wired: the Swift
# driver drives the real StoreKit 2 APIs + VERIFIES every transaction (fail closed on .unverified), the
# .mm owns the driver under @available(iOS 15) + forwards getProducts/purchase/restore + routes the
# entitlement callback into the portable stream + keeps the fallback, the lifetime_unlock product id is
# identical across the Swift driver / .mm / Products.storekit / Android BillingModule.java, the .storekit
# Simulator config is a well-formed NonConsumable attached to the run+test scheme (not bundled), the
# in-app-purchase entitlement is present in Debug+Release, and the device-free Billing XCTest legs pin
# the dispatch + wire shapes. Pure bash + grep + python3. The real purchase/restore run is a Simulator
# with Products.storekit (no paid account) or a sandbox device — per host/ios/BUILD-AND-VALIDATE.md §6.1.
bash "$ROOT/scripts/check-ios-storekit2.sh" || fail=1

echo
echo "==> [29/29] check-beforeafter-parity.sh (L-I4 before/after wipe-compositor parity suite)"
# L-I4: the anti-drift control for the C2 before/after WIPE compositor — the iOS CanopyBeforeAfterView
# (port of the Android BeforeAfterView from L-A1) and the Android view implement the SAME wipe by hand,
# so they would drift. Both now delegate the wipe's pure MATH (clamp/split/drag/snap/cover/commit-payload)
# to ONE shared header host/shared/cpp/CanopyBeforeAfter.h (iOS: canopy::beforeafter::*; Android:
# CanopyBeforeAfterMath, its Java twin), and ONE corpus host/shared/test-vectors/beforeafter-vectors.json
# asserts that math on BOTH hosts (iOS XCTest CanopyBeforeAfterVectorTests.mm on a Simulator; Android
# JVM unit test CanopyBeforeAfterMathTest, runnable on the build host). The device/Simulator runs are
# env-gated, so this STRUCTURAL gate proves device-free that the suite is wired and cannot silently rot:
# an INDEPENDENT oracle (validate-beforeafter.js, incl. a from-scratch %g formatter) reproduces every
# expected value, both hosts delegate to the shared math (no inline drift), the header and its Java twin
# carry the same rule set + snap duration, both runners consume the corpus, and the project is wired
# (iOS resource bundle + the header in check-portable-cpp.sh). Pure bash + grep + node.
bash "$ROOT/scripts/check-beforeafter-parity.sh" || fail=1

echo
echo "==> [30/30] check-ios-lumen-e2e.sh (L-I6 iPhone lumen-restore E2E parity gate)"
# L-I6: the SAME lumen-restore spec runs green on a real iPhone via XCUITest (testID ->
# accessibilityIdentifier). The iOS host can't be compiled off macOS and there is no iPhone here, so
# this STRUCTURAL gate proves device-free that (A) the native XCUITest spec
# (CanopyLumenRestoreUITests.swift) drives the WHOLE pick->restore->compare->share->save->loop spine
# by testID, (B) it asserts the SAME testIDs + screen copy as the Android Appium spec
# (e2e/lumen-restore.mjs) — so "the same spec, both platforms" is real, not aspirational, (C) the
# Appium spec is now platform-neutral (caps.mjs fork + iOS-branched PHPicker/share-sheet edges) so it
# runs unchanged on the XCUITest Appium driver too, and (D) the iOS test fixture is byte-identical to
# the Android canonical fixture (the same restore input on both platforms). The real Simulator/device
# run is the Swift file itself (run steps at its top + BUILD-AND-VALIDATE.md §5.8). Pure bash + grep.
bash "$ROOT/scripts/check-ios-lumen-e2e.sh" || fail=1

echo
echo "==> [REL-1] check-guarantee-doc.sh (reliability guarantee: live enforcement citations + the five caveats)"
# REL-1: docs/guarantee.md is the precise, honest scope of "correctness-by-construction". This gate
# keeps it honest device-free — it fails if the doc cites an enforcement file that no longer exists
# (a guarantee pointing at a deleted gate) or drops any of the five caveats (an unqualified "no
# errors" overclaim creeping back in). Pure bash + grep.
bash "$ROOT/scripts/check-guarantee-doc.sh" || fail=1

echo
echo "==> [CAP-5] check-compatibility-matrix.sh (full-compatibility surface: in sync + coverage %)"
# CAP-5: docs/compatibility-matrix.json tracks the component + native-capability surface vs RN/Expo.
# This gate fails if a SHIPPED capability (a *Module.java in the host) is missing from the matrix —
# so "full compatibility" stays an honest, tracked number and adding a capability without documenting
# it goes red. It also re-renders docs/compatibility-matrix.md from the JSON. Pure bash + node.
bash "$ROOT/scripts/check-compatibility-matrix.sh" || fail=1

echo
echo "==> [DXL-1] check-fast-refresh-rides-bundle.sh (Model-type-hash emitted into the REAL bundle)"
# DXL-1: state-preserving Fast Refresh keeps the TEA model only when the new bundle's Model type is
# the same shape, decided by a compiler-emitted globalThis.__canopy_model_typehash that native.js
# reads on remount. This gate proves the compiler actually EMITS the assignment into the real bundle
# (not just native.js's reader ref) and fails loud if a compiler bump ever drops it (which would
# silently turn every reload into a full state reset). Pairs with harness/run-reload-typehash.js.
bash "$ROOT/scripts/check-fast-refresh-rides-bundle.sh" || fail=1

echo
echo "==> [REL-5a] run-capability-fuzz.js (native-module seam: malformed input → structured result, never a crash)"
# REL-5: property-fuzz the __canopy_call/__canopy_resolve capability seam — for ANY input (garbage
# JSON, null bytes, huge/deep, wrong-typed, unknown method) the seam never throws, resolves every
# accepted call exactly once, and surfaces a throwing capability body as a structured {code,message}
# rejection. Persisted corpus: harness/fuzz-corpus/capability-inputs.json. Device-free.
node "$ROOT/harness/run-capability-fuzz.js" || fail=1

echo
echo "==> [REL-5b] run-fuzz-corpus.js (replay the pinned reconciler fuzz corpus — deterministic regression)"
# REL-5: run-stress.js fuzzes the reconciler with a time-derived seed (discovery); this replays a
# PINNED seed set (harness/fuzz-corpus/reconciler-seeds.json) every commit so a once-seen failure
# can't vanish. Add a discovered failing seed to the corpus to make it a permanent regression case.
node "$ROOT/harness/run-fuzz-corpus.js" || fail=1

echo
echo "==> [CAP-0] check-autolink-zero-edit.sh (a stranger capability autolinks with ZERO host edits)"
# CAP-0: the compatibility north star, device-free. examples/pingtest depends on the sibling
# capability canopy/ping (declared in its native.json); the autolinker must emit the Ping
# registration into the host's GENERATED registrant from the dep graph alone, leaving every TRACKED
# host/ + package/ file untouched (no host fork), with exactly one registration (deterministic). The
# on-device boot of Ping is the device-gated half (CAP-1). Skips cleanly if the sibling pkg/toolchain
# is absent.
bash "$ROOT/scripts/check-autolink-zero-edit.sh" || fail=1

echo
echo "==> [AAG-1] check-llms-corpus.sh (the AI-assistant idiom corpus compiles)"
# AAG-1: docs/llms-native.txt is fed to LLMs so they write COMPILING Canopy for a zero-training-data
# language; corpus/src/Main.can is the canonical idiom set it points at. This gate compiles the corpus
# every run, so the advertised idioms can never rot into plausible-but-wrong code. Skips if toolchain absent.
bash "$ROOT/scripts/check-llms-corpus.sh" || fail=1

echo
echo "==> [REACH-1] check-rtl-parity.sh (RTL / logical-edge layout wired identically on both hosts)"
# REACH-1: logical, writing-direction-aware edges (paddingStart/End, marginStart/End, start/end) +
# `direction` let ONE view mirror itself for right-to-left locales. This device-free gate greps both
# hosts (+ the public .can API + corpus) to assert every logical key maps to the matching Yoga
# START/END edge on BOTH Android and iOS, so the two mappings can't silently drift apart.
bash "$ROOT/scripts/check-rtl-parity.sh" || fail=1

echo
echo "==> [REPRO-1] check-reproducible-build.sh (same source + pinned compiler ⇒ byte-identical bundle)"
# REPRO-1: the content-addressed buildId is the trust anchor for the crash-free metric (REL-4) and OTA
# (DXL-4). This builds the canonical app twice from a clean tree and asserts the bundle sha256 (==
# manifest buildId) is identical, so a non-deterministic change can't silently break that anchor.
# Skips if the toolchain is absent.
bash "$ROOT/scripts/check-reproducible-build.sh" || fail=1

echo
if [ "$fail" -eq 0 ]; then
  echo "ALL GREEN — canopy/native regression gate passed."
else
  echo "REGRESSION — one or more suites failed." >&2
fi
exit "$fail"
