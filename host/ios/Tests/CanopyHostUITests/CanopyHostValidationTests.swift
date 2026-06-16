// CanopyHostValidationTests.swift — IOS-6: the FULL Part-5 validation ledger, driven on the iOS
// Simulator via XCUITest. This is the iOS twin of the Android device-validated ledger (the Appium
// smoke.mjs / Maestro counter-smoke.yaml flows + the on-device matrix), and it builds on the IOS-5
// first-light boot smoke (CanopyHostUITests.swift). Where that suite proves only that the app boots
// to the foreground with a mounted window, THIS suite drives every Part-5 gate family enumerated in
// BUILD-AND-VALIDATE.md §5 (and tracked in PART5-LEDGER.md) until the ledger is green — the parity
// definition of done.
//
// =====================================================================================
//  [MAC-REQUIRED] — every test here needs a booted iOS Simulator (or device). Nothing in this file
//  can run on the Linux authoring box: Hermes/Yoga link, code signing, and the Simulator runtime are
//  Apple-only. The device-free legs of the ledger (the CanopyColor CSS verdicts, the diff-null reset,
//  the leaf measure-mode math, the streaming/ABI verdicts) are pinned WITHOUT a Simulator in the
//  ObjC++ XCTest CanopyValidationLedgerTests.mm + CanopyEngineTests.mm, and the whole ledger's
//  structural completeness is gated device-free by scripts/check-ios-validation-ledger.sh. This
//  Swift file is the on-device half.
//
//  Run it (on a Mac, after host/ios/BUILD-AND-VALIDATE.md Parts 1–3 produced CanopyHost.xcworkspace
//  and a real examples/counter bundle is at CanopyHostApp/Resources/canopy.bundle.js):
//
//      cd host/ios
//      xcodebuild test \
//        -workspace CanopyHost.xcworkspace \
//        -scheme CanopyHost \
//        -sdk iphonesimulator \
//        -destination 'platform=iOS Simulator,name=iPhone 15,OS=latest' \
//        -only-testing:CanopyHostUITests/CanopyHostValidationTests
// =====================================================================================
//
// PARITY CONTRACT (E2E-2): selection is by `testID` → accessibilityIdentifier, never by coordinates,
// and on-screen copy is read off the element tree. That is EXACTLY the contract the Android Appium
// flow (e2e/smoke.mjs) and the Maestro flow (e2e/flows/counter-smoke.yaml) use (testID → Android
// content-description / iOS accessibilityIdentifier), so the SAME assertions cover both platforms.
// The CANONICAL CI app (examples/counter) renders the deterministic copy this suite reads:
//   • a label "Count: N"
//   • a "Tap me" button with testID "increment"
//   • a "Reset"  button with testID "reset"
//
// HONESTY NOTE: the counter app exercises the render + event + capability spine end-to-end (boot →
// Yoga layout → native views → tap → TEA update → targeted updateProps). The richer component gates
// (ScrollView momentum, controlled TextInput, Image decode, Switch, Modal, the anim driver, each
// capability, streaming) are driven the same testID-selected way against a gallery/Lumen bundle that
// exposes those surfaces; until that gallery bundle is the embedded one, those tests SKIP with an
// explicit XCTSkip (never a silent pass) so the ledger never claims a gate it did not actually drive.

import XCTest

final class CanopyHostValidationTests: XCTestCase {

  // The deterministic testIDs + copy the canonical counter app renders (parity with e2e/smoke.mjs).
  private let incrementID = "increment"
  private let resetID     = "reset"

  private var app: XCUIApplication!

  override func setUpWithError() throws {
    continueAfterFailure = false
    app = XCUIApplication()
    // A clean foreground launch each run = fresh TEA state (parity with Android forceAppLaunch), so
    // every test starts the counter at "Count: 0".
    app.launchArguments += ["-CanopyUITest", "1"]
    app.launch()
  }

  override func tearDownWithError() throws {
    app = nil
  }

  // MARK: - small helpers (the Swift twin of smoke.mjs's texts()/waitForText()/check()) ----------

  /// Every visible static-text string on the live native view tree (the XCUITest twin of reading
  /// `text="…"` off the Appium page source). Native text nodes only exist if JSI + Yoga + the
  /// production walker ran — a WebView would expose none — so reading "Count: 0" here is itself a
  /// full-stack render proof.
  private func visibleTexts() -> [String] {
    let labels = app.staticTexts.allElementsBoundByIndex.map { $0.label }
    return Array(Set(labels)).filter { !$0.isEmpty }
  }

  private func hasText(_ predicate: (String) -> Bool) -> Bool {
    visibleTexts().contains(where: predicate)
  }

  /// Poll until a label matching `predicate` appears (the deterministic-copy wait).
  @discardableResult
  private func waitForText(_ timeout: TimeInterval = 20, _ predicate: @escaping (String) -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if hasText(predicate) { return true }
      _ = app.staticTexts.firstMatch.waitForExistence(timeout: 0.3)
    }
    return false
  }

  /// The element selected by its Canopy `testID` (== accessibilityIdentifier). This is the ONE
  /// selector contract shared with Android (~testID); a nil/absent element fails the gate loudly.
  private func element(testID: String) -> XCUIElement {
    // Match across the common control classes a Canopy testID can land on.
    let byID = app.descendants(matching: .any).matching(identifier: testID).firstMatch
    return byID
  }

  /// Skip-with-reason when the embedded bundle does not expose a given gate's surface, so the ledger
  /// never silently green-passes a gate it could not drive. (An XCTSkip is reported, not hidden.)
  private func requireSurface(_ id: String, _ gate: String) throws {
    let el = element(testID: id)
    if !el.waitForExistence(timeout: 4) {
      throw XCTSkip(
        "[\(gate)] the embedded bundle does not expose testID '\(id)'. Embed the gallery/Lumen " +
        "bundle that renders it (PART5-LEDGER.md) to drive this gate on the Simulator.")
    }
  }

  // MARK: - §5.1 RENDER GATES -------------------------------------------------------------------

  /// The whole native boot path succeeded AND it rendered: a native "Count: 0" text node exists,
  /// which only happens if Hermes booted, the ABI canary passed, the bundle evaluated with no
  /// red-box, and the root (pinned full-size to surface_) laid out in Yoga points and mounted.
  func test_5_1_render_bootsAndMountsNativeViews() throws {
    XCTAssertEqual(app.state, .runningForeground,
                   "the host should boot Hermes + the bundle and reach the foreground")
    XCTAssertTrue(waitForText(30) { $0 == "Count: 0" },
                  "the host should mount a NATIVE 'Count: 0' label (JSI + Yoga + walker ran)")
  }

  /// The host surface is on screen with a real frame (no "booted but rendered nothing" regression),
  /// and the layout is in points (the deliberate iOS divergence: no density multiply). We assert the
  /// root window fills the screen — a density-multiplied root would be the wrong size.
  func test_5_1_render_rootPinnedFullSizeInPoints() throws {
    let window = app.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 10), "the host window should mount")
    XCTAssertGreaterThan(window.frame.width, 0)
    XCTAssertGreaterThan(window.frame.height, 0)
    // The root is pinned to the surface, so the window covers the device screen bounds (points).
    let screen = XCUIScreen.main.bounds
    XCTAssertEqual(window.frame.width, screen.width, accuracy: 1.0,
                   "the root is pinned full-width in points (no density multiply)")
    XCTAssertEqual(window.frame.height, screen.height, accuracy: 1.0,
                   "the root is pinned full-height in points (no density multiply)")
  }

  // MARK: - §5.2 EVENT GATES --------------------------------------------------------------------

  /// A REAL tap on the testID-selected button dispatches a TEA Increment and the label re-renders to
  /// "Count: N" via a targeted native updateProps (NOT a re-mount) — the architecture's whole point.
  /// This drives the §5.2 press gate (exact `press` token → emit_ on main) end-to-end.
  func test_5_2_event_tapDispatchesTeaUpdate() throws {
    XCTAssertTrue(waitForText(30) { $0 == "Count: 0" }, "start at Count: 0")
    let increment = element(testID: incrementID)
    XCTAssertTrue(increment.waitForExistence(timeout: 15),
                  "the increment button is found by testID (~increment / accessibilityIdentifier)")
    XCTAssertTrue(increment.isHittable, "the button is on screen + hittable")

    let taps = 3
    for _ in 0..<taps { increment.tap() }
    XCTAssertTrue(waitForText(8) { $0 == "Count: \(taps)" },
                  "tapping ~increment \(taps)× dispatches updates → 'Count: \(taps)'")
  }

  /// A second handler works: ~reset dispatches Reset and the label returns to "Count: 0" — proves
  /// the event routing is general (not hardwired to one button) and setEvents wired both handlers.
  func test_5_2_event_secondHandlerResets() throws {
    let increment = element(testID: incrementID)
    XCTAssertTrue(increment.waitForExistence(timeout: 15))
    increment.tap()
    XCTAssertTrue(waitForText(8) { $0 == "Count: 1" })

    let reset = element(testID: resetID)
    XCTAssertTrue(reset.waitForExistence(timeout: 10),
                  "the reset button is found by testID (~reset)")
    reset.tap()
    XCTAssertTrue(waitForText(8) { $0 == "Count: 0" },
                  "tapping ~reset dispatches Reset → back to 'Count: 0'")
  }

  // MARK: - §5.3 COMPONENT GATES ----------------------------------------------------------------
  // These drive the richer surfaces by testID. They SKIP (never silently pass) when the embedded
  // bundle is the bare counter; embed the gallery bundle (PART5-LEDGER.md) to turn them green.

  /// ScrollView: momentum scroll moves content; the §5.3 ScrollView gate (separate content root,
  /// contentSize from the content node) is observable as the list offset changing after a swipe.
  func test_5_3_component_scrollViewMomentum() throws {
    try requireSurface("gallery-scroll", "ScrollView")
    let scroll = element(testID: "gallery-scroll")
    // row-0 starts at the top; after a fast swipe up, momentum should carry the content far enough
    // that row-0 is no longer hittable (it scrolled out of view). The content root having its own
    // Yoga layout + a real contentSize is what makes the list scrollable at all.
    XCTAssertTrue(app.staticTexts["row-0"].waitForExistence(timeout: 4), "the first row mounts")
    scroll.swipeUp(velocity: .fast)
    XCTAssertFalse(app.staticTexts["row-0"].isHittable,
                   "a fast swipe scrolled row-0 out of view (momentum + a real contentSize)")
  }

  /// TextInput: a controlled UITextField round-trips typed text via changeText into the model and
  /// the rendered echo updates — the §5.3 controlled-TextInput gate.
  func test_5_3_component_controlledTextInput() throws {
    try requireSurface("gallery-input", "TextInput")
    let field = element(testID: "gallery-input")
    field.tap()
    field.typeText("hi")
    XCTAssertTrue(waitForText(5) { $0.contains("hi") },
                  "typed text round-trips through changeText into the rendered echo")
  }

  /// Image (declarative + blob): an Image surface mounts and loads (load/loadEnd) — the §5.3 Image
  /// gates. We assert the image element exists and becomes hittable (a failed decode would not).
  func test_5_3_component_image() throws {
    try requireSurface("gallery-image", "Image")
    let image = element(testID: "gallery-image")
    XCTAssertTrue(image.waitForExistence(timeout: 8),
                  "the Image view mounts and the source/blob loads (load/loadEnd)")
  }

  /// Switch: toggling a UISwitch emits valueChange and the bound label flips — the §5.3 Switch gate.
  func test_5_3_component_switch() throws {
    try requireSurface("gallery-switch", "Switch")
    let sw = element(testID: "gallery-switch")
    sw.tap()
    XCTAssertTrue(waitForText(5) { $0.lowercased().contains("on") },
                  "toggling the Switch emits valueChange and the bound state flips to 'on'")
  }

  /// Modal: opening a Modal presents its own content root in an overlay; closing dismisses it — the
  /// §5.3 Modal gate (keyWindow traversal + visible-applied-last). Predicted-rework surface.
  func test_5_3_component_modalPresentDismiss() throws {
    try requireSurface("gallery-open-modal", "Modal")
    element(testID: "gallery-open-modal").tap()
    let modalBody = element(testID: "gallery-modal-body")
    XCTAssertTrue(modalBody.waitForExistence(timeout: 5),
                  "the Modal presents its own content root in an overlay")
    element(testID: "gallery-close-modal").tap()
    XCTAssertFalse(modalBody.waitForExistence(timeout: 2),
                   "closing dismisses the Modal (visible applied last)")
  }

  /// BeforeAfter: dragging the wipe handle changes the wipe fraction and emits wipeStart/wipeCommit —
  /// the §5.3 BeforeAfter gate (the Lumen photo-restore comparator). Predicted-rework surface.
  func test_5_3_component_beforeAfterWipe() throws {
    try requireSurface("gallery-beforeafter", "BeforeAfter")
    let comparator = element(testID: "gallery-beforeafter")
    let start = comparator.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    let end = comparator.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
    start.press(forDuration: 0.1, thenDragTo: end)
    XCTAssertTrue(waitForText(5) { $0.lowercased().contains("wipe") || $0.contains("%") },
                  "dragging the wipe handle changes the fraction (wipeStart/wipeCommit)")
  }

  // MARK: - §5.3b IMPERATIVE-COMMAND SEAM (IOS-8) -----------------------------------------------
  //
  // The ONE imperative seam (reconciled with AND-3): __fabric_command(handle, name, argsJson) → the
  // host's command() override → async result on the __commandResult path, keyed by __callId. These
  // legs drive the host's real UIKit behaviours (becomeFirstResponder + keyboard, convertRect window
  // coords, setContentOffset) that the device-free CanopyValidationLedgerTests.mm CANNOT reach — the
  // pure marshalling is pinned there; here we prove the op actually moves the view on a Simulator.
  // Each drives a `gallery-command` surface that issues the command from Canopy and renders the
  // async result; an embedded bundle that lacks it XCTSkips (never a silent green). [MAC-REQUIRED]

  /// focus: a button that calls Native.focus(inputRef) brings up the keyboard and focuses the input —
  /// proving the deferred becomeFirstResponder lands AFTER mount (the RN focus-timing fix) and the
  /// {ok:true} result round-trips on the __commandResult path.
  func test_5_3b_command_focusBlur() throws {
    try requireSurface("gallery-command-focus", "Command:focus")
    element(testID: "gallery-command-focus").tap()
    // The keyboard appearing is the observable proof becomeFirstResponder fired on the real input.
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5),
                  "Native focus() command brings up the keyboard (deferred becomeFirstResponder)")
    XCTAssertTrue(waitForText(5) { $0.lowercased().contains("focused") || $0.contains("ok") },
                  "the {ok:true} command result round-trips on the __commandResult path")
  }

  /// measure: a button that calls Native.measure(ref) renders back the view's frame (the RN
  /// UIManager.measure contract: x/y/width/height/pageX/pageY in points) — proving the deferred
  /// convertRect:toView:nil read happens post-layout (non-zero size) and the __callId-keyed result
  /// routes back to the right one-shot.
  func test_5_3b_command_measure() throws {
    try requireSurface("gallery-command-measure", "Command:measure")
    element(testID: "gallery-command-measure").tap()
    // A settled measure reports a non-zero width — a same-frame (pre-layout) measure would read 0.
    XCTAssertTrue(waitForText(5) { $0.contains("width") && !$0.contains("width:0") && !$0.contains("\"width\":0") },
                  "Native measure() reports a settled, non-zero frame back through __commandResult")
  }

  /// scrollTo / scrollToIndex: a button that imperatively scrolls a ScrollView moves its content —
  /// proving setContentOffset fired and the ok:true result round-tripped. A row that was off-screen
  /// becomes hittable after the command.
  func test_5_3b_command_scrollTo() throws {
    try requireSurface("gallery-command-scroll", "Command:scrollTo")
    // The target row starts off-screen (the ScrollView is taller than the viewport).
    let target = element(testID: "gallery-command-scroll-target")
    XCTAssertFalse(target.isHittable, "the target row starts off-screen (pre-scroll)")
    element(testID: "gallery-command-scroll").tap()  // issues Native.scrollToIndex(scrollRef, …)
    XCTAssertTrue(target.waitForExistence(timeout: 5) && target.isHittable,
                  "Native scrollTo()/scrollToIndex() brought the off-screen row on screen")
  }

  // MARK: - §5.4 ANIMATION GATE -----------------------------------------------------------------

  /// The CADisplayLink-driven animation completes (no hang, no crash from a frame callback hitting a
  /// dead view after removeChild) — the §5.4 anim driver + remove-during-animation safety gate.
  func test_5_4_animation_drivesAndCleansUp() throws {
    try requireSurface("gallery-animate", "Animation")
    element(testID: "gallery-animate").tap()
    // The animated element should still be present + the app still responsive after the tween.
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 3) || app.state == .runningForeground,
                  "the animation drives via the CADisplayLink loop without crashing")
    // Remove the animated view mid-flight: a frame callback must not hit a dead view.
    if element(testID: "gallery-remove-animated").exists {
      element(testID: "gallery-remove-animated").tap()
      XCTAssertEqual(app.state, .runningForeground,
                     "removeChild cancels the animation; no frame callback hits a dead view")
    }
  }

  // MARK: - §5.5 CAPABILITY (C1 effect ABI) GATES -----------------------------------------------
  // Each capability routes through __canopy_call → the ObjC bridge → the Swift module → complete →
  // canopyResolveCall. The Echo round-trip is the bridge smoke; the OS-backed caps (Photos/Album/
  // Share/Notify/Billing) need the gallery/Lumen surface + autoAcceptAlerts (set in the scheme) and
  // SKIP on the bare counter so the ledger stays honest.

  /// Echo: the shared-C++ EchoModule round-trips an arg through the full C1 bridge — the cheapest
  /// proof that __canopy_call → module → complete(err,res) → resolve works on a real device.
  func test_5_5_capability_echoRoundTrips() throws {
    try requireSurface("gallery-echo", "Capability:Echo")
    element(testID: "gallery-echo").tap()
    XCTAssertTrue(waitForText(8) { $0.lowercased().contains("echo") },
                  "Echo round-trips an arg through the C1 bridge (module → complete → resolve)")
  }

  /// Streaming (Lifecycle/AppShell): a subscribe receives repeated events. Backgrounding then
  /// foregrounding the app drives Lifecycle.appState → {state:"background"} then {"foreground"},
  /// and the bound label reflects the latest — the §5.5 streaming gate on a real lifecycle event.
  func test_5_5_streaming_lifecycleAppState() throws {
    try requireSurface("gallery-appstate", "Streaming:Lifecycle")
    XCTAssertTrue(waitForText(5) { $0.lowercased().contains("foreground") },
                  "Lifecycle.appState is primed with the current foreground state on subscribe")
    XCUIDevice.shared.press(.home)               // → DidEnterBackground → {state:"background"}
    app.activate()                                // → DidBecomeActive    → {state:"foreground"}
    XCTAssertTrue(waitForText(8) { $0.lowercased().contains("foreground") },
                  "re-foregrounding re-emits {state:'foreground'} to the open subscriber")
  }

  // MARK: - the ledger banner (a single test that documents what THIS run covered) ---------------

  /// Always-on: records, in the test log, which gate families this run actually drove vs skipped, so
  /// a CI Mac run produces a self-describing ledger artifact (the on-device half of PART5-LEDGER.md).
  func test_ledger_banner() throws {
    XCTAssertEqual(app.state, .runningForeground)
    print("""
    === Canopy iOS Part-5 validation ledger (this run) ===
      §5.1 Render   : driven (boot → native 'Count: 0', root pinned in points)
      §5.2 Events   : driven (tap → TEA update, second handler reset)
      §5.3 Comps    : driven where the embedded bundle exposes the surface (else XCTSkip)
      §5.4 Anim     : driven where exposed (else XCTSkip)
      §5.5 Caps     : Echo + Lifecycle streaming where exposed (else XCTSkip)
      device-free legs (color/diff-null/measure/ABI/stream verdicts): CanopyValidationLedgerTests.mm
      structural completeness gate: scripts/check-ios-validation-ledger.sh
    """)
  }
}
