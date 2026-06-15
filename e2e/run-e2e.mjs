// run-e2e.mjs — cross-device E2E for a Canopy Native app, driven by Appium (UIAutomator2 on
// Android, XCUITest on iOS) via WebdriverIO. This is the "test like Playwright" layer: it
// selects on the SAME testID->accessibility-id contract the host wires (Android content-desc /
// iOS accessibilityIdentifier), so one test runs unchanged across the device matrix.
//
// Run:  npm run appium    (in one shell — starts the server)
//       npm test          (in another — runs this against the booted app)
//
// The Android emulator must be up with the Canopy host app installed (org.canopy.echo). To run
// on a different device/API level or on iOS, change CAPS (platformName/automationName/deviceName)
// — the test body is identical because selectors are by accessibility id + text, not coordinates.

import { remote } from 'webdriverio'

const CAPS = {
  platformName: process.env.E2E_PLATFORM || 'Android',
  'appium:automationName': process.env.E2E_AUTOMATION || 'UiAutomator2',
  'appium:appPackage': 'org.canopy.echo',
  'appium:appActivity': 'com.canopyhost.MainActivity',
  'appium:noReset': true,
  'appium:newCommandTimeout': 120,
  ...(process.env.E2E_DEVICE ? { 'appium:deviceName': process.env.E2E_DEVICE } : {}),
}

let passed = 0, failed = 0
const fails = []
function check(name, cond, detail) {
  if (cond) { passed++; console.log('  \x1b[32m✓\x1b[0m ' + name) }
  else { failed++; fails.push(name); console.log('  \x1b[31m✗\x1b[0m ' + name + (detail ? ' — ' + detail : '')) }
}
const byText = (t) => 'android=new UiSelector().text("' + t + '")'
const byTextContains = (t) => 'android=new UiSelector().textContains("' + t + '")'

console.log('\n\x1b[1mCanopy Native E2E — ' + CAPS.platformName + ' / ' + CAPS['appium:automationName'] + '\x1b[0m')
const driver = await remote({ hostname: '127.0.0.1', port: 4723, path: '/', capabilities: CAPS, logLevel: 'error' })
try {
  // 1. the app rendered native views (not a WebView)
  const lumen = await driver.$(byText('Lumen'))
  check('app launches and the "Lumen" heading is displayed', await lumen.isDisplayed())

  const tagline = await driver.$(byTextContains('Bring old photos'))
  check('the tagline text rendered', await tagline.isExisting())

  // 2. selection on the testID -> accessibility-id contract (the cross-device selector)
  const choose = await driver.$('~choose')
  check('the primary button is found by testID (~choose / accessibility id)', await choose.isExisting())
  check('that button is displayed and enabled', (await choose.isDisplayed()) && (await choose.isEnabled()))

  // 3. a real tap drives a native interaction (the OS photo picker opens)
  await choose.click()
  await driver.pause(2500)
  const picker = await driver.$(byTextContains('Photos'))
  check('tapping it opens the native photo picker', await picker.isExisting())
  await driver.back() // dismiss the picker
} catch (e) {
  check('E2E session ran without an unexpected error', false, String(e && e.message || e))
} finally {
  await driver.deleteSession()
}

console.log('\n\x1b[1mResult: ' + (failed === 0 ? '\x1b[32mPASS' : '\x1b[31mFAIL') + '\x1b[0m  (' + passed + ' passed, ' + failed + ' failed)')
if (failed) console.log('failed:\n  - ' + fails.join('\n  - '))
process.exit(failed === 0 ? 0 : 1)
