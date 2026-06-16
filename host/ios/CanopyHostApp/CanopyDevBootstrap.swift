// CanopyDevBootstrap.swift — DEV-12: the debug-only auto-start for the iOS dev-loop WS client.
//
// The iOS twin of Android's CanopyDevBootstrap.java. On Android a zero-row ContentProvider kicks the
// dev client off at process boot with no edit to the production Application/Activity. iOS has no such
// pre-launch provider hook, so the equivalent seam is the scene-connect callback: SceneDelegate calls
// CanopyDevBootstrap.start() right after it installs the host view controller (the window root the
// dev client reloads). The whole thing is #if DEBUG so it (and any reference to CanopyDevClient) is
// gone from a release build — exactly like the Android client living in src/debug.
//
// The dev-server endpoint (host:port) is resolved, in priority order, from:
//   1. the CANOPY_DEV_HOST process ENVIRONMENT variable  (Xcode scheme env / `canopy-native run`)
//   2. the CANOPY_DEV_HOST key in Info.plist              (baked by `canopy-native run`)
//   3. nil → CanopyDevClient's built-in 127.0.0.1:8099 default (the Simulator shares the Mac loopback)
// so a plain run against the Simulator needs no configuration, while a LAN device overrides via the
// scheme env or the Info.plist key.

import Foundation

enum CanopyDevBootstrap {

  #if DEBUG
  // Held so the socket + its reconnect loop outlive the scene-connect call. One per process.
  private static var client: CanopyDevClient?
  #endif

  /// Start the dev client (debug builds only). Idempotent: a second call is ignored. A failure is
  /// swallowed (a dev-tooling problem must never block app boot — mirrors the Android catch).
  static func start() {
    #if DEBUG
    guard client == nil else { return }
    client = CanopyDevClient.start(withDevHost: resolveDevHost())
    #endif
  }

  #if DEBUG
  /// Resolve CANOPY_DEV_HOST: process env → Info.plist → nil (CanopyDevClient then falls back to its
  /// built-in 127.0.0.1:8099 default). Mirrors CanopyDevBootstrap.resolveDevHost (Android).
  private static func resolveDevHost() -> String? {
    if let env = ProcessInfo.processInfo.environment["CANOPY_DEV_HOST"], !env.isEmpty {
      return env
    }
    if let plist = Bundle.main.object(forInfoDictionaryKey: "CANOPY_DEV_HOST") as? String,
       !plist.isEmpty {
      return plist
    }
    return nil
  }
  #endif
}
