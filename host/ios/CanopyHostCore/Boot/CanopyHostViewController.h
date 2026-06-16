// CanopyHostViewController.h — the iOS boot entry point (contract §3.1).
//
// A UIViewController that owns the Hermes jsi::Runtime, the Fabric host, and the module
// host, and drives the boot sequence (contract §3.2). The app's SceneDelegate sets an
// instance of this as the window's rootViewController (contract §3.6); its `view` is the
// surface every __fabric_* mount call draws into.
//
// The public surface is deliberately empty: everything (the held runtime, the host, the
// registry) is a private C++ member of the .mm so no Hermes/Yoga header leaks to Swift.
// Swift sees only a UIViewController.

#pragma once

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The native entry point for a canopy/native app. Boots Hermes, installs the __fabric_*
/// render seam + the __canopy_* effect ABI, evaluates `canopy.bundle.js`, and runs the
/// program against this controller's view. No React, no WebView.
///
/// Created and installed as the window root by SceneDelegate. The status-bar style is
/// driven by the AppShell capability via -setHostStatusBarStyle: (contract §3.6).
@interface CanopyHostViewController : UIViewController

/// Drive the status bar style from the AppShell capability (Author E). Updates
/// `preferredStatusBarStyle` and triggers -setNeedsStatusBarAppearanceUpdate. Safe to call
/// from any thread (it hops to the main queue internally).
- (void)setHostStatusBarStyle:(UIStatusBarStyle)style;

/// DEV-12 — the iOS in-process, state-preserving reload (the analogue of Android's
/// CanopyHost.reload → CanopyHostJni nativeReload). Re-evaluates `bundleJs` on the SAME held
/// Hermes runtime and re-boots onto the SAME cached root, preserving the host view tree (only
/// the program's mounted subtree is rebuilt) and the user's TEA model (captured before the eval,
/// restored after the re-boot) via the DEV-2 reload seam published by external/native.js
/// (__canopy_captureState / __canopy_teardown / __canopy_remount). Replaces a cold relaunch
/// (multi-second, total state loss). Safe to call from any thread — it marshals onto the main
/// queue (the JS thread for this host) where the runtime + every __fabric_* mount live. A null/
/// empty bundle is a no-op; a syntax error / throw in the NEW bundle surfaces as a dev red-box
/// (fatal: the old program is already torn down) rather than a crash. No-op in a never-booted /
/// ABI-gate-aborted runtime (a red-box explains it). Used by the debug-only CanopyDevClient.
- (void)reloadWithBundle:(NSString *)bundleJs;

/// DEV-12 — surface a dev-server BUILD error (a compile failure pushed by the dev server) as the
/// non-fatal dev red-box, leaving the last-good program up underneath (DEV-11 recovery posture).
/// Debug-only path: the CanopyDevClient calls this on an `error` frame. Safe from any thread.
- (void)showDevBuildError:(NSString *)report;

@end

NS_ASSUME_NONNULL_END
