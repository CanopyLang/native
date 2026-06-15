# Canopy Native — E2E device testing ("test like Playwright")

Black-box UI testing for Canopy Native apps across the **device matrix** (Android API levels,
iOS simulators/devices), driven by **Appium 2** + **WebdriverIO**, plus a **Maestro** smoke flow.

The whole thing rests on the **`testID` → accessibility-id** contract the host wires:
`Native.Attributes.testID "choose"` becomes the Android view's `content-description` and (on iOS)
the `accessibilityIdentifier`. So one test selects `~choose` and runs **unchanged** on every
platform — no coordinates, no platform forks. This is the same idea as Playwright's `getByTestId`.

## Layers

| Layer | Tool | What it's for |
|---|---|---|
| **Lumen restore E2E** | Appium + WebdriverIO (`lumen-restore.mjs`) | the real Lumen app's pick→restore→compare→share→save→loop spine, on-device |
| Generic launch E2E | Appium + WebdriverIO (`run-e2e.mjs`) | a launch + photo-picker sanity flow |
| Smoke | Maestro (`flows/smoke.yaml`, `flows/lumen-restore.yaml`) | fast launch + tap sanity in CI |

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

Run it against the booted Lumen bundle:

```
scripts/dev.sh apps/lumen/app   # build + push the Lumen bundle to the host (one-time per change)
npm run appium                  # terminal 1
ADB=$ANDROID_HOME/platform-tools/adb node lumen-restore.mjs   # terminal 2
```

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

## Device matrix

`run-e2e.mjs` reads env vars so the SAME test covers the matrix:

```
E2E_DEVICE="Pixel_7_API_34" npm test                                  # another AVD
E2E_PLATFORM=iOS E2E_AUTOMATION=XCUITest E2E_DEVICE="iPhone 15" npm test   # iOS (Mac)
```

`run-matrix.sh` boots each AVD in `DEVICES` and runs the suite against it, aggregating results —
the cross-device sweep. CI runs `appium` + `npm test` per matrix entry.

## Writing tests

Tag interactive views with `A.testID "<id>"` in your `.can` view code, then select `~<id>`.
Everything else is plain WebdriverIO (`$`, `click`, `setValue`, `getText`, `waitForDisplayed`).
