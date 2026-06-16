// CanopyDevRedBox.h — DEV-12: the iOS dev-loop red-box overlay.
//
// The iOS twin of Android's CanopyRedBox.java (host/android/.../CanopyRedBox.java). When a build
// fails (a compile error the dev server pushes) or an in-process reload fails to apply, the host
// surfaces the error as a plain-UIKit overlay — NOT through the Canopy walker — so it survives even
// a renderer/reconciler crash. Mirrors the Android dev posture exactly:
//
//   • a build error (fatal:NO) overlays the still-running last-good tree with a Dismiss + Reload row
//     (dismissing returns to the last working program — DEV-11 recovery posture);
//   • a failed reload / fatal native error (fatal:YES) keeps the message up (there is no good tree to
//     return to) with a single Reload button.
//
// This is intentionally dependency-free UIKit (no Hermes, no JSI, no Yoga) so it carries no RN
// coupling and can be shown from any error site. It is the visible counterpart of
// CanopyHostViewController's os_log fault channel.

#pragma once

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The single dev red-box overlay. `showOnView:` collapses any prior overlay to the most recent
/// error (one overlay at a time, like the Android `current` field) and mounts a fresh one on the
/// host view. Must be called on the main thread.
@interface CanopyDevRedBox : NSObject

/// Mount the overlay on `hostView`. `title` is the bold header, `message` the one-line summary,
/// `stack` the scrollable detail (compiler report / JS stack). `fatal:NO` shows Dismiss + Reload;
/// `fatal:YES` shows Reload only (no good tree underneath to dismiss to). `reload` fires when the
/// Reload button is tapped (the dev loop re-pushes on the next save, so this is usually a no-op
/// closure). Replaces any visible overlay.
+ (void)showOnView:(UIView *)hostView
             title:(NSString *)title
           message:(nullable NSString *)message
             stack:(nullable NSString *)stack
             fatal:(BOOL)fatal
            reload:(nullable void (^)(NSString *_Nullable bundle))reload;

/// Remove the current overlay if one is up (idempotent). Main thread only.
+ (void)dismiss;

@end

NS_ASSUME_NONNULL_END
