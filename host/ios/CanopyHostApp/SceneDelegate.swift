// SceneDelegate.swift — stands up the window and the Canopy host (contract §3.6).
//
// Creates the UIWindow for a scene and installs CanopyHostViewController as its root. That
// controller's `view` is the surface every __fabric_* mount draws into; setting it as the
// window root is what gives the host a real, sized, on-screen surface (so Yoga's root
// layout runs against the device bounds, and rotation/keyboard/safe-area changes reach the
// renderer's layoutSubviews).
//
// CanopyHostViewController is Objective-C++ (CanopyHostCore/Boot/CanopyHostViewController.h),
// exposed to Swift via the bridging header (Author A owns the #import line).

import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

  var window: UIWindow?

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene else { return }

    let window = UIWindow(windowScene: windowScene)
    // The host controller boots Hermes + the Canopy program in viewDidLoad, which fires
    // when the window is made key + visible below.
    window.rootViewController = CanopyHostViewController()
    self.window = window
    window.makeKeyAndVisible()

    // DEV-12: start the debug-only dev-loop client AFTER the host view controller is the window root
    // (so a pushed reload can reach it via keyWindow.rootViewController). A no-op in a release build
    // (the whole client is compiled out) and when no dev server / CANOPY_DEV_HOST is configured.
    CanopyDevBootstrap.start()
  }

  // Lifecycle transitions are observed directly by the Lifecycle/AppShell capability modules
  // (UIApplication.didBecomeActiveNotification / willResignActiveNotification), so no extra
  // wiring is needed here.
  func sceneDidDisconnect(_ scene: UIScene) {}
  func sceneDidBecomeActive(_ scene: UIScene) {}
  func sceneWillResignActive(_ scene: UIScene) {}
  func sceneWillEnterForeground(_ scene: UIScene) {}
  func sceneDidEnterBackground(_ scene: UIScene) {}
}
