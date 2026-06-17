# canopy/native CI — the unified gate (CI-7)

This page is the authoritative description of `.github/workflows/ci.yml`. It records the **CI-7**
reconciliation: one canonical example app, one canonical regression-gate script, and **no duplicate
or divergent gate definitions** between what the dev box runs and what CI runs.

## The problem CI-7 fixed

Before CI-7 the device-free gate was defined **twice**:

- `scripts/ci-test.sh` — the script the **dev box** runs (`canopy test` + the full mock-Fabric
  harness + every `check-*.sh` guard); and
- a hand-maintained list of individual `node harness/run*.js` / `bash scripts/check-*.sh` steps
  re-typed inside `ci.yml`'s `gate` job.

The two lists had **drifted**: the CI `gate` ran a strict *subset* of `ci-test.sh`. Worst of all,
the CI gate never ran `ci-test.sh` step **[1] `canopy test tests/`** — because the in-house
`canopy` compiler was not on PATH in that job — so the Canopy-written component/CSS suite was
**not gated in CI** at all ("green" was ambiguous). "Pick one canonical app for bundle/e2e/smoke"
was likewise unstated.

## The reconciliation

### One canonical app

`examples/counter` is **the** canonical app, pinned in
[`scripts/compiler-pin.env`](../scripts/compiler-pin.env) as `CANOPY_PIN_CANONICAL_APP`. It is the
app whose IIFE bundle the F7 acceptance gate verifies, whose bundle the renderer/walker harness
drives, and whose from-source bundle the `bundle` job ships. (`examples/echo` from the source plan
is stale — lower-bound deps + a dangling virtual-dom dir; `counter` is the live, harness-backed app.)

### One canonical gate script

`scripts/ci-test.sh` is **the single definition** of the device-free regression suite. The CI
`gate` job no longer re-lists harness steps — it shells out to that exact script:

```yaml
- name: Canonical device-free gate — scripts/ci-test.sh (CI-7)
  run: |
    export PATH="$HOME/.local/bin:$PATH"
    bash scripts/ci-test.sh
```

so the CI gate and the local gate **cannot drift** into two step lists again. Adding a regression
suite to `ci-test.sh` adds it to CI for free.

### `canopy` is on PATH in the gate → the `canopy test` gap is closed

The `gate` job builds the in-house compiler **from the pin** (CI-2,
`scripts/build-compiler-from-pin.sh`) before running `ci-test.sh`, so `canopy` (and
`canopy-native`) are on PATH. That makes `ci-test.sh`'s **step [1] `canopy test tests/`** actually
**run in CI** — the gap the master plan called out. The same step also runs the **F7 IIFE
acceptance gate** (a `CMP-1` `F7 is not defined` regression fails the build), which means the
gate job **subsumes the former standalone `rebuild-bundle` job** — one compiler-from-pin setup, one
shared pin-keyed Stack cache, instead of two near-identical jobs.

### `run-symbolicate.js` added to the gate

The gate runs the **online** source-map symbolicator (`harness/run-symbolicate.js`, DX M0 — the
online sibling of `ci-test.sh`'s offline AND-10 retrace, `run-symbolicate-offline.js`). It drives
the real `_Native_symbolicate` from `package/external/native.js`; the styletest real-map smoke
self-skips if that build is absent.

### actionlint clean

`.github/workflows/ci.yml` is **actionlint-clean** (verified with `actionlint 1.7.7`).

## The canonical `gate` job, step by step

| Step | What | Why |
|---|---|---|
| checkout / setup-node / haskell-actions/setup | runner bootstrap | Node + GHC/stack for the compiler |
| Read the compiler pin | `compiler-pin.env` → `$GITHUB_OUTPUT` | the pin-keyed cache key |
| Cache `~/.stack` + `.stack-work` | shared pin-keyed cache (same key as `bundle`) | pay the GHC build once |
| Cache + Fetch vendored `.so` | `scripts/fetch-vendor.sh` (CI-5) | so `ci-test.sh`'s `check-abi` RNV-2 gate runs |
| Build + install `canopy-native` | `stack install canopy-native` | `ci-test.sh`'s listtest build + the F7 gate need it |
| Fetch sibling `canopy/*` sources | clone the public CanopyLang package repos | so `canopy test tests/` + the canonical app compile |
| Build pinned compiler + F7 gate | `build-compiler-from-pin.sh`, `CANOPY_PIN_REQUIRE_GATE=1` | CI-2: `canopy` on PATH + F7 IIFE acceptance |
| **`scripts/ci-test.sh`** | the single canonical 15-step device-free gate | the CI-7 reconciliation |
| `harness/run-symbolicate.js` | DX M0 online source-map symbolicator | CI-7: added to the gate |

## What `ci-test.sh` gates (the single suite)

`ci-test.sh` is self-documenting at its head; the suite is: `canopy test tests/`, the mock-Fabric
walker/reconciler harness (`run.js`, `run-keyed.js`, `run-lazy.js`, `run-echo.js`, `run-command.js`,
`run-reload.js`), the perf/scalar-fast-path bench (`bench.js`), the RN-coupling freeze
(`check-rn-coupling.sh`), the release-load safety guard (`check-release-bundle-security.sh`), the
AND-9 coalescing spec (`run-coalesce.js`), the RND-6 list-windowing proof (`run-list-perf.js`), the
RNV-8 cross-platform pin guard (`check-vendor-pins.sh`), the RNV-2 Hermes/JSI ABI gate
(`check-abi.sh`), and the RND-9 competitive perf bar (`perf-bar.js`). All device-free.

## Honest scope — what runs where

- **Verified on the Linux dev box / Linux runners:** the whole `ci-test.sh` suite (all steps green),
  `run-symbolicate.js`, the F7 IIFE acceptance gate on the canonical counter bundle, and `actionlint`
  over the workflow.
- **Runs only on a CI runner (not reproducible offline on this box):** the `haskell-actions/setup` +
  `build-compiler-from-pin.sh` *clone* of the public compiler repo at the pinned SHA (the dev box
  already has `canopy` installed; the driver is the same script, exercised here against the local
  toolchain). The android/ios build jobs and the emulator/simulator runs are device-/Mac-gated.

### Android emulator jobs — REQUIRED (VS-1, first green KVM run pinned)

`android-instrumented` (native UIAutomator) and `android-appium-e2e` (WebdriverIO/Appium smoke) both
run the from-source bundle on an x86_64 google_apis AVD via `reactivecircus/android-emulator-runner`.
They were `continue-on-error` stubs until the AVD could actually boot HW-accelerated: hosted
`ubuntu-latest` exposes `/dev/kvm` but the runner user is not in the `kvm` group, so the emulator fell
back to software emulation and timed out. The **Enable KVM** udev step (in both jobs) fixed that.
**First green KVM run: 27677824058** (both jobs green — instrumented UIAutomator + Appium counter
smoke). Both are now `continue-on-error: false` (**required**). If AVD-boot flakiness reappears, the
follow-up is a retry/quarantine policy (do not silently re-stub them).

## The iOS gate (CI-6)

The iOS half of the workflow has its own authoritative page: **[`docs/ci-ios.md`](./ci-ios.md)**. In
short: `ios-build` runs on a macOS runner (hosted by default; a `workflow_dispatch` `ios_runner` input
re-targets a self-hosted Mac), guards the **RN 0.76.9** pod pin, and builds + tests via the
**`CanopyHost` scheme** so both `CanopyHostCoreTests` (XCTest) **and** `CanopyHostUITests` (the
XCUITest boot smoke) run. A second, opt-in `ios-remote-mac` job drives a Mac you own **over SSH**
(`scripts/remote.sh ios`) as a fallback when you can't register a runner. The iOS job stays
`continue-on-error: true` (advisory) until the first green run is pinned on a real Mac — `docs/ci-ios.md`
is the checklist for the flip to **required**. Do not mark it required before a Mac runner exists.
