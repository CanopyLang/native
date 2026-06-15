// CanopyHostAppearance.h — the host→AppShell appearance seam (iOS color-scheme bridge).
//
// WHY THIS EXISTS: Android observes light/dark via a process-level ComponentCallbacks hook on the
// app Context (AppShellModule.onConfigurationChanged uiMode). iOS has NO global notification for
// a light/dark flip — the system delivers it ONLY through a trait environment
// (UIViewController/UIView -traitCollectionDidChange:). So CanopyHostViewController is the single
// place that learns of the change, and it re-broadcasts it on this app-wide NSNotification. The
// AppShell capability (CanopyAppShellModule) observes the notification for its `colorScheme`
// stream and reads the current value via CanopyHostCurrentColorScheme() to prime a subscriber.
//
// Decoupling: the VC and AppShell share ONLY this tiny header (a notification name + a pure
// reader) — neither imports the other. UIKit-only, so it rides the bridging header cleanly.

#pragma once

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted on the MAIN thread by CanopyHostViewController when the system light/dark setting
/// changes (its -traitCollectionDidChange: detected a userInterfaceStyle flip). userInfo carries
/// the resolved value: @{ @"scheme": @"light" | @"dark" }. The Android parallel is
/// AppShellModule's ComponentCallbacks.onConfigurationChanged uiMode hook.
extern NSString *const CanopyHostColorSchemeDidChangeNotification;

/// The current system color scheme — @"light" or @"dark" — read from the foreground-active
/// window's trait collection (falling back to the main screen). Call on the main queue. Used by
/// AppShell to prime a freshly-subscribed `colorScheme` listener with the correct value at once.
NSString *CanopyHostCurrentColorScheme(void);

NS_ASSUME_NONNULL_END
