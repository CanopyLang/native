// CanopyAppShellModule.mm — the iOS host module behind canopy/navigation's Native.AppShell
// (module "AppShell"). The iOS analog of android/.../modules/AppShellModule.java. Two surfaces:
//   • setStatusBarStyle — one-shot Cmd: set the status-bar icon contrast on the host window.
//   • colorScheme       — streaming Sub: the system light/dark setting.
//
// colorScheme is delivered through CanopyHostViewController's trait environment (iOS has no
// global light/dark notification — see CanopyHostAppearance.h): the VC re-broadcasts a flip on
// CanopyHostColorSchemeDidChangeNotification, which we observe; the current value is read via
// CanopyHostCurrentColorScheme() to prime a fresh subscriber. This subclasses
// CanopyStreamingModuleBase for the per-channel sink bookkeeping (the iOS StreamingJniModule).
//
// setStatusBarStyle maps the Canopy CONTENT-contrast vocabulary to UIStatusBarStyle and drives
// it through the host VC's -setHostStatusBarStyle: (which updates -preferredStatusBarStyle and
// calls -setNeedsStatusBarAppearanceUpdate). "light" => light CONTENT (white icons, for a dark
// bar) => UIStatusBarStyleLightContent; "dark" => dark content (black icons) =>
// UIStatusBarStyleDarkContent — exactly the Android APPEARANCE_LIGHT_STATUS_BARS inversion.
//
// THREADING: window/VC reads and the status-bar update run on the main queue;
// -emitOnChannel:event: is safe from any thread. The trait notification is posted on main.
//
// Wire contract (must match appshell.js / Native.AppShell.can and AppShellModule.java):
//   setStatusBarStyle (one-shot) {"style":"light"|"dark"} -> null
//   colorScheme       (stream)                            -> {"scheme":"light"|"dark"}

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "CanopyStreamingModuleBase.h"
#import "CanopyModuleSupport.h"
#import "../Bridge/CanopyHostAppearance.h"
#import "../Boot/CanopyHostViewController.h"

// The host view controller (the window root installed by SceneDelegate), or nil if the window is
// currently presenting something else as root. Read on the main queue (touches connectedScenes /
// keyWindow). Used to drive -setHostStatusBarStyle:.
static CanopyHostViewController *CanopyAppShellHostVC(void) {
  UIViewController *root = nil;
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:[UIWindowScene class]]) { continue; }
    UIWindowScene *windowScene = (UIWindowScene *)scene;
    UIWindow *window = windowScene.keyWindow ?: windowScene.windows.firstObject;
    if (window.rootViewController != nil) {
      root = window.rootViewController;
      if (scene.activationState == UISceneActivationStateForegroundActive) { break; }
    }
  }
  return [root isKindOfClass:[CanopyHostViewController class]] ? (CanopyHostViewController *)root
                                                              : nil;
}

@interface CanopyAppShellModule : CanopyStreamingModuleBase
@end

@implementation CanopyAppShellModule {
  BOOL _colorSchemeObserved;
}

- (void)registerHandlers {
  // Streaming channel: a no-op per-subscribe handler (observation begins in -onFirstSubscriber:).
  [self onMethod:@"colorScheme"
         handler:^(NSString *args, NSString *callId, CanopyComplete complete) {}];

  __weak __typeof__(self) weakSelf = self;
  [self onMethod:@"setStatusBarStyle"
         handler:^(NSString *args, NSString *callId, CanopyComplete complete) {
           [weakSelf handleSetStatusBarStyle:args complete:complete];
         }];
}

- (void)onFirstSubscriber:(NSString *)channel args:(NSString *)argsJson {
  if ([channel isEqualToString:@"colorScheme"]) {
    if (!_colorSchemeObserved) {
      _colorSchemeObserved = YES;
      [NSNotificationCenter.defaultCenter addObserver:self
                                             selector:@selector(onColorSchemeChanged:)
                                                 name:CanopyHostColorSchemeDidChangeNotification
                                               object:nil];
    }
    // Prime the current scheme so a fresh subscriber is correct immediately.
    [self emitScheme:CanopyHostCurrentColorScheme()];
  }
}

- (void)onColorSchemeChanged:(NSNotification *)note {
  NSString *scheme = note.userInfo[@"scheme"];
  if (![scheme isKindOfClass:[NSString class]]) { scheme = CanopyHostCurrentColorScheme(); }
  [self emitScheme:scheme];
}

- (void)emitScheme:(NSString *)scheme {
  NSString *safe = [scheme isEqualToString:@"dark"] ? @"dark" : @"light";
  [self emitOnChannel:@"colorScheme"
                event:[NSString stringWithFormat:@"{\"scheme\":\"%@\"}", safe]];
}

- (void)handleSetStatusBarStyle:(NSString *)argsJson complete:(CanopyComplete)complete {
  NSDictionary *args = CanopyParseArgs(argsJson);
  NSString *style = [args[@"style"] isKindOfClass:[NSString class]] ? args[@"style"] : @"dark";
  UIStatusBarStyle barStyle =
      [style isEqualToString:@"light"] ? UIStatusBarStyleLightContent : UIStatusBarStyleDarkContent;

  dispatch_async(dispatch_get_main_queue(), ^{
    CanopyHostViewController *vc = CanopyAppShellHostVC();
    if (vc != nil) { [vc setHostStatusBarStyle:barStyle]; }
    CanopyResolveNull(complete);
  });
}

- (void)dealloc {
  [NSNotificationCenter.defaultCenter removeObserver:self];
}

@end
