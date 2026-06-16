// smoke.mjs — the CANONICAL Appium smoke flow for CI (E2E-1). Fast, deterministic, device-only.
//
// It drives the SAME app the CI `bundle` job builds from source: examples/counter
// (scripts/compiler-pin.env CANOPY_PIN_CANONICAL_APP). That app is the smallest end-to-end Canopy
// program — Count / "Tap me" (testID increment) / "Reset" (testID reset) — so a green run here is a
// full-stack proof on a real emulator:
//
//   • the host BOOTED the from-source bundle and mounted native views (not a WebView) — we read
//     "Count: 0" off the live view tree, which only exists if JSI + Yoga + the production walker ran;
//   • the testID -> accessibility-id contract is wired — we select the button by ~increment
//     (Android content-description; on iOS the same id is the accessibilityIdentifier);
//   • a REAL tap dispatches a TEA update + a targeted native updateProps — after N taps the label
//     re-renders to "Count: N" (an incremental prop update, NOT a re-mount);
//   • a second handler works — ~reset dispatches Reset and the label returns to "Count: 0".
//
// Unlike run-e2e.mjs / lumen-restore.mjs (which assert Lumen copy + open the flaky OS photo picker),
// this spec has NO external dependency: no picker, no ONNX, no gallery fixture, no network. That is
// what makes it the smoke gate a CI emulator can run reliably on every push (E2E-1).
//
// Selectors are by accessibility id + text only (never coordinates), so the SAME body runs on iOS
// (E2E-2) by flipping E2E_PLATFORM=iOS E2E_AUTOMATION=XCUITest.
//
// Run:  npm run appium    (one shell — starts the server on 127.0.0.1:4723)
//       npm run smoke     (another — against the booted org.canopy.echo running the counter bundle)
//
// Env (all optional): E2E_PLATFORM (Android|iOS), E2E_AUTOMATION (UiAutomator2|XCUITest),
//   E2E_DEVICE (AVD/sim name), E2E_HOST/E2E_PORT (Appium server), E2E_TAPS (default 3).

import { remote } from 'webdriverio'

const HOST = process.env.E2E_HOST || '127.0.0.1'
const PORT = parseInt(process.env.E2E_PORT || '4723', 10)
const TAPS = Math.max(1, parseInt(process.env.E2E_TAPS || '3', 10))

const CAPS = {
  platformName: process.env.E2E_PLATFORM || 'Android',
  'appium:automationName': process.env.E2E_AUTOMATION || 'UiAutomator2',
  'appium:appPackage': 'org.canopy.echo',
  'appium:appActivity': 'com.canopyhost.MainActivity',
  // A clean foreground launch each run so we always start at Count: 0 with fresh TEA state.
  'appium:forceAppLaunch': true,
  'appium:noReset': process.env.E2E_NORESET === '1',
  'appium:newCommandTimeout': 120,
  ...(process.env.E2E_DEVICE ? { 'appium:deviceName': process.env.E2E_DEVICE } : {}),
}

// ---- tiny harness (matches run-e2e.mjs / lumen-restore.mjs) ----------------------------------
let passed = 0, failed = 0
const fails = []
function check(name, cond, detail) {
  if (cond) { passed++; console.log('  \x1b[32m✓\x1b[0m ' + name) }
  else { failed++; fails.push(name); console.log('  \x1b[31m✗\x1b[0m ' + name + (detail ? ' — ' + detail : '')) }
}

// Every visible text on the live native view tree, de-duped (UIAutomator2 + XCUITest source both
// expose text="..."). Selection is by testID; this is only to assert the deterministic Elm copy.
async function texts(driver) {
  try {
    const src = await driver.getPageSource()
    return [...new Set([...src.matchAll(/text="([^"]+)"/g)].map((m) => m[1]).filter(Boolean))]
  } catch { return [] }
}
const hasText = async (driver, re) => (await texts(driver)).some((t) => re.test(t))

async function waitForText(driver, re, { timeout = 20000, interval = 350 } = {}) {
  const start = Date.now()
  while (Date.now() - start < timeout) {
    if (await hasText(driver, re)) return true
    await driver.pause(interval)
  }
  return false
}

// ---------------------------------------------------------------------------------------------
console.log('\n\x1b[1mCanopy Native SMOKE — ' + CAPS.platformName + ' / ' + CAPS['appium:automationName'] +
  '  (app org.canopy.echo, ' + TAPS + ' taps)\x1b[0m')

const driver = await remote({ hostname: HOST, port: PORT, path: '/', capabilities: CAPS, logLevel: 'error' })
try {
  // 1. the from-source bundle booted and mounted NATIVE views — "Count: 0" only exists if the host
  //    actually walked the VDOM into Fabric (a WebView would expose no such native text node).
  check('app launches and the host mounted native views ("Count: 0")',
    await waitForText(driver, /^Count: 0$/, { timeout: 30000 }))

  // 2. the testID -> accessibility-id contract: find the button by its accessibility id, not text.
  const increment = await driver.$('~increment')
  await increment.waitForExist({ timeout: 15000 })
  check('the increment button is found by testID (~increment / accessibility id)', await increment.isExisting())
  check('that button is displayed + enabled', (await increment.isDisplayed()) && (await increment.isEnabled()))

  // 3. a REAL tap dispatches a TEA update; after N taps the label re-renders to "Count: N" via a
  //    targeted native updateProps (the whole point of the architecture — not a re-mount).
  for (let i = 0; i < TAPS; i++) { await increment.click() }
  await driver.pause(500)
  const want = new RegExp('^Count: ' + TAPS + '$')
  check('tapping ~increment ' + TAPS + '× dispatches updates → "Count: ' + TAPS + '"',
    await waitForText(driver, want, { timeout: 8000 }),
    'on-screen: ' + (await texts(driver)).filter((t) => /Count/.test(t)).join(' | '))

  // 4. a second handler (~reset) dispatches Reset and the label returns to "Count: 0".
  const reset = await driver.$('~reset')
  await reset.waitForExist({ timeout: 10000 })
  check('the reset button is found by testID (~reset)', await reset.isExisting())
  await reset.click()
  check('tapping ~reset dispatches Reset → back to "Count: 0"',
    await waitForText(driver, /^Count: 0$/, { timeout: 8000 }))
} catch (e) {
  check('smoke session ran without an unexpected error', false, String((e && e.stack) || e))
} finally {
  try { await driver.deleteSession() } catch { /* ignore */ }
}

console.log('\n\x1b[1mResult: ' + (failed === 0 ? '\x1b[32mPASS' : '\x1b[31mFAIL') + '\x1b[0m  (' + passed + ' passed, ' + failed + ' failed)')
if (failed) console.log('failed:\n  - ' + fails.join('\n  - '))
process.exit(failed === 0 ? 0 : 1)
