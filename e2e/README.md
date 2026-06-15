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
| Full E2E | Appium (UIAutomator2 / XCUITest) + WebdriverIO (`run-e2e.mjs`) | flows, assertions, the device matrix |
| Smoke | Maestro (`flows/smoke.yaml`) | fast launch + tap sanity in CI |

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
