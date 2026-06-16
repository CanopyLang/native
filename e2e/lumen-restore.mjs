// lumen-restore.mjs — the LUMEN restore flow, end-to-end, driven by Appium (UIAutomator2 on
// Android, XCUITest on iOS) via WebdriverIO. This drives the REAL Lumen app
// (apps/lumen/app/src/Main.can) — the production TEA program, not the capability probe.
//
// L-I6 (cross-platform parity): the SAME spec runs on Android AND on an iPhone. Capabilities come
// from the ONE platform fork (caps.mjs); the test body selects ONLY on the testID -> accessibility-id
// contract the host wires (CanopyHost: A.testID -> Android content-description / iOS
// accessibilityIdentifier), so it is identical across the device matrix. The ONLY per-platform edges
// are the OS picker + share-sheet chrome the app does not own (Android Photo Picker / intentresolver
// vs iOS PHPicker / UIActivityViewController) — branched in the pickerIsUp / pickNewestPhoto /
// shareSheetIsUp / dismissShareSheet helpers. The NATIVE XCUITest twin of this spec (no Appium) is
// host/ios/Tests/CanopyHostUITests/CanopyLumenRestoreUITests.swift — same spine, same testIDs.
//
// It walks the product spine the Lumen `update` produces (plan/01: D1 auto-only "Just fix it",
// D3 on-device):
//
//   Pick     —  "Lumen" / "Choose a photo"        (testID choose)
//     → tap choose → the OS photo picker opens; pick the seeded (newest) test photo
//   Detected —  "Ready to restore" / "Just fix it"  (testID justfix)
//     → tap justfix → Processing ("Enhancing details · super-resolution")
//   Processing → the REAL super-resolution pass runs on-device (ESPCN ONNX on Android, Core ML/ANE
//                on iOS) — no mock
//   Compare  —  "Before / After", the native BeforeAfter wipe, "Enhanced to N×N",
//               the free-tier export gate (✦ watermark + the L-A5 budget cap note)  (save / share)
//     → tap save  → Album.save (MediaStore / PHPhotoLibrary) → Done
//   Done     —  "✓  Saved" / "Saved to your Lumen album."                            (another)
//   share    —  from Compare, tap share → the system share sheet opens
//
// The "Enhanced to N×N" badge on Compare is the inference proof: it is the actual restored output
// size, so a green run proves the real on-device super-resolution ran, not a stub.
//
// FIXTURE (self-contained): before the run we seed ONE known-good small test photo as the newest
// gallery image. Android: prepareGalleryFixtureAndroid() seeds it via adb/MediaStore + clears large
// prior outputs. iOS: seed it BEFORE the run with `xcrun simctl addmedia booted
// host/ios/Tests/CanopyHostUITests/Fixtures/lumen-test.jpg` (the byte-identical fixture). The picker
// is newest-first, so the run is deterministic AND the restored bitmap stays under the on-screen
// BeforeAfter compositor's draw limit (a big source → a multi-MP restore the compositor cannot draw).
//
// Run (Android):  npm run appium                                   (one shell — server on :4723)
//                 node lumen-restore.mjs                           (another — booted org.canopy.echo)
// Run (iOS):      E2E_PLATFORM=iOS E2E_AUTOMATION=XCUITest E2E_UDID=<sim> E2E_BUNDLE_ID=com.canopyhost.app \
//                 node lumen-restore.mjs                           (needs a Mac; see e2e/README.md)
// Matrix: ./run-matrix.sh   (SPEC defaults to this file; Android pushes the Lumen bundle + restarts)

import { remote } from 'webdriverio'
import { execFileSync } from 'node:child_process'
import { mkdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { buildCaps, capsLabel, isIOS } from './caps.mjs'

const HERE = dirname(fileURLToPath(import.meta.url))
const ADB = process.env.ADB || 'adb'
const SHOTS = join(HERE, 'screenshots')

// L-I6: capabilities come from the ONE platform fork (caps.mjs), so this exact spec runs on Android
// (UIAutomator2) AND on an iPhone (XCUITest) — the cross-platform thesis at the device-E2E layer.
// Android → appPackage/appActivity (org.canopy.echo); iOS → bundleId (com.canopyhost.app). The TEST
// BODY below is platform-neutral: it selects ONLY by `~testID` (Android content-desc / iOS
// accessibilityIdentifier) and reads on-screen copy off the page source; the only per-platform edges
// are the OS picker + share-sheet chrome (which the app does not own) — branched in the helpers below.
const CAPS = buildCaps()
const IOS = isIOS()

// ---- tiny harness (matches run-e2e.mjs) -----------------------------------------------------
let passed = 0, failed = 0
const fails = []
function check(name, cond, detail) {
  if (cond) { passed++; console.log('  \x1b[32m✓\x1b[0m ' + name) }
  else { failed++; fails.push(name); console.log('  \x1b[31m✗\x1b[0m ' + name + (detail ? ' — ' + detail : '')) }
}

const adb = (...args) => {
  try { return execFileSync(ADB, args, { encoding: 'utf8' }) } catch (e) { return String((e && e.stdout) || (e && e.message) || e) }
}

// Every visible text on screen, de-duped. We read the raw UIAutomator page source and pull
// text="..." (works the same on UIAutomator2 + XCUITest source). Selection is still by testID;
// this is only for asserting the deterministic screen copy the Elm `update` renders.
async function texts(driver) {
  try {
    const src = await driver.getPageSource()
    return [...new Set([...src.matchAll(/text="([^"]+)"/g)].map((m) => m[1]).filter(Boolean))]
  } catch { return [] }
}
async function hasText(driver, re) { return (await texts(driver)).some((t) => re.test(t)) }

// Poll until some on-screen text matches `re` (or timeout). Returns true on match.
async function waitForText(driver, re, { timeout = 30000, interval = 400 } = {}) {
  const start = Date.now()
  while (Date.now() - start < timeout) {
    if (await hasText(driver, re)) return true
    await driver.pause(interval)
  }
  return false
}

const tap = async (driver, id, timeout = 15000) => {
  const el = await driver.$('~' + id)
  await el.waitForExist({ timeout })
  await el.click()
  return el
}

let shotN = 0
async function shot(driver, label) {
  try {
    mkdirSync(SHOTS, { recursive: true })
    const name = String(++shotN).padStart(2, '0') + '-' + label + '.png'
    const png = await driver.takeScreenshot() // base64
    const { writeFileSync } = await import('node:fs')
    writeFileSync(join(SHOTS, name), Buffer.from(png, 'base64'))
    console.log('    \x1b[2mscreenshot → e2e/screenshots/' + name + '\x1b[0m')
  } catch (e) { console.log('    \x1b[2m(screenshot ' + label + ' skipped: ' + ((e && e.message) || e) + ')\x1b[0m') }
}

// ---- fixture: a deterministic, draw-safe test photo in the device gallery -------------------
// The Android Photo Picker lists newest-first, so we (1) clear large prior restore outputs that
// would push the picker off our fixture AND would over-size the on-screen compositor, then
// (2) ensure a small (≤512px) test photo exists and is the most recent image. A small source
// keeps the restore output well under Android's ~100MB Canvas draw limit.
//
// L-I6: this is ANDROID-ONLY (it drives the MediaStore via `adb`). On iOS the equivalent seed is
//   `xcrun simctl addmedia booted host/ios/Tests/CanopyHostUITests/Fixtures/lumen-test.jpg`
// (the byte-identical fixture), run by the harness BEFORE this spec — see e2e/README.md + the run
// recipe at the top of host/ios/Tests/CanopyHostUITests/CanopyLumenRestoreUITests.swift. So on iOS
// we skip the adb seed and trust the pre-seeded library (the picker is still newest-first).
function prepareGalleryFixtureAndroid() {
  // The host ships the canonical 400×400 test image as an asset; it is already present on this
  // emulator at /sdcard/Pictures/lumen-test.jpg. Pull its MediaStore rows, delete anything that
  // is NOT our small fixture and is large (a prior restore output), then re-scan so the picker
  // refreshes. Best-effort: any adb hiccup just leaves the gallery as-is and the run proceeds.
  const q = adb('shell', 'content', 'query', '--uri', 'content://media/external/images/media',
    '--projection', '_id:_data:width:height')
  const rows = q.split('\n').map((l) => {
    const id = (l.match(/_id=(\d+)/) || [])[1]
    const data = (l.match(/_data=([^,]+)/) || [])[1]
    const w = parseInt((l.match(/width=(\d+)/) || [])[1] || '0', 10)
    const h = parseInt((l.match(/height=(\d+)/) || [])[1] || '0', 10)
    return id ? { id, data: (data || '').trim(), w, h } : null
  }).filter(Boolean)

  const small = rows.filter((r) => r.w > 0 && r.w <= 512 && r.h > 0 && r.h <= 512)
  const big = rows.filter((r) => r.w > 512 || r.h > 512)

  // Drop large prior outputs so they neither shadow the fixture nor crash the compositor.
  for (const r of big) {
    adb('shell', 'content', 'delete', '--uri', 'content://media/external/images/media/' + r.id)
    if (r.data) adb('shell', 'rm', '-f', r.data)
  }
  // Make sure a small fixture exists + is the newest image by re-stamping its mtime, then re-scan.
  const fixture = (small[0] && small[0].data) || '/sdcard/Pictures/lumen-test.jpg'
  adb('shell', 'touch', fixture)
  adb('shell', 'am', 'broadcast', '-a', 'android.intent.action.MEDIA_SCANNER_SCAN_FILE',
    '-d', 'file://' + fixture)
  return { kept: small.length, removed: big.length, fixture }
}

// ---- platform-neutral OS-chrome helpers (the ONLY per-platform edges of the parity spine) ---
// The app's own views are always selected by `~testID`; these touch the OS picker / share sheet the
// app does NOT own, whose detection differs by platform. They are the exact twins of the iOS-only
// branches in CanopyLumenRestoreUITests.swift (PHPicker / UIActivityViewController).

// Has the OS photo picker come to the FRONT after the ~choose tap? Android: the foreground package
// flips to the photo-picker provider. iOS: the system PHPicker presents IN-PROCESS, so we look for
// its standard chrome (Photos/Recents/Cancel) on the page source.
async function pickerIsUp(driver) {
  if (IOS) return hasText(driver, /^(Photos|Recents|Albums|Cancel|Photo Library|Library|Collections)$/)
  return /providers\.media|photopicker|DocumentsUI/i.test(await driver.getCurrentPackage())
}

// Pick the most-recent photo (our seeded ≤512px fixture — newest-first). Android: the picker exposes
// cells as "Photo taken on …" (content-desc). iOS: PHPicker exposes the grid as image cells; the
// first is the newest. Returns true once a cell was tapped.
async function pickNewestPhoto(driver) {
  if (IOS) {
    const img = await driver.$('(//XCUIElementTypeImage)[1]')
    if (await img.isExisting().catch(() => false)) { await img.click(); return true }
    const cell = await driver.$('(//XCUIElementTypeCell)[1]')
    await cell.waitForExist({ timeout: 15000 })
    await cell.click()
    return true
  }
  const photo = await driver.$('//*[contains(@content-desc,"Photo taken on")]')
  await photo.waitForExist({ timeout: 15000 })
  await photo.click()
  return true
}

// Is the system share sheet in FRONT? Android: the chooser is a separate package (intentresolver).
// iOS: UIActivityViewController presents IN-PROCESS — detect its standard action chrome on the source.
async function shareSheetIsUp(driver) {
  if (IOS) return hasText(driver, /^(Copy|Save Image|AirDrop|Cancel|Close|Options|More|Messages|Mail)$/)
  return /intentresolver|resolver|chooser/i.test(await driver.getCurrentPackage())
}

// Dismiss the share sheet and return to Compare. Android: press back only while the chooser is in
// front (a too-early back would hit Lumen's onBackPressed Sub). iOS: tap the sheet's Close/Cancel, or
// tap outside the bottom sheet to dismiss the in-process presentation (NEVER a `back` on iOS).
async function dismissShareSheet(driver) {
  for (let i = 0; i < 5; i++) {
    if (await hasText(driver, /Before \/ After/)) return true
    if (IOS) {
      const close = await driver.$('~Close')
      const cancel = await driver.$('~Cancel')
      if (await close.isExisting().catch(() => false)) await close.click()
      else if (await cancel.isExisting().catch(() => false)) await cancel.click()
      else { try { await driver.action('pointer').move({ x: 30, y: 30 }).down().up().perform() } catch { /* ignore */ } }
    } else if (await shareSheetIsUp(driver)) {
      await driver.back()
    }
    await driver.pause(1500)
  }
  return hasText(driver, /Before \/ After/)
}

// After the picker returns, focus is back in our app. Android exposes the package; iOS presents the
// picker in-process so "back in the app" is proven by the next screen's copy ("Ready to restore").
async function focusBackInApp(driver) {
  if (IOS) return true  // asserted by the Detected-screen copy that follows
  return (await driver.getCurrentPackage()) === 'org.canopy.echo'
}

// ---------------------------------------------------------------------------------------------
console.log('\n\x1b[1mLUMEN restore E2E — ' + capsLabel(CAPS) + '\x1b[0m')

// The gallery seed is Android-only (adb/MediaStore); on iOS the library is pre-seeded via
// `xcrun simctl addmedia` before the run (see the helper's doc + e2e/README.md).
if (!IOS) {
  const fx = prepareGalleryFixtureAndroid()
  console.log('  \x1b[2mgallery fixture: kept ' + fx.kept + ' small, removed ' + fx.removed + ' oversized → ' + fx.fixture + '\x1b[0m')
} else {
  console.log('  \x1b[2miOS: using the pre-seeded photo library (xcrun simctl addmedia lumen-test.jpg)\x1b[0m')
}

const driver = await remote({ hostname: '127.0.0.1', port: 4723, path: '/', capabilities: CAPS, logLevel: 'error' })
try {
  // 0. PICK — the real app booted to the Pick screen with native views (testID -> content-desc).
  const choose = await driver.$('~choose')
  await choose.waitForExist({ timeout: 25000 })
  check('app launched to Pick: "Choose a photo" CTA found by testID (~choose)', await choose.isExisting())
  check('Pick screen shows the "Lumen" title', await hasText(driver, /^Lumen$/))
  check('Pick screen shows the tagline', await hasText(driver, /Bring old photos back to life/))
  check('Pick screen shows the on-device trust line', await hasText(driver, /On-device · nothing uploaded/))
  await shot(driver, 'pick')

  // 1. tap choose → the OS photo picker opens (a real native interaction). Platform-neutral: the
  //    Android Photo Picker provider OR the iOS PHPicker chrome (pickerIsUp branches on platform).
  await choose.click()
  await driver.pause(3000)
  let pickerUp = false
  for (let i = 0; i < 8 && !pickerUp; i++) { pickerUp = await pickerIsUp(driver); if (!pickerUp) await driver.pause(400) }
  check('tapping ~choose opens the OS photo picker', pickerUp)
  await shot(driver, 'picker')

  // 2. pick the seeded test photo (newest-first). pickNewestPhoto branches: Android content-desc
  //    cell vs iOS PHPicker image cell.
  await pickNewestPhoto(driver)
  await driver.pause(2500)
  check('after picking, focus returns to the app', await focusBackInApp(driver))

  // 3. DETECTED — the picked photo decoded; the one-tap "Just fix it" CTA is shown.
  check('Detected screen shows "Ready to restore"', await waitForText(driver, /Ready to restore/, { timeout: 15000 }))
  const justfix = await driver.$('~justfix')
  await justfix.waitForExist({ timeout: 10000 })
  check('Detected screen rendered the "Just fix it" CTA (~justfix)', await justfix.isExisting())
  await shot(driver, 'detected')

  // 4. tap justfix → Processing → the REAL ESPCN ONNX super-resolution pass. On a small fixture
  //    the restore can finish in well under a poll interval, so we treat reaching EITHER the
  //    transient Processing copy OR the Compare result as proof the restore ran (the transient
  //    state is legitimately skippable on a fast device — the Compare arrival below is the gate).
  await justfix.click()
  const processingOrCompare = await waitForText(
    driver, /Enhancing details|super-resolution|Restoring|Before \/ After/, { timeout: 12000 })
  check('tapping ~justfix starts the restore (Processing screen or its Compare result)', processingOrCompare)

  // 5. COMPARE — the restore finished on-device and the before/after wipe is shown. Generous wait:
  //    real inference at multi-MP (ONNX on Android, Core ML/ANE on iOS). "Enhanced to N×N" = proof.
  check('restore completes on-device and reaches the Compare screen ("Before / After")',
    await waitForText(driver, /Before \/ After/, { timeout: IOS ? 120000 : 90000 }))
  await driver.pause(1200)
  const compareTexts = await texts(driver)
  // Accept the U+00D7 multiplication sign the app renders AND a plain 'x' (some accessibility trees
  // normalise it) — both platforms render the same RestoreEngine.width/height pair.
  const badgeRe = /^Enhanced to \d+[×x]\d+$/
  const enhanced = compareTexts.find((t) => badgeRe.test(t)) || ''
  check('Compare shows the real restored output size ("Enhanced to N×N" — inference proof)', badgeRe.test(enhanced), 'badge="' + enhanced + '"')
  // free-tier export gate (L-A4/L-A5): the ✦ watermark overlay + the budget cap note are shown.
  check('Compare surfaces the free-tier export gate (✦ Lumen watermark)', await hasText(driver, /✦ Lumen/))
  check('Compare surfaces the L-A5 budget cap note ("Free export: …px")', compareTexts.some((t) => /Free export:.*px/.test(t)), compareTexts.filter((t) => /px/.test(t)).join(' | '))
  const save = await driver.$('~save')
  const share = await driver.$('~share')
  await save.waitForExist({ timeout: 10000 })
  check('Compare rendered the Save CTA (~save)', await save.isExisting())
  check('Compare rendered the Share CTA (~share)', await share.isExisting())
  await shot(driver, 'compare')

  // 6. SHARE — tap share → the system share sheet opens; dismiss it and confirm we land back on
  //    Compare (the export side-effect is real). Platform-neutral: Android intentresolver chooser vs
  //    iOS UIActivityViewController (shareSheetIsUp / dismissShareSheet branch on platform).
  await share.click()
  let shareSheet = false
  for (let i = 0; i < 12 && !shareSheet; i++) { shareSheet = await shareSheetIsUp(driver); if (!shareSheet) await driver.pause(400) }
  check('tapping ~share opens the system share sheet', shareSheet)
  await shot(driver, 'share-sheet')
  // Dismiss it robustly and wait for the Compare screen to resume (the sheet only pauses our screen,
  // so the Compare TEA state resumes intact — no re-launch, no lost screen).
  const backOnCompare = await dismissShareSheet(driver)
  check('dismissing the share sheet returns to Compare', backOnCompare)

  // 7. SAVE → DONE — Album.save writes the restored image to the gallery and the Done screen shows.
  await tap(driver, 'save')
  check('tapping ~save reaches the Done screen ("✓  Saved")', await waitForText(driver, /Saved/, { timeout: 25000 }))
  check('Done screen confirms the album write ("Saved to your Lumen album.")', await hasText(driver, /Saved to your Lumen album/))
  const another = await driver.$('~another')
  await another.waitForExist({ timeout: 10000 })
  check('Done screen rendered the "Restore another" CTA (~another)', await another.isExisting())
  await shot(driver, 'done')

  // 8. RESTORE ANOTHER — the loop closes back to a fresh Pick screen.
  await another.click()
  check('tapping ~another returns to a fresh Pick screen', await waitForText(driver, /Pick a photo to restore|Choose a photo/, { timeout: 10000 }))
} catch (e) {
  check('E2E session ran without an unexpected error', false, String((e && e.stack) || e))
} finally {
  try { await driver.deleteSession() } catch { /* ignore */ }
}

console.log('\n\x1b[1mResult: ' + (failed === 0 ? '\x1b[32mPASS' : '\x1b[31mFAIL') + '\x1b[0m  (' + passed + ' passed, ' + failed + ' failed)')
if (failed) console.log('failed:\n  - ' + fails.join('\n  - '))
process.exit(failed === 0 ? 0 : 1)
