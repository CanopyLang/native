// run-e2e.mjs — cross-device E2E for a Canopy Native app, driven by Appium (UIAutomator2 on
// Android, XCUITest on iOS) via WebdriverIO. This is the "test like Playwright" layer: it
// selects on the SAME testID->accessibility-id contract the host wires (Android content-desc /
// iOS accessibilityIdentifier), so ONE test runs unchanged across the device matrix.
//
// E2E-2: the body is now PLATFORM-NEUTRAL. It used to assert copy with Android-only
// `android=new UiSelector().text(...)` selectors (which throw on XCUITest); it now reads the live
// view tree's text off the page source (the same scrape smoke.mjs / lumen-restore.mjs use — it
// works identically on UIAutomator2 and XCUITest source), and selects interactive views ONLY by
// `~testID` (accessibilityIdentifier on iOS, content-description on Android). So the exact same file
// runs on Android AND on an iOS simulator — the cross-platform thesis, proven at the e2e layer.
//
// Run:  npm run appium    (in one shell — starts the server)
//       npm test          (in another — runs this against the booted app)
//
// Platform is chosen by env via caps.mjs (the ONE capability fork):
//   Android (default):  npm test
//   iOS simulator:      E2E_PLATFORM=iOS E2E_DEVICE="iPhone 15" npm test     (needs a Mac)
// The test body below is identical on both — selectors are accessibility id + text, not coordinates.

import { remote } from 'webdriverio'
import { buildCaps, capsLabel, isIOS } from './caps.mjs'

const HOST = process.env.E2E_HOST || '127.0.0.1'
const PORT = parseInt(process.env.E2E_PORT || '4723', 10)
const CAPS = buildCaps()

let passed = 0, failed = 0
const fails = []
function check(name, cond, detail) {
  if (cond) { passed++; console.log('  \x1b[32m✓\x1b[0m ' + name) }
  else { failed++; fails.push(name); console.log('  \x1b[31m✗\x1b[0m ' + name + (detail ? ' — ' + detail : '')) }
}

// Every visible text on the live native view tree, de-duped. We read the page source and pull
// text="..." — UIAutomator2 AND XCUITest source both expose it — so this is platform-neutral
// (it replaces the old Android-only UiSelector text matchers). Selection of interactive views is
// still by `~testID`; this is only for asserting the deterministic on-screen copy.
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

// Has the OS photo picker come to the FRONT? Platform-neutral: on Android the foreground package
// flips to the photo-picker provider; on iOS the system PHPicker presents inside our process, so we
// look for its standard "Photos"/"Cancel"/"Recents" chrome on the page source. Either is proof the
// `~choose` tap drove a real native interaction (not just a JS state change).
async function pickerIsUp(driver) {
  if (isIOS()) {
    // PHPicker chrome — any of these strings appearing is the picker presenting.
    return hasText(driver, /^(Photos|Recents|Albums|Cancel|Photo Library)$/)
  }
  try {
    const pkg = await driver.getCurrentPackage()
    if (/providers\.media|photopicker|documentsui/i.test(pkg)) return true
  } catch { /* fall through to a text check */ }
  return hasText(driver, /Photos|Recent|Camera/)
}

console.log('\n\x1b[1mCanopy Native E2E — ' + capsLabel(CAPS) + '\x1b[0m')
const driver = await remote({ hostname: HOST, port: PORT, path: '/', capabilities: CAPS, logLevel: 'error' })
try {
  // 1. the app rendered native views (not a WebView) — "Lumen" only exists as a native text node if
  //    the host walked the VDOM into the platform's view tree (Fabric on iOS / the Android walker).
  check('app launches and the "Lumen" heading is displayed', await waitForText(driver, /^Lumen$/, { timeout: 25000 }))
  check('the tagline text rendered', await hasText(driver, /Bring old photos/))

  // 2. selection on the testID -> accessibility-id contract (the cross-device selector). `~choose`
  //    is the Android content-description AND the iOS accessibilityIdentifier — one selector, both OSes.
  const choose = await driver.$('~choose')
  await choose.waitForExist({ timeout: 15000 })
  check('the primary button is found by testID (~choose / accessibility id)', await choose.isExisting())
  check('that button is displayed and enabled', (await choose.isDisplayed()) && (await choose.isEnabled()))

  // 3. a real tap drives a native interaction (the OS photo picker opens) — platform-neutral assertion.
  await choose.click()
  await driver.pause(2500)
  let up = false
  for (let i = 0; i < 8 && !up; i++) { up = await pickerIsUp(driver); if (!up) await driver.pause(400) }
  check('tapping it opens the native photo picker', up)
  // dismiss the picker so the run leaves the app in a clean state.
  if (isIOS()) {
    try { const cancel = await driver.$('~Cancel'); if (await cancel.isExisting()) await cancel.click() } catch { /* ignore */ }
  } else {
    try { await driver.back() } catch { /* ignore */ }
  }
} catch (e) {
  check('E2E session ran without an unexpected error', false, String((e && e.message) || e))
} finally {
  try { await driver.deleteSession() } catch { /* ignore */ }
}

console.log('\n\x1b[1mResult: ' + (failed === 0 ? '\x1b[32mPASS' : '\x1b[31mFAIL') + '\x1b[0m  (' + passed + ' passed, ' + failed + ' failed)')
if (failed) console.log('failed:\n  - ' + fails.join('\n  - '))
process.exit(failed === 0 ? 0 : 1)
