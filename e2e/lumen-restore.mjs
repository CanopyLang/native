// lumen-restore.mjs — the LUMEN end-to-end restore flow, driven by Appium (UIAutomator2 on
// Android, XCUITest on iOS) via WebdriverIO. This drives the ACTUAL probe surface in
// examples/lumen-probe/src/Main.can: a status Text node (testID "status", rendering
// "Status: <state>") plus six buttons (testIDs restore/pick/save/share/store/notify).
//
// It selects ONLY on the testID -> accessibility-id contract the host wires
// (CanopyHost.java: testID -> Android content-description / iOS accessibilityIdentifier), so the
// body is identical across the device matrix. It asserts the deterministic status-line
// transitions the Elm `update` produces:
//
//   init        -> "Status: decoding…"  then "Status: decoded"     (Image.decode at launch)
//   tap restore -> "Status: restoring…" then "Status: restored"    (ESPCN ONNX inference)
//   tap save    -> "Status: saving…"    then "Status: saved → …" (MediaStore)
//   tap share   -> "Status: sharing…"   then "Status: shared"      (share sheet)
//   tap store   -> "Status: storing…"   then "Status: stored+read → active-2026"
//   tap notify  -> "Status: notifying…" then "Status: notified"
//
// Save/Share/Store/Notify all act on the decoded original (Main.can sourceInt), so the spine
// never depends on the emulator photo-picker having content. Pick is attempted best-effort
// and is non-fatal.
//
// Run:  npm run appium    (one shell — starts the server on 127.0.0.1:4723)
//       node lumen-restore.mjs   (another shell — runs this against the booted org.canopy.echo)
// Matrix: ./run-matrix.sh   (SPEC defaults to this file)

import { remote } from 'webdriverio'

const CAPS = {
  platformName: process.env.E2E_PLATFORM || 'Android',
  'appium:automationName': process.env.E2E_AUTOMATION || 'UiAutomator2',
  'appium:appPackage': 'org.canopy.echo',
  'appium:appActivity': 'com.canopyhost.MainActivity',
  // we want a clean launch each run so decode-at-init fires and the status line is fresh.
  'appium:noReset': process.env.E2E_NORESET === '1',
  'appium:newCommandTimeout': 180,
  // auto-accept the POST_NOTIFICATIONS runtime dialog (API 33+) so Notify doesn't stall.
  'appium:autoGrantPermissions': true,
  ...(process.env.E2E_DEVICE ? { 'appium:deviceName': process.env.E2E_DEVICE } : {}),
}

// ---- tiny harness (matches run-e2e.mjs) -----------------------------------------------------
let passed = 0, failed = 0
const fails = []
function check(name, cond, detail) {
  if (cond) { passed++; console.log('  \x1b[32m✓\x1b[0m ' + name) }
  else { failed++; fails.push(name); console.log('  \x1b[31m✗\x1b[0m ' + name + (detail ? ' — ' + detail : '')) }
}

// The status node carries the visible "Status: ..." text AND content-description "status".
// getText() returns the visible text on both UIAutomator2 and XCUITest.
async function statusText(driver) {
  try {
    const el = await driver.$('~status')
    if (!(await el.isExisting())) return ''
    return (await el.getText()) || ''
  } catch { return '' }
}

// Poll the status line until `pred(text)` is true (or timeout). Returns the last text seen.
async function waitForStatus(driver, pred, { timeout = 30000, interval = 400, label = '' } = {}) {
  const start = Date.now()
  let last = ''
  while (Date.now() - start < timeout) {
    last = await statusText(driver)
    if (pred(last)) return last
    await driver.pause(interval)
  }
  return last
}

const tap = async (driver, id) => {
  const el = await driver.$('~' + id)
  await el.waitForExist({ timeout: 15000 })
  await el.click()
  return el
}

// Dismiss whatever OS surface a tap may have raised (share sheet, picker, save toast).
async function dismissOverlay(driver, settle = 1500) {
  await driver.pause(settle)
  try { await driver.back() } catch { /* nothing to dismiss */ }
  await driver.pause(500)
}

console.log('\n\x1b[1mLUMEN restore E2E — ' + CAPS.platformName + ' / ' + CAPS['appium:automationName'] + '\x1b[0m')
const driver = await remote({ hostname: '127.0.0.1', port: 4723, path: '/', capabilities: CAPS, logLevel: 'error' })
try {
  // 0. the app rendered native views and the status line exists (testID -> content-desc).
  const status = await driver.$('~status')
  await status.waitForExist({ timeout: 20000 })
  check('status line is found by testID (~status / accessibility id)', await status.isExisting())
  check('status line is displayed', await status.isDisplayed())

  // 1. decode-at-init: Image.decode "asset:lumen-test.jpg" runs from init; status settles to
  //    "Status: decoded" (was "Status: decoding…"). Generous wait: ONNX/asset init at launch.
  const decoded = await waitForStatus(driver, (t) => /^Status:\s*decoded\b/.test(t), { timeout: 30000, label: 'decode' })
  check('decode-at-init reaches "Status: decoded"', /^Status:\s*decoded\b/.test(decoded), 'last="' + decoded + '"')

  // 2. RESTORE -> ESPCN ONNX inference. "restoring…" then "restored".
  await tap(driver, 'restore')
  const restored = await waitForStatus(driver, (t) => /^Status:\s*restored\b/.test(t), { timeout: 60000, label: 'restore' })
  check('tapping ~restore reaches "Status: restored"', /^Status:\s*restored\b/.test(restored), 'last="' + restored + '"')

  // 3. SAVE -> MediaStore. "saving…" then "saved → <path>". A save may surface a system
  //    confirmation on some OEM/API levels; settle then re-read.
  await tap(driver, 'save')
  let saved = await waitForStatus(driver, (t) => /^Status:\s*saved\s*→/.test(t) || /^Status:\s*err:/.test(t), { timeout: 25000, label: 'save' })
  if (!/^Status:\s*saved\s*→/.test(saved)) { await dismissOverlay(driver); saved = await statusText(driver) }
  check('tapping ~save reaches "Status: saved → …"', /^Status:\s*saved\s*→/.test(saved), 'last="' + saved + '"')

  // 4. SHARE -> system share sheet opens (a separate activity). "sharing…" then "shared".
  //    The share sheet steals focus; dismiss it with back, then read the status line back in-app.
  await tap(driver, 'share')
  await dismissOverlay(driver, 2000) // close the share chooser so we can read our own UI
  const shared = await waitForStatus(driver, (t) => /^Status:\s*shared\b/.test(t) || /^Status:\s*err:\s*cancelled/.test(t), { timeout: 20000, label: 'share' })
  check('tapping ~share reaches "Status: shared" (or a clean cancel)',
    /^Status:\s*shared\b/.test(shared) || /cancelled/.test(shared), 'last="' + shared + '"')

  // 5. STORE -> EncryptedSharedPreferences set+get round-trip. "storing…" then
  //    "stored+read → active-2026" (the value written in update DoStore).
  await tap(driver, 'store')
  const stored = await waitForStatus(driver, (t) => /^Status:\s*stored\+read\s*→\s*active-2026\b/.test(t), { timeout: 20000, label: 'store' })
  check('tapping ~store round-trips to "Status: stored+read → active-2026"',
    /stored\+read\s*→\s*active-2026/.test(stored), 'last="' + stored + '"')

  // 6. NOTIFY -> posts a notification. "notifying…" then "notified". autoGrantPermissions
  //    handles POST_NOTIFICATIONS on API 33+.
  await tap(driver, 'notify')
  const notified = await waitForStatus(driver, (t) => /^Status:\s*notified\b/.test(t), { timeout: 20000, label: 'notify' })
  check('tapping ~notify reaches "Status: notified"', /^Status:\s*notified\b/.test(notified), 'last="' + notified + '"')

  // 7. PICK (best-effort, non-fatal): opens the Android Photo Picker. Emulators often have no
  //    photos, so we only assert the picker opened, not that a photo came back.
  try {
    await tap(driver, 'pick')
    await driver.pause(2500)
    const src = await driver.getPageSource()
    const pickerUp = /photopicker|com\.google\.android\.providers\.media|DocumentsUI|Photos/i.test(src)
    check('[optional] tapping ~pick opens the OS photo picker', pickerUp)
    await dismissOverlay(driver) // back out to the app
  } catch (e) {
    check('[optional] pick step ran without throwing', false, String((e && e.message) || e))
  }
} catch (e) {
  check('E2E session ran without an unexpected error', false, String((e && e.message) || e))
} finally {
  try { await driver.deleteSession() } catch { /* ignore */ }
}

console.log('\n\x1b[1mResult: ' + (failed === 0 ? '\x1b[32mPASS' : '\x1b[31mFAIL') + '\x1b[0m  (' + passed + ' passed, ' + failed + ' failed)')
if (failed) console.log('failed:\n  - ' + fails.join('\n  - '))
process.exit(failed === 0 ? 0 : 1)
