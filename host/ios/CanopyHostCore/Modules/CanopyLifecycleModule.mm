// CanopyLifecycleModule.mm — the iOS host module behind canopy/navigation's Native.Lifecycle
// (module "Lifecycle"). The iOS analog of android/.../modules/LifecycleModule.java.
//
// appState / memoryPressure / backPressed are live SUBSCRIPTIONS, so this subclasses
// CanopyStreamingModuleBase (the iOS StreamingJniModule) for per-channel sink bookkeeping,
// first-subscriber laziness, and prime-on-subscribe. One method — allowDefaultBack — is a
// one-shot Cmd. The OS event sources are UIKit notifications rather than Android's
// ProcessLifecycleOwner / onTrimMemory / OnBackPressedDispatcher.
//
// WHAT EACH CHANNEL OBSERVES (matching the Java wire shape exactly):
//   • appState       — UIApplicationDidBecomeActiveNotification -> {"state":"foreground"},
//                      UIApplicationDidEnterBackgroundNotification -> {"state":"background"}.
//                      Primed on subscribe from UIApplication.applicationState. (Android maps
//                      ProcessLifecycleOwner ON_START/ON_STOP to the same two states.)
//   • memoryPressure — UIApplicationDidReceiveMemoryWarningNotification -> {"level":"critical"}.
//                      iOS surfaces a SINGLE memory-warning signal — there is no
//                      moderate/low/critical ladder like Android's onTrimMemory — so it maps to
//                      the strongest bucket (free memory now). No prime (no "current" pressure).
//   • backPressed    — iOS has NO hardware/gesture back EVENT delivered to the app (the swipe-
//                      back is a navigation-controller gesture, not a global intercept). So this
//                      channel never emits on iOS. It stays subscribable so cross-platform .can
//                      navigation code compiles and runs unchanged; on iOS back is driven by the
//                      app's own NavStack UI instead. (Android: OnBackPressedDispatcher intercept.)
//
// One-shot:
//   • allowDefaultBack {} -> null. On Android this yields the intercepted back to the system; on
//     iOS there is nothing to yield, so it is a benign no-op that resolves null — keeping shared
//     navigation code correct on both platforms.
//
// SUBSCRIBE LAZINESS / IDEMPOTENCE (mirrors the Java guards): the base calls
// -onFirstSubscriber: the first time a channel gains a subscriber; we add the UIKit observer
// then, guarded by a per-channel BOOL so a drop+re-subscribe never double-registers. Observers
// are process-cheap and never removed on unsubscribe (matching the Java module); -dealloc clears
// them defensively (the module is process-lived, so this rarely runs).
//
// THREADING: the UIApplication notifications fire on the MAIN thread; -emitOnChannel:event: is
// safe from any thread (each sink hops to the JS thread via the registry postToJs). The base
// invokes -onFirstSubscriber: on the JS/main thread, so adding observers there is main-safe.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "CanopyStreamingModuleBase.h"
#import "CanopyModuleSupport.h"

@interface CanopyLifecycleModule : CanopyStreamingModuleBase
@end

@implementation CanopyLifecycleModule {
  BOOL _appStateObserved;
  BOOL _memoryObserved;
}

- (void)registerHandlers {
  // Streaming channels: observation begins lazily in -onFirstSubscriber:; the per-subscribe
  // handler has nothing to do (the base already recorded the sink + primed the last value).
  // A handler must still be REGISTERED so the method is known — an unregistered method makes
  // -invokeMethod: return NO (→ ModuleNotFound). Hence the no-op handlers.
  CanopyMethodHandler noop = ^(NSString *args, NSString *callId, CanopyComplete complete) {};
  [self onMethod:@"appState" handler:noop];
  [self onMethod:@"memoryPressure" handler:noop];
  [self onMethod:@"backPressed" handler:noop];

  // One-shot: no hardware/gesture back to yield on iOS — resolve null (keeps shared .can
  // navigation that calls allowDefaultBack on Android correct here).
  [self onMethod:@"allowDefaultBack"
         handler:^(NSString *args, NSString *callId, CanopyComplete complete) {
           CanopyResolveNull(complete);
         }];
}

- (void)onFirstSubscriber:(NSString *)channel args:(NSString *)argsJson {
  if ([channel isEqualToString:@"appState"]) {
    if (!_appStateObserved) {
      _appStateObserved = YES;
      NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
      [nc addObserver:self
             selector:@selector(onDidBecomeActive)
                 name:UIApplicationDidBecomeActiveNotification
               object:nil];
      [nc addObserver:self
             selector:@selector(onDidEnterBackground)
                 name:UIApplicationDidEnterBackgroundNotification
               object:nil];
    }
    // Prime the current state so a fresh subscriber is correct at once (an app is normally active
    // when it first subscribes). UIApplication.applicationState must be read on the main thread —
    // -onFirstSubscriber: runs on the JS/main thread, so this is safe.
    UIApplicationState state = UIApplication.sharedApplication.applicationState;
    [self emitOnChannel:@"appState"
                  event:(state == UIApplicationStateBackground ? @"{\"state\":\"background\"}"
                                                               : @"{\"state\":\"foreground\"}")];
  } else if ([channel isEqualToString:@"memoryPressure"]) {
    if (!_memoryObserved) {
      _memoryObserved = YES;
      [NSNotificationCenter.defaultCenter
          addObserver:self
             selector:@selector(onMemoryWarning)
                 name:UIApplicationDidReceiveMemoryWarningNotification
               object:nil];
    }
    // No prime: there is no "current" memory-pressure value to report.
  }
  // backPressed: nothing to observe on iOS — see the file header.
}

- (void)onDidBecomeActive {
  [self emitOnChannel:@"appState" event:@"{\"state\":\"foreground\"}"];
}

- (void)onDidEnterBackground {
  [self emitOnChannel:@"appState" event:@"{\"state\":\"background\"}"];
}

- (void)onMemoryWarning {
  [self emitOnChannel:@"memoryPressure" event:@"{\"level\":\"critical\"}"];
}

- (void)dealloc {
  [NSNotificationCenter.defaultCenter removeObserver:self];
}

@end
