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

@end

NS_ASSUME_NONNULL_END
