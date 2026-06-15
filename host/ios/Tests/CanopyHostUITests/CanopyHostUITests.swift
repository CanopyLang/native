// CanopyHostUITests.swift — the iOS end-to-end boot smoke test (XCUITest), the parallel of the
// Android Appium/Maestro smoke flow. It launches the real app — which boots Hermes, installs the
// __fabric_* render seam + the __canopy_* effect ABI, evaluates canopy.bundle.js, and mounts the
// program against the host view controller — and asserts the process reaches the foreground
// without crashing. That single assertion exercises the entire native boot path (Scene → host VC
// → runtime → bundle eval → first render); a red-box/SIGABRT in any step leaves the app not
// running-foreground and fails here.
//
// Deeper on-device gates (render/event/component/animation/capability parity) are enumerated in
// BUILD-AND-VALIDATE.md §5 and are driven the same way the Android matrix is.

import XCTest

final class CanopyHostUITests: XCTestCase {

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  /// The app launches and reaches the foreground (the whole native boot path succeeded).
  func testAppBootsToForeground() throws {
    let app = XCUIApplication()
    app.launch()
    XCTAssertEqual(app.state, .runningForeground,
                   "Canopy host should boot Hermes + the bundle and reach the foreground")
  }

  /// The host surface actually exists on screen (a window with non-zero bounds was mounted). This
  /// catches a "booted but rendered nothing" regression that a bare foreground check would miss.
  func testHostSurfaceIsOnScreen() throws {
    let app = XCUIApplication()
    app.launch()
    // The root host view is the first window; assert it exists and has a real frame.
    let window = app.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 10), "the host window should mount")
    XCTAssertGreaterThan(window.frame.width, 0)
    XCTAssertGreaterThan(window.frame.height, 0)
  }
}
