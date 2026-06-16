# iOS Appium e2e — the XCUITest leg of the device matrix (E2E-2)

This page is the authoritative description of the **iOS** half of the black-box Appium e2e suite: the
`ios-appium-e2e` job in `.github/workflows/ci.yml`, the `e2e/run-appium-ios.sh` driver, the
cross-platform `e2e/run-matrix.sh` sweep, and the combined matrix report. It records the **E2E-2**
work: drive the iOS leg in the matrix (simulator + the XCUITest driver), port `run-e2e.mjs` to
platform-neutral accessibility-id selectors, and aggregate Android + iOS into **one** report.

E2E-2 builds on **E2E-1** (the Android Appium smoke flow, `docs/ci.md` → `android-appium-e2e`). The
thesis it proves: **one** spec body runs **unchanged** on both platforms — selecting only on the
`testID`→accessibility-id contract — so the cross-platform claim holds at the e2e layer, not just in
the renderer.

> **Honest status (2026-06):** the iOS host has **never compiled** — there is no Mac (hosted or
> self-hosted) wired to this repo. The `ios-appium-e2e` job is **authored + actionlint/shellcheck-clean**
> and the spec it runs (`smoke.mjs` / `run-e2e.mjs`) is **locally proven green on Android** (the only
> difference on iOS is `caps.mjs` flipping the platform). It is **`continue-on-error: true`** (advisory,
> never red) until the first green simulator run is pinned on a real Mac. Do **not** mark it required
> before then. This page is the checklist for the flip.

---

## The one capability fork (caps.mjs) — same spec, both platforms

The whole suite rests on the `testID`→accessibility-id contract the host wires: `A.testID "choose"`
becomes the Android view's **content-description** AND the iOS view's **accessibilityIdentifier**, so
`driver.$('~choose')` resolves on UIAutomator2 and XCUITest alike. The only thing that differs per
platform is the Appium *capabilities*, and they live in **one** place:

| | Android | iOS |
|---|---|---|
| `platformName` | `Android` | `iOS` |
| `appium:automationName` | `UiAutomator2` | `XCUITest` |
| app identity | `appPackage` / `appActivity` (`org.canopy.echo`) | `bundleId` (`com.canopyhost.app`) |
| permissions | `autoGrantPermissions` | `autoAcceptAlerts` |
| device | `deviceName` (AVD) | `udid` / `deviceName` (sim) + optional `app` (.app to install) |

`e2e/caps.mjs` builds the right object from env (`E2E_PLATFORM`, `E2E_DEVICE`, `E2E_UDID`, `E2E_APP`,
…). Every spec — `run-e2e.mjs`, `smoke.mjs`, `lumen-restore.mjs` — selects the platform through it, so
the **test body** is identical and a new platform is added in `caps.mjs`, never in each spec.

### What the `run-e2e.mjs` port changed (E2E-2 deliverable #2)

`run-e2e.mjs` used to assert on-screen copy with Android-only selectors
(`android=new UiSelector().text(...)`), which **throw** on the XCUITest driver. It now:

- reads the live view tree's text off `getPageSource()` (`text="…"` is exposed identically by
  UIAutomator2 and XCUITest source) — a platform-neutral copy assertion;
- selects every interactive view by `~testID` only;
- detects the photo picker platform-neutrally (Android: the foreground package flips to the
  photo-picker provider; iOS: the system PHPicker chrome — `Photos`/`Recents`/`Cancel` — appears).

So the exact same file runs on Android (proven green locally) and on an iOS simulator.

---

## How to run it on a Mac

### 1. Build CanopyHost.app for the simulator

```bash
cd host/ios
xcodegen generate && pod install
WS=$(ls -d ./*.xcworkspace | head -1)
xcodebuild -workspace "$WS" -scheme CanopyHost -configuration Debug \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15' \
  -derivedDataPath build build
# the .app lands at: host/ios/build/Build/Products/Debug-iphonesimulator/CanopyHost.app
```

### 2. Run the smoke spec on a booted simulator (the CI driver, run locally)

```bash
cd e2e
npm ci
npx appium driver install xcuitest        # one-time
APP=../host/ios/build/Build/Products/Debug-iphonesimulator/CanopyHost.app \
SIM_NAME='iPhone 15' SPEC=smoke.mjs \
  bash run-appium-ios.sh
```

`run-appium-ios.sh` boots the named simulator (capturing its UDID), installs the `.app`, starts
Appium with the xcuitest driver (log → `$APPIUM_LOG`), runs the spec with the iOS capabilities, and
tears Appium + the sim down. It is the **iOS twin of `run-appium-ci.sh`** — the same script the CI job
and a Mac dev box run identically.

### 3. The cross-platform matrix sweep (E2E-2 deliverable #1 + #3)

```bash
# Android + iOS in one sweep. Each entry is "<platform>:<device>"; a bare name = android (legacy).
IOS_APP=host/ios/build/Build/Products/Debug-iphonesimulator/CanopyHost.app \
DEVICES="android:canopy_echo ios:iPhone 15" SPEC=smoke.mjs \
  e2e/run-matrix.sh
```

`run-matrix.sh` boots each device (AVD via the emulator, iOS sim via `xcrun simctl`), runs the spec
with the right driver, appends one JSON line per entry to `matrix-out/results.jsonl`, and writes the
combined **matrix report** to `matrix-out/matrix-report.md` (built by `matrix-report.mjs`). The exit
code is the number of failed entries.

> Android and iOS can run on **separate machines** (the AVD leg on Linux, the sim leg on a Mac):
> concatenate the two `results.jsonl` ledgers and re-run `node matrix-report.mjs <merged.jsonl>
> <out.md>` to merge them into one report.

---

## What the `ios-appium-e2e` CI job does

| Step | What | Why |
|---|---|---|
| checkout / setup-node | runner bootstrap | Node for Appium + the RN install |
| Cache iOS pods | keyed on Podfile + project.yml | `pod install` skips network on a hit (shared with `ios-build`) |
| Install XcodeGen / RN pods | `xcodegen`, `npm i react-native@0.76.9` | the pinned Hermes + Yoga the app links |
| Download + stage `app-bundle` | the from-source bundle artifact | `canopy.bundle.js` is git-ignored — no committed copy |
| **Build CanopyHost.app** | `xcodebuild … build` into `build/` | the `.app` the Appium run installs |
| Install Appium harness | `npm ci` + the xcuitest driver | the WebdriverIO/Appium client + driver |
| **Run smoke (XCUITest)** | `bash run-appium-ios.sh` (`SPEC=smoke.mjs`) | the SAME spec the Android leg runs |
| Upload `ios-appium-e2e-logs` | appium log + screenshots, `always()` | a red iOS run is diagnosable without a Mac |

It runs on the GitHub-hosted `macos-14` runner by default and can be re-targeted to a self-hosted Mac
exactly like `ios-build` (the shared `ios_runner` dispatch input). It is **distinct** from
`ios-build`'s native-Swift `CanopyHostUITests` (a UI-test bundle compiled *into* the app): this job is
the **WebdriverIO/Appium** layer — the exact same harness, server, and spec the Android job uses.

---

## Flipping iOS e2e to REQUIRED (the E2E-2 finish line)

Do this **only after** the first green simulator run on a Mac runner.

1. Wire a Mac (register a self-hosted macOS runner, or accept the hosted `macos-14` cost).
2. Get a **green** `ios-appium-e2e` run: the `.app` builds, the simulator boots, `appium` (xcuitest)
   starts, and `smoke.mjs` passes (the counter spine: launch → mount native views (`Count: 0`) →
   `~increment` → `Count: N` → `~reset` → `Count: 0`). Pin the toolchain that produced it (Xcode
   version, the `macos-14` image, the appium + xcuitest driver versions).
3. In `.github/workflows/ci.yml`, set the `ios-appium-e2e` job's `continue-on-error: false`.
4. In the branch-protection rule for `main`, add **`iOS Appium smoke (simulator, XCUITest) — E2E-2`**
   to the required status checks.

Until step 2 lands, the job stays advisory so a missing Mac can never turn the tree red — the same
discipline as `ios-build` (CI-6).

---

## Honest scope — what is verified vs. not

- **Verified on the Linux dev box:**
  - the ported `run-e2e.mjs` runs **green on the live Android emulator** (5/5 checks: launch → `Lumen`
    heading → tagline → `~choose` by accessibility id → the OS photo picker opens) — i.e. the
    platform-neutral selector port did **not** regress the Android path;
  - `caps.mjs` builds correct Android **and** iOS capability objects (XCUITest, `bundleId`, `udid`,
    `app`, `autoAcceptAlerts`) from env;
  - `matrix-report.mjs` aggregates a mixed Android+iOS ledger into one Markdown report with the right
    PASS/FAIL verdict and exit code (tested on a synthetic ledger);
  - `run-matrix.sh`'s `DEVICES` segmentation handles bare legacy names, prefixed entries, and
    multi-word iOS simulator names (`ios:iPhone 15`) correctly, and is **shellcheck-clean**;
  - `run-appium-ios.sh` is **shellcheck-clean**; the workflow is **actionlint-clean** (`actionlint 1.7.7`).
- **NOT verified here (Mac-gated):** the actual `xcodebuild` build of `CanopyHost.app`, the iOS
  simulator boot, `appium driver install xcuitest`, and the XCUITest run of `smoke.mjs`/`run-e2e.mjs`
  on a simulator — there is no Mac on this box. The iOS capability shape and the spec body are proven
  correct against Appium's documented XCUITest contract and a green Android run respectively, but their
  on-simulator execution is pending the first Mac run (the flip checklist above).
