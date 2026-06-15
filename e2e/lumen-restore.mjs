// lumen-restore.mjs — the LUMEN restore flow, end-to-end, driven by Appium (UIAutomator2 on
// Android, XCUITest on iOS) via WebdriverIO. This drives the REAL Lumen app
// (apps/lumen/app/src/Main.can) — the production TEA program, not the capability probe.
//
// It selects ONLY on the testID -> accessibility-id contract the host wires
// (CanopyHost: A.testID -> Android content-description / iOS accessibilityIdentifier), so the
// body is identical across the device matrix. It walks the product spine the Lumen `update`
// produces (plan/01: D1 auto-only "Just fix it", D3 on-device):
//
//   Pick     —  "Lumen" / "Choose a photo"        (testID choose)
//     → tap choose → the Android system Photo Picker opens; pick the seeded test photo
//   Detected —  "Ready to restore" / "Just fix it"  (testID justfix)
//     → tap justfix → Processing ("Enhancing details · super-resolution")
//   Processing → the REAL ESPCN ONNX super-resolution pass runs on-device (no mock)
//   Compare  —  "Before / After", the native BeforeAfter wipe, "Enhanced to N×N",
//               the free-tier export gate (✦ watermark + the L-A5 budget cap note)  (save / share)
//     → tap save  → Album.save (MediaStore) → Done
//   Done     —  "✓  Saved" / "Saved to your Lumen album."                            (another)
//   share    —  from Compare, tap share → the system share sheet (intentresolver) opens
//
// The "Enhanced to N×N" badge on Compare is the inference proof: it is the actual ESPCN output
// size, so a green run proves the real on-device super-resolution ran, not a stub.
//
// FIXTURE (self-contained): before the run we seed ONE known-good small test photo into the
// device gallery and clear large prior restore outputs. The picker is newest-first, so the run
// is deterministic AND the restored bitmap stays under Android's ~100MB Canvas draw limit (a big
// source → a multi-MP restore the on-screen BeforeAfter compositor cannot draw — see README).
//
// Run:  npm run appium          (one shell — starts the server on 127.0.0.1:4723)
//       node lumen-restore.mjs   (another — against the booted org.canopy.echo running the Lumen bundle)
// Matrix: ./run-matrix.sh        (SPEC defaults to this file; pushes the Lumen bundle + restarts)

import { remote } from 'webdriverio'
import { execFileSync } from 'node:child_process'
import { mkdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const ADB = process.env.ADB || 'adb'
const SHOTS = join(HERE, 'screenshots')

const CAPS = {
  platformName: process.env.E2E_PLATFORM || 'Android',
  'appium:automationName': process.env.E2E_AUTOMATION || 'UiAutomator2',
  'appium:appPackage': 'org.canopy.echo',
  'appium:appActivity': 'com.canopyhost.MainActivity',
  // A clean launch each run so we always start on the Pick screen with fresh TEA state.
  'appium:noReset': process.env.E2E_NORESET === '1',
  'appium:forceAppLaunch': true,
  'appium:newCommandTimeout': 200,
  // auto-accept the POST_NOTIFICATIONS / READ_MEDIA runtime dialogs so the spine never stalls.
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
// keeps the ESPCN restore output well under Android's ~100MB Canvas draw limit.
function prepareGalleryFixture() {
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

// ---------------------------------------------------------------------------------------------
console.log('\n\x1b[1mLUMEN restore E2E — ' + CAPS.platformName + ' / ' + CAPS['appium:automationName'] + '\x1b[0m')

const fx = prepareGalleryFixture()
console.log('  \x1b[2mgallery fixture: kept ' + fx.kept + ' small, removed ' + fx.removed + ' oversized → ' + fx.fixture + '\x1b[0m')

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

  // 1. tap choose → the Android system Photo Picker opens (a real native interaction).
  await choose.click()
  await driver.pause(3000)
  const pickerUp = /providers\.media|photopicker|DocumentsUI/i.test(await driver.getCurrentPackage())
  check('tapping ~choose opens the OS photo picker', pickerUp, 'pkg=' + (await driver.getCurrentPackage()))
  await shot(driver, 'picker')

  // 2. pick the seeded test photo (the picker exposes cells as "Photo taken on …").
  const photo = await driver.$('//*[contains(@content-desc,"Photo taken on")]')
  await photo.waitForExist({ timeout: 15000 })
  await photo.click()
  await driver.pause(2500)
  check('after picking, focus returns to the app', (await driver.getCurrentPackage()) === 'org.canopy.echo')

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

  // 5. COMPARE — the restore finished on-device and the before/after wipe is shown. Generous
  //    wait: real ONNX inference at multi-MP. The "Enhanced to N×N" badge is the inference proof.
  check('restore completes on-device and reaches the Compare screen ("Before / After")',
    await waitForText(driver, /Before \/ After/, { timeout: 90000 }))
  await driver.pause(1200)
  const compareTexts = await texts(driver)
  const enhanced = compareTexts.find((t) => /^Enhanced to \d+×\d+$/.test(t)) || ''
  check('Compare shows the real ESPCN output size ("Enhanced to N×N" — inference proof)', /Enhanced to \d+×\d+/.test(enhanced), 'badge="' + enhanced + '"')
  // free-tier export gate (L-A4/L-A5): the ✦ watermark overlay + the budget cap note are shown.
  check('Compare surfaces the free-tier export gate (✦ Lumen watermark)', await hasText(driver, /✦ Lumen/))
  check('Compare surfaces the L-A5 budget cap note ("Free export: …px")', compareTexts.some((t) => /Free export:.*px/.test(t)), compareTexts.filter((t) => /px/.test(t)).join(' | '))
  const save = await driver.$('~save')
  const share = await driver.$('~share')
  await save.waitForExist({ timeout: 10000 })
  check('Compare rendered the Save CTA (~save)', await save.isExisting())
  check('Compare rendered the Share CTA (~share)', await share.isExisting())
  await shot(driver, 'compare')

  // 6. SHARE — tap share → the system share sheet (intentresolver) opens; dismiss it and confirm
  //    we land back on Compare (the export side-effect is real, a separate activity).
  await share.click()
  // Wait for the chooser to actually be in FRONT before we press back — pressing back too early
  // would hit Lumen's own onBackPressed Sub (popping the nav stack) instead of closing the sheet.
  const isChooser = async () => /intentresolver|resolver|chooser/i.test(await driver.getCurrentPackage())
  let shareSheet = false
  for (let i = 0; i < 12 && !shareSheet; i++) { shareSheet = await isChooser(); if (!shareSheet) await driver.pause(400) }
  check('tapping ~share opens the system share sheet', shareSheet, 'pkg=' + (await driver.getCurrentPackage()))
  await shot(driver, 'share-sheet')
  // Dismiss the chooser robustly: press back only while the chooser is confirmed in front, retry
  // until the Compare screen is back. The chooser only pauses our activity, so the Compare TEA
  // state resumes intact — no re-launch, no lost screen.
  let backOnCompare = false
  for (let i = 0; i < 5 && !backOnCompare; i++) {
    if (await isChooser()) await driver.back()
    await driver.pause(1500)
    backOnCompare = await hasText(driver, /Before \/ After/)
  }
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
