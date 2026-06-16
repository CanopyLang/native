// CanopyLumenRestoreUITests.swift — L-I6: the LUMEN restore flow on a real iPhone, driven by
// XCUITest. This is the iPhone-PARITY twin of the Android Appium spec e2e/lumen-restore.mjs (L-A6)
// and the Maestro flow e2e/flows/lumen-restore.yaml: the SAME pick → restore → compare → share →
// save → loop spine, selecting ONLY on the `testID` → accessibilityIdentifier contract the host
// wires (CanopyHostFabric.mm: A.testID "choose" → view.accessibilityIdentifier "choose"), and
// asserting the SAME deterministic screen copy the Lumen `update` renders. One spec contract, both
// platforms — the cross-platform thesis, proven at the device-E2E layer (the L-I6 deliverable).
//
// =====================================================================================
//  [MAC-REQUIRED · DEVICE-PREFERRED] — every test here needs a booted iOS Simulator or, for the
//  REAL on-device gates (the Core ML / ANE restore, the system Photos picker, the share sheet, a
//  PHPhotoLibrary save), a provisioned physical iPhone. Nothing in this file can run on the Linux
//  authoring box: Hermes/Yoga link, code signing, the Simulator/device runtime, Photos + Core ML are
//  all Apple-only. The exact Mac/device run steps are in host/ios/BUILD-AND-VALIDATE.md §5.8 (this
//  file's run recipe) and the device-free structural gate is scripts/check-ios-lumen-e2e.sh.
//
//  Run it (on a Mac, against the LUMEN bundle embedded as canopy.bundle.js — NOT the counter bundle):
//
//      # 1. embed the real Lumen bundle (the iOS twin of the Android dev-override push)
//      canopy-native build /home/quinten/projects/apps/lumen/app
//      cp /home/quinten/projects/apps/lumen/app/build/canopy.bundle.js \
//         host/ios/CanopyHostApp/Resources/canopy.bundle.js
//      # 2. seed ONE small (≤512px) draw-safe photo as the newest image (deterministic + draw-safe)
//      xcrun simctl boot 'iPhone 15'
//      xcrun simctl addmedia booted host/ios/Tests/CanopyHostUITests/Fixtures/lumen-test.jpg
//      # 3. drive the Lumen flow (the -CanopyLumenE2E launch arg makes the spec assert the Lumen spine)
//      cd host/ios
//      xcodebuild test \
//        -workspace CanopyHost.xcworkspace -scheme CanopyHost \
//        -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15,OS=latest' \
//        -only-testing:CanopyHostUITests/CanopyLumenRestoreUITests
//      # On a PHYSICAL iPhone: -destination 'platform=iOS,name=<device>' + a signing team (IOS-10).
// =====================================================================================
//
// PARITY CONTRACT (the L-A6 ↔ L-I6 invariant). The Android spec (lumen-restore.mjs) and THIS file
// drive the identical spine and assert the identical copy + testIDs:
//
//   Pick     "Lumen" / "Bring old photos back to life." / "On-device · nothing uploaded"  (~choose)
//     → tap choose → the system Photos picker (PHPicker) presents; pick the seeded test photo
//   Detected "Ready to restore"                                                            (~justfix)
//     → tap justfix → Processing ("Restoring" / "Enhancing details · super-resolution")
//   Processing → the REAL on-device super-resolution pass runs (Core ML / ANE on iOS; ESPCN ONNX on
//                Android) — no mock
//   Compare  "Before / After", the native BeforeAfter wipe, "Enhanced to N×N" (the inference proof),
//            the free-tier export gate ("✦ Lumen" watermark + "Free export: …px")          (~save / ~share)
//     → tap share → the system share sheet (UIActivityViewController) presents; dismiss → back on Compare
//     → tap save  → Album.save (PHPhotoLibrary) → Done
//   Done     "✓  Saved" / "Saved to your Lumen album."                                     (~another)
//     → tap another → the loop closes back to a fresh Pick
//
// The "Enhanced to N×N" badge on Compare is the inference proof: it is the ACTUAL restored output
// size (RestoreEngine.width/height), so a green run proves the real on-device super-resolution ran,
// not a stub — exactly as on Android.
//
// HONESTY: when the embedded bundle is the bare counter (not the Lumen bundle), the very first gate
// (the "Lumen" title / ~choose) is absent, so setUp XCTSkips the whole class with an explicit reason
// (never a silent pass). Embed the Lumen bundle (step 1 above) to drive the flow.

import XCTest

final class CanopyLumenRestoreUITests: XCTestCase {

  // The deterministic testIDs the Lumen `view` renders (parity with e2e/lumen-restore.mjs). These are
  // the SAME ids the Android content-description selector uses — A.testID → accessibilityIdentifier.
  private let chooseID  = "choose"   // Pick:    "Choose a photo"
  private let justfixID = "justfix"  // Detected: "Just fix it"
  private let saveID    = "save"     // Compare:  "Save"
  private let shareID   = "share"    // Compare:  "Share"
  private let anotherID = "another"  // Done:     "Restore another"

  private var app: XCUIApplication!

  override func setUpWithError() throws {
    continueAfterFailure = false
    app = XCUIApplication()
    // A clean foreground launch each run = fresh TEA state (parity with the Android forceAppLaunch),
    // so every run starts on the Pick screen. -CanopyLumenE2E documents intent (the spec is gated on
    // the Lumen surface actually being embedded, below).
    app.launchArguments += ["-CanopyUITest", "1", "-CanopyLumenE2E", "1"]
    app.launch()

    // Gate honestly on the embedded bundle: the Lumen flow only exists if the LUMEN bundle is embedded
    // as canopy.bundle.js. If the bare counter bundle is embedded, ~choose / the "Lumen" title are
    // absent — XCTSkip the whole class with an explicit reason rather than failing or silently passing.
    let lumenPresent =
      waitForText(10) { $0 == "Lumen" } || element(testID: chooseID).waitForExistence(timeout: 4)
    try XCTSkipUnless(
      lumenPresent,
      "[L-I6] the embedded canopy.bundle.js is not the Lumen bundle (no \"Lumen\" title / ~choose). " +
      "Embed the real Lumen bundle (apps/lumen/app → CanopyHostApp/Resources/canopy.bundle.js) to " +
      "drive the lumen-restore flow on the Simulator/device — see the run recipe at the top of this file.")
  }

  override func tearDownWithError() throws {
    app = nil
  }

  // MARK: - small helpers (the Swift twin of lumen-restore.mjs's texts()/waitForText()/check()) -----

  /// Every visible static-text string on the live native view tree (the XCUITest twin of reading
  /// `text="…"` off the Appium page source). Native text nodes only exist if JSI + Yoga + the
  /// production walker ran — a WebView would expose none — so reading "Before / After" here is itself
  /// a full-stack render proof.
  private func visibleTexts() -> [String] {
    let labels = app.staticTexts.allElementsBoundByIndex.map { $0.label }
    return Array(Set(labels)).filter { !$0.isEmpty }
  }

  private func hasText(_ predicate: (String) -> Bool) -> Bool {
    visibleTexts().contains(where: predicate)
  }

  /// Poll until a label matching `predicate` appears (the deterministic-copy wait; parity with the
  /// Android waitForText). Generous on the Compare wait because the real ANE inference takes time.
  /// `predicate` is NON-escaping (it is only evaluated synchronously inside the loop), so call sites
  /// may reference instance helpers (isPickerChrome/isShareSheetChrome) without an explicit `self.`.
  @discardableResult
  private func waitForText(_ timeout: TimeInterval = 30, _ predicate: (String) -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if hasText(predicate) { return true }
      _ = app.staticTexts.firstMatch.waitForExistence(timeout: 0.35)
    }
    return false
  }

  /// The element selected by its Canopy `testID` (== accessibilityIdentifier). This is the ONE
  /// selector contract shared with Android (~testID); never a coordinate. A nil/absent element fails
  /// the gate loudly (waitForExistence at the call site).
  private func element(testID: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: testID).firstMatch
  }

  // MARK: - the spine ----------------------------------------------------------------------------
  //
  // ONE end-to-end test that walks the whole Lumen restore spine in order. It is one method (not six)
  // because the spine is stateful — each screen is reached only by completing the prior — and a clean
  // launch resets it; this mirrors lumen-restore.mjs running the steps as one session.

  func test_lumenRestoreSpine_pickRestoreCompareShareSaveLoop() throws {
    // 0. PICK — the real Lumen app booted to the Pick screen with native views (testID → a11y id).
    let choose = element(testID: chooseID)
    XCTAssertTrue(choose.waitForExistence(timeout: 25),
                  "app launched to Pick: the \"Choose a photo\" CTA is found by testID (~choose)")
    XCTAssertTrue(hasText { $0 == "Lumen" }, "Pick screen shows the \"Lumen\" title")
    XCTAssertTrue(hasText { $0.contains("Bring old photos back to life") },
                  "Pick screen shows the tagline")
    XCTAssertTrue(hasText { $0.contains("On-device") && $0.contains("nothing uploaded") },
                  "Pick screen shows the on-device trust line (\"On-device · nothing uploaded\")")

    // 1. tap choose → the system Photos picker (PHPicker) presents (a real native interaction). On
    //    iOS PHPicker presents IN-PROCESS, so — unlike Android, where the foreground package flips to
    //    the photo-picker provider — we detect it by its standard chrome (Photos/Recents/Cancel) on
    //    the element tree. autoAcceptAlerts (caps/scheme) dismisses the Photos permission alert.
    choose.tap()
    XCTAssertTrue(waitForText(15) { isPickerChrome($0) },
                  "tapping ~choose opens the system Photos picker (PHPicker chrome appears)")

    // 2. pick the seeded test photo. PHPicker exposes the grid as image cells; the FIRST cell is the
    //    most-recent image (our seeded ≤512px fixture — newest-first, deterministic AND draw-safe).
    try pickFirstPhoto()

    // 3. DETECTED — the picked photo decoded; the one-tap "Just fix it" CTA is shown.
    XCTAssertTrue(waitForText(20) { $0.contains("Ready to restore") },
                  "Detected screen shows \"Ready to restore\"")
    let justfix = element(testID: justfixID)
    XCTAssertTrue(justfix.waitForExistence(timeout: 10),
                  "Detected screen rendered the \"Just fix it\" CTA (~justfix)")

    // 4. tap justfix → Processing → the REAL on-device super-resolution pass (Core ML / ANE). On a
    //    small fixture the restore can finish in well under a poll interval, so reaching EITHER the
    //    transient Processing copy OR the Compare result proves the restore ran (Compare is the gate).
    justfix.tap()
    XCTAssertTrue(
      waitForText(15) { $0.contains("Restoring") || $0.contains("Enhancing details")
        || $0.contains("super-resolution") || $0.contains("Before / After") },
      "tapping ~justfix starts the restore (Processing screen or its Compare result)")

    // 5. COMPARE — the restore finished on-device and the before/after wipe is shown. Generous wait:
    //    real Core ML inference at multi-MP. The "Enhanced to N×N" badge is the inference proof.
    XCTAssertTrue(waitForText(120) { $0.contains("Before / After") },
                  "restore completes on-device and reaches the Compare screen (\"Before / After\")")
    let badge = visibleTexts().first { isEnhancedBadge($0) } ?? ""
    XCTAssertTrue(isEnhancedBadge(badge),
                  "Compare shows the real restored output size (\"Enhanced to N×N\" — the inference proof). badge=\(badge)")
    // free-tier export gate (L-A4/L-I5 parity): the ✦ watermark + the budget cap note are shown.
    XCTAssertTrue(hasText { $0.contains("✦ Lumen") },
                  "Compare surfaces the free-tier export gate (✦ Lumen watermark)")
    XCTAssertTrue(hasText { $0.contains("Free export:") && $0.contains("px") },
                  "Compare surfaces the export budget cap note (\"Free export: …px\")")
    let save = element(testID: saveID)
    let share = element(testID: shareID)
    XCTAssertTrue(save.waitForExistence(timeout: 10), "Compare rendered the Save CTA (~save)")
    XCTAssertTrue(share.waitForExistence(timeout: 10), "Compare rendered the Share CTA (~share)")

    // 6. SHARE — tap share → the system share sheet (UIActivityViewController) presents; dismiss it
    //    and confirm we land back on Compare (the export side-effect is real, a separate presentation).
    //    On iOS the sheet is IN-PROCESS (it does NOT flip the foreground app the way the Android
    //    intentresolver does), so we detect it by its chrome and dismiss via Close/Cancel or tap-outside.
    share.tap()
    XCTAssertTrue(waitForText(10) { isShareSheetChrome($0) }
                  || shareSheetCloseButton().waitForExistence(timeout: 6),
                  "tapping ~share opens the system share sheet (UIActivityViewController)")
    dismissShareSheet()
    XCTAssertTrue(waitForText(20) { $0.contains("Before / After") },
                  "dismissing the share sheet returns to Compare")

    // 7. SAVE → DONE — Album.save writes the restored image to the photo library and Done is shown.
    save.tap()
    XCTAssertTrue(waitForText(25) { $0.contains("Saved") },
                  "tapping ~save reaches the Done screen (\"✓  Saved\")")
    XCTAssertTrue(hasText { $0.contains("Saved to your Lumen album") },
                  "Done screen confirms the album write (\"Saved to your Lumen album.\")")
    let another = element(testID: anotherID)
    XCTAssertTrue(another.waitForExistence(timeout: 10),
                  "Done screen rendered the \"Restore another\" CTA (~another)")

    // 8. RESTORE ANOTHER — the loop closes back to a fresh Pick screen.
    another.tap()
    XCTAssertTrue(waitForText(10) { $0.contains("Pick a photo to restore") || $0.contains("Choose a photo") },
                  "tapping ~another returns to a fresh Pick screen")
  }

  // MARK: - iOS picker / share-sheet helpers (the platform-specific edges of the parity spine) ----
  //
  // These are the ONLY iOS-specific bits — exactly the Android lumen-restore.mjs counterparts
  // (getCurrentPackage()-on-the-picker, the intentresolver chooser dismissal). The SELECTORS for the
  // app itself stay testID-only; these touch the OS chrome the app does not own.

  /// Standard PHPicker chrome strings (the in-process Photos picker). Any one appearing is proof the
  /// ~choose tap drove a real native presentation (not a JS state change). Parity with the Android
  /// pickerIsUp() text check in run-e2e.mjs.
  private func isPickerChrome(_ s: String) -> Bool {
    ["Photos", "Recents", "Albums", "Cancel", "Photo Library", "Library", "Collections"].contains(s)
  }

  /// Standard UIActivityViewController chrome. The share sheet's row/action labels vary by installed
  /// apps; "Copy"/"Save Image"/"AirDrop"/"Cancel"/"Close" are the stable system actions.
  private func isShareSheetChrome(_ s: String) -> Bool {
    ["Copy", "Save Image", "AirDrop", "Cancel", "Close", "Options", "More"].contains(s)
  }

  /// Pick the most-recent photo in PHPicker. The grid cells are images; the FIRST is the newest (our
  /// seeded fixture). Tapping a single asset in the single-selection picker dismisses it and returns
  /// the blob to the app (parity with the Android "tap the newest cell" step). Falls back to a "Photo"
  /// /"Image" labelled cell if the image-element heuristic finds nothing.
  private func pickFirstPhoto() throws {
    // Prefer a real image cell in the picker's collection.
    let images = app.images
    if images.count > 0 {
      let first = images.element(boundBy: 0)
      if first.waitForExistence(timeout: 10) { first.tap(); return }
    }
    // Fallbacks: a cell whose label/identifier looks like a photo asset, then the first collection cell.
    let byLabel = app.cells.matching(NSPredicate(format: "label CONTAINS[c] 'Photo' OR label CONTAINS[c] 'Image'")).firstMatch
    if byLabel.waitForExistence(timeout: 6) { byLabel.tap(); return }
    let anyCell = app.cells.firstMatch
    if anyCell.waitForExistence(timeout: 6) { anyCell.tap(); return }
    XCTFail("PHPicker presented but no photo cell was selectable — seed a fixture with " +
            "`xcrun simctl addmedia booted <small.jpg>` (see the run recipe at the top of this file)")
  }

  /// The share sheet's dismiss control (Close on iOS 16+, Cancel earlier). Returned so we can wait on it.
  private func shareSheetCloseButton() -> XCUIElement {
    let close = app.buttons["Close"]
    if close.exists { return close }
    return app.buttons["Cancel"]
  }

  /// Dismiss UIActivityViewController robustly: tap its Close/Cancel if present, else tap outside the
  /// sheet (the dimming view) to dismiss the half-sheet — never a `back`, which on iOS would not close
  /// an in-process sheet and could disturb the nav stack (parity intent with the Android "press back
  /// only while the chooser is confirmed in front" guard).
  private func dismissShareSheet() {
    let close = shareSheetCloseButton()
    if close.waitForExistence(timeout: 4) { close.tap(); return }
    // No explicit dismiss control: tap the top-left corner (outside the bottom sheet) to dismiss.
    let outside = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.04))
    outside.tap()
  }

  /// Is `s` the "Enhanced to N×N" inference-proof badge? Accepts the U+00D7 multiplication sign the
  /// app renders ("Enhanced to 1200×1200") AND a plain 'x' fallback, matching the Android regex.
  private func isEnhancedBadge(_ s: String) -> Bool {
    guard s.hasPrefix("Enhanced to ") else { return false }
    let nums = s.dropFirst("Enhanced to ".count)
    // "<digits>×<digits>" (or x). At least one digit on each side of the separator.
    let parts = nums.split(whereSeparator: { $0 == "\u{00D7}" || $0 == "x" || $0 == "X" })
    return parts.count == 2 && parts.allSatisfy { $0.allSatisfy(\.isNumber) && !$0.isEmpty }
  }
}
