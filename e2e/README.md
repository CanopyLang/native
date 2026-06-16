# Canopy Native — E2E device testing ("test like Playwright")

Black-box UI testing for Canopy Native apps across the **device matrix** (Android API levels,
iOS simulators/devices), driven by **Appium 2** + **WebdriverIO**, plus a **Maestro** smoke flow.

The whole thing rests on the **`testID` → accessibility-id** contract the host wires:
`Native.Attributes.testID "choose"` becomes the Android view's `content-description` and (on iOS)
the `accessibilityIdentifier`. So one test selects `~choose` and runs **unchanged** on every
platform — no coordinates, no platform forks. This is the same idea as Playwright's `getByTestId`.

**One spec, both platforms (E2E-1 + E2E-2).** The ONLY thing that differs per platform is the Appium
*capabilities*, and they live in one place — **`caps.mjs`** (Android → UIAutomator2 + `appPackage`;
iOS → XCUITest + `bundleId`). Every spec (`run-e2e.mjs`, `smoke.mjs`, `lumen-restore.mjs`) builds its
capabilities through it and selects only on `~testID` + on-screen text, so the **test body is
identical** on Android (proven green) and on an iOS simulator. iOS is Mac-gated — see
[`docs/ci-e2e-ios.md`](../docs/ci-e2e-ios.md).

## Layers

| Layer | Tool | What it's for |
|---|---|---|
| **CI smoke** | Appium + WebdriverIO (`smoke.mjs`) | **the CI gate (E2E-1)** — drives the canonical `examples/counter` bundle (the app CI builds from source): launch → mount native views → tap `~increment` → `Count: N` → `~reset` → `Count: 0`. No OS picker / ONNX, so it runs reliably on a CI emulator. |
| **Lumen restore E2E** | Appium + WebdriverIO (`lumen-restore.mjs`) | the real Lumen app's pick→restore→compare→share→save→loop spine, on-device |
| Generic launch E2E | Appium + WebdriverIO (`run-e2e.mjs`) | a launch + photo-picker sanity flow (asserts Lumen copy) |
| Smoke | Maestro (`flows/counter-smoke.yaml`, `flows/smoke.yaml`, `flows/lumen-restore.yaml`) | fast launch + tap sanity. `counter-smoke.yaml` is the Maestro twin of `smoke.mjs` (matches the CI bundle). |

### The CI smoke flow (`smoke.mjs`) — E2E-1

`smoke.mjs` is the spec the **CI emulator job** runs (`.github/workflows/ci.yml` → `android-appium-e2e`).
It drives the SAME app the `bundle` job builds from source — `examples/counter` — purely through the
`testID` → accessibility-id contract, so a green run proves the whole device stack (host boot + JSI +
Yoga + the production walker + a real tap dispatching a TEA update) on an emulator, with no flaky
external dependency. The CI job: downloads the from-source bundle → `assembleDebug` → boots an AVD on
the KVM `android-emulator-runner` → installs the APK → `appium` (uiautomator2) → `smoke.mjs`, and
uploads the Appium server log. The body is platform-neutral (selectors are accessibility-id + text),
so it runs unchanged on iOS (E2E-2) via `E2E_PLATFORM=iOS E2E_AUTOMATION=XCUITest`.

```
npm run appium      # terminal 1 — start the server
npm run smoke       # terminal 2 — run smoke.mjs against the booted counter bundle
```

The CI driver `run-appium-ci.sh` is the same sequence factored into a script (install APK → start
appium with log capture → run the spec → tear appium down); the CI job and the dev box run it identically.

### The Lumen restore flow (`lumen-restore.mjs`)

Drives the **real Lumen app** (`apps/lumen/app/src/Main.can`) — the production TEA program, not
the capability probe — through its whole spine, selecting only on the `testID` contract:

```
Pick (~choose) → OS photo picker → Detected (~justfix) → Processing (real ESPCN ONNX) →
  Compare (~save / ~share, "Enhanced to N×N" = the inference proof, ✦ watermark gate) →
  Share sheet → Save → Done (~another) → back to Pick
```

It runs **on-device against real native effects**: the Android system Photo Picker, the real
on-device ESPCN super-resolution pass, the system share sheet (`intentresolver`), and a real
MediaStore save. The `Enhanced to N×N` badge on Compare is the actual ESPCN output size, so a
green run proves the real inference ran. Screenshots of every screen land in `e2e/screenshots/`.

**Gallery fixture (self-contained).** The spec seeds one small (≤512px) draw-safe test photo as
the most-recent gallery image and clears large prior restore outputs before each run, so the
picker is deterministic AND the restored bitmap stays under Android's ~100MB `Canvas` draw limit.
A multi-megapixel source produces a restore the on-screen `BeforeAfterView` compositor cannot draw
(`Canvas: trying to draw too large bitmap`) — a host-side follow-up to cap/downsample the
compositor's draw bitmap (see `BeforeAfterView.drawCover`). Override `adb` with `ADB=/path/to/adb`.

Run it against the booted Lumen bundle (Android):

```
scripts/dev.sh apps/lumen/app   # build + push the Lumen bundle to the host (one-time per change)
npm run appium                  # terminal 1
ADB=$ANDROID_HOME/platform-tools/adb node lumen-restore.mjs   # terminal 2
```

**On an iPhone (L-I6) — the SAME spec, XCUITest driver.** `lumen-restore.mjs` is platform-neutral: it
builds its capabilities through `caps.mjs` and branches only the OS picker / share-sheet chrome the
app does not own (Android Photo Picker / `intentresolver` → iOS **PHPicker** / **UIActivityViewController**).
Two preconditions, both the iOS twins of the Android steps: (1) the LUMEN bundle is embedded as the
app's `canopy.bundle.js` (built on Linux; the iOS twin of the dev-override push), and (2) a draw-safe
photo is seeded into the library — **`xcrun simctl addmedia booted
../host/ios/Tests/CanopyHostUITests/Fixtures/lumen-test.jpg`** (the byte-identical fixture; the iOS
twin of the Android gallery seed). Then (needs a Mac):

```
E2E_PLATFORM=iOS E2E_AUTOMATION=XCUITest E2E_BUNDLE_ID=com.canopyhost.app \
  E2E_UDID=$(xcrun simctl list devices booted | sed -nE 's/.*\(([0-9A-Fa-f-]+)\).*Booted.*/\1/p' | head -1) \
  node lumen-restore.mjs
```

There is also a **native XCUITest** twin (no Appium) at
`host/ios/Tests/CanopyHostUITests/CanopyLumenRestoreUITests.swift` — same spine, same testIDs, and it
runs on a **physical iPhone** (the L-I6 deliverable proper). See `host/ios/BUILD-AND-VALIDATE.md §5.8`.
The device-free anti-drift net for both is `scripts/check-ios-lumen-e2e.sh` (in the Linux gate): it
fails if the iPhone spec drops a spine step or diverges from this Android spec's testIDs/copy.

## Setup (done)

```
npm install                              # appium 2 + webdriverio
npx appium driver install uiautomator2   # Android driver (pinned 3.9.4 for appium 2.x)
# iOS: npx appium driver install xcuitest   (needs a Mac)
```

## Run

```
npm run appium      # terminal 1 — start the server (127.0.0.1:4723)
npm test            # terminal 2 — run run-e2e.mjs against the booted app
```

The Android emulator must be up with the host app installed (`org.canopy.echo`).

## Device matrix (Android + iOS — E2E-2)

The SAME spec covers the whole matrix; `caps.mjs` reads env vars to pick the platform:

```
E2E_DEVICE="Pixel_7_API_34" npm test                          # another AVD (Android)
E2E_PLATFORM=iOS E2E_DEVICE="iPhone 15" npm test              # iOS simulator (needs a Mac)
```

**`run-matrix.sh`** is the cross-PLATFORM sweep. Each `DEVICES` entry is `<platform>:<device>`
(a bare name defaults to `android:`, so the legacy `DEVICES="canopy_echo Pixel_7"` form still means
"two AVDs"). It boots each device (AVD via the emulator, iOS sim via `xcrun simctl`), runs the spec
with the right driver, and **aggregates Android + iOS into one report**:

```
# Android + iOS in one sweep (iOS needs a Mac with Xcode + the .app built — see docs/ci-e2e-ios.md)
IOS_APP=../host/ios/build/Build/Products/Debug-iphonesimulator/CanopyHost.app \
DEVICES="android:canopy_echo ios:iPhone 15" SPEC=smoke.mjs ./run-matrix.sh
```

Output: a per-entry ledger at `matrix-out/results.jsonl` and a combined Markdown **matrix report** at
`matrix-out/matrix-report.md` (built by `matrix-report.mjs`). The exit code is the number of failed
entries. Android and iOS may run on **separate machines** — concatenate the two `results.jsonl`
ledgers and re-run `node matrix-report.mjs <merged.jsonl> <out.md>` to merge them.

### The CI drivers

| Script | Leg | What |
|---|---|---|
| `run-appium-ci.sh` | Android | install APK → start appium (uiautomator2) → run spec → tear down (the `android-appium-e2e` job body, E2E-1) |
| `run-appium-ios.sh` | iOS | boot a simulator → install `.app` → start appium (xcuitest) → run spec → tear down (the `ios-appium-e2e` job body, E2E-2) — **needs a Mac** |

CI runs the Android leg on the KVM emulator runner and the iOS leg on a macOS runner; both are
Mac/emulator-gated and `continue-on-error` until the first green run is pinned (see
[`docs/ci.md`](../docs/ci.md) and [`docs/ci-e2e-ios.md`](../docs/ci-e2e-ios.md)).

## Writing tests

Tag interactive views with `A.testID "<id>"` in your `.can` view code, then select `~<id>`.
Everything else is plain WebdriverIO (`$`, `click`, `setValue`, `getText`, `waitForDisplayed`).
