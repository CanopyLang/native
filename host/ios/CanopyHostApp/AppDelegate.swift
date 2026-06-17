// AppDelegate.swift — the UIApplication shell for the Canopy iOS host (contract §3.6).
//
// Minimal application lifecycle owner. The real work lives in CanopyHostViewController
// (Objective-C++, exposed to Swift via the bridging header): it boots Hermes, installs the
// __fabric_* render seam + the __canopy_* effect ABI, evaluates canopy.bundle.js, and runs
// the program. This file just hands the scene system a configuration; SceneDelegate stands
// up the window + the host view controller.
//
// On iOS 13+ window/scene lifecycle is owned by SceneDelegate; AppDelegate retains only the
// process-level hooks (launch, scene-session vending). Capability modules that need
// app-level notifications (Lifecycle's UIApplication.didBecomeActive/willResignActive,
// Notify's UNUserNotificationCenter) observe NSNotification / UNUserNotificationCenter
// directly and do not require wiring here.

import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    // REL-2: install the process-level crash floor FIRST (before any scene/Hermes work) so an uncaught
    // NSException anywhere — including during boot — is recorded (buildId-keyed) and the prior handler
    // chained. Then surface any record a prior-run crash left. Both are no-ops on a clean run.
    CanopyCrashFloorInstall()
    _ = CanopyCrashFloorDrainPending()
    // Hermes boot happens in CanopyHostViewController.viewDidLoad once the scene installs it.
    return true
  }

  // MARK: - Scene lifecycle

  func application(
    _ application: UIApplication,
    configurationForConnecting connectingSceneSession: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    let config = UISceneConfiguration(name: "Default Configuration",
                                      sessionRole: connectingSceneSession.role)
    config.delegateClass = SceneDelegate.self
    return config
  }

  func application(
    _ application: UIApplication,
    didDiscardSceneSessions sceneSessions: Set<UISceneSession>
  ) {}
}
