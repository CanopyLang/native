// caps.mjs — build the platform-correct Appium capabilities for a Canopy Native E2E run, from env.
//
// E2E-2: this is the ONE place the Android (UIAutomator2) vs iOS (XCUITest) capability fork lives,
// so every spec (run-e2e.mjs, smoke.mjs, lumen-restore.mjs) selects the platform identically and a
// new platform is added here, not in each spec. The TEST BODY stays platform-neutral — it selects
// only on the `testID` -> accessibility-id contract (`~choose`) and reads on-screen copy off the
// page source — so the SAME body runs on both platforms; only these capabilities differ.
//
// The contract the host wires (CanopyHost): `A.testID "choose"` becomes the Android view's
// content-description AND the iOS view's accessibilityIdentifier, so `driver.$('~choose')` resolves
// on UIAutomator2 and XCUITest alike. That is what makes one spec cover the device matrix.
//
// Env (all optional):
//   E2E_PLATFORM    Android | iOS                         (default: Android)
//   E2E_AUTOMATION  UiAutomator2 | XCUITest               (default: per platform)
//   E2E_DEVICE      AVD name / iOS simulator name         (e.g. "iPhone 15")
//   E2E_UDID        iOS simulator UDID (preferred over name on a Mac with a booted sim)
//   E2E_APP         iOS: absolute path to the built CanopyHost.app to install (optional —
//                   omit to drive an already-installed app by bundle id)
//   E2E_NORESET     "1" => appium:noReset true (keep app state between runs)
//   E2E_FORCE_LAUNCH "0" => do NOT forceAppLaunch (default: force a clean foreground launch)
//
// Android identifiers (the installed Canopy host) and the iOS bundle id are the SAME app across
// platforms — org.canopy.echo (Android applicationId) / com.canopyhost.app (iOS PRODUCT_BUNDLE_ID).

const ANDROID_PKG = process.env.E2E_APP_PACKAGE || 'org.canopy.echo'
const ANDROID_ACT = process.env.E2E_APP_ACTIVITY || 'com.canopyhost.MainActivity'
const IOS_BUNDLE_ID = process.env.E2E_BUNDLE_ID || 'com.canopyhost.app'

export function platform() {
  return /^ios$/i.test(process.env.E2E_PLATFORM || '') ? 'iOS' : 'Android'
}

export function isIOS() {
  return platform() === 'iOS'
}

// Build the WebdriverIO `capabilities` object for the active platform.
export function buildCaps() {
  const force = process.env.E2E_FORCE_LAUNCH !== '0'
  const noReset = process.env.E2E_NORESET === '1'
  const newCommandTimeout = parseInt(process.env.E2E_CMD_TIMEOUT || '200', 10)

  if (isIOS()) {
    // XCUITest on an iOS simulator/device. Selection is still by `~testID` (accessibilityIdentifier)
    // + page-source text, so the spec body is unchanged from Android.
    const caps = {
      platformName: 'iOS',
      'appium:automationName': process.env.E2E_AUTOMATION || 'XCUITest',
      'appium:bundleId': IOS_BUNDLE_ID,
      'appium:noReset': noReset,
      'appium:newCommandTimeout': newCommandTimeout,
      // A clean foreground launch each run = fresh TEA state (parity with Android forceAppLaunch).
      'appium:forceAppLaunch': force,
      // auto-accept the Photos/Notifications permission alerts so a capability/Lumen spine never stalls.
      'appium:autoAcceptAlerts': true,
    }
    if (process.env.E2E_UDID) caps['appium:udid'] = process.env.E2E_UDID
    if (process.env.E2E_DEVICE) caps['appium:deviceName'] = process.env.E2E_DEVICE
    if (process.env.E2E_PLATFORM_VERSION) caps['appium:platformVersion'] = process.env.E2E_PLATFORM_VERSION
    // If a freshly-built .app path is given, install + launch it (otherwise drive the installed one).
    if (process.env.E2E_APP) caps['appium:app'] = process.env.E2E_APP
    return caps
  }

  // Android — UIAutomator2 against the installed host (org.canopy.echo).
  const caps = {
    platformName: 'Android',
    'appium:automationName': process.env.E2E_AUTOMATION || 'UiAutomator2',
    'appium:appPackage': ANDROID_PKG,
    'appium:appActivity': ANDROID_ACT,
    'appium:noReset': noReset,
    'appium:newCommandTimeout': newCommandTimeout,
    'appium:forceAppLaunch': force,
    'appium:autoGrantPermissions': true,
  }
  if (process.env.E2E_DEVICE) caps['appium:deviceName'] = process.env.E2E_DEVICE
  return caps
}

// A short, human label for the platform + automation engine (for the run banner + matrix report).
export function capsLabel(caps) {
  return caps.platformName + ' / ' + caps['appium:automationName']
}
