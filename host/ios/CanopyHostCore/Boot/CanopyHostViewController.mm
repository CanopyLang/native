// CanopyHostViewController.mm — the iOS boot flow (contract §3.1, §3.2, §3.4).
//
// Owns the held Hermes jsi::Runtime, the Fabric host, and the module host, and runs the
// boot sequence: create runtime → install __fabric_* + __canopy_* → eval canopy.bundle.js
// → __canopy_boot. This is the whole native entry point for a canopy/native app — no
// React, no WebView. The iOS analog of Android's CanopyHostJni.cpp boot flow.
//
// THE RUNTIME-POINTER GAP, CLOSED (contract §3.4). The stub's CanopyHostIOS had no
// jsi::Runtime*, so setEvents/gestures could never call canopyEmitEvent. Fix: the held
// runtime is owned HERE; we build a CanopyEmitFn (makeEmitClosure) that captures it and
// emits on the main queue, and hand that closure to the host at construction
// (CanopyHostMake(surface, emit), §5.1). Every interactive surface emits through that
// closure; only this closure ever calls canopy::canopyEmitEvent (contract §6.9). The host
// never sees Hermes.
//
// THREADING (contract §0.2): the JS thread IS the main thread for the direct-views host —
// every __fabric_* mount touches UIKit (main-only). So the runtime is created + evaluated
// here on the main queue, and postToJs = dispatch_async(main). All event emits and module
// resolves re-enter the runtime only on the main queue.

#import "CanopyHostViewController.h"
#import "CanopyModuleHost.h"

#import <UIKit/UIKit.h>
#import <os/log.h>

#import <hermes/hermes.h>             // facebook::hermes::makeHermesRuntime

#include <exception>
#include <memory>
#include <string>

// Author C's iOS render header: declares canopy::CanopyEmitFn (§6.1) and the factory
// canopy::CanopyHostMake(UIView*, CanopyEmitFn) (§6.2), and transitively includes the
// portable CanopyFabric.h (CanopyHost, installCanopyFabric, canopyEmitEvent, canopyBoot).
// This is the B↔C handoff (§7.1): B constructs `emit` from the held runtime; C stores it.
#include "../Render/CanopyHostFabric.h"

// The host→AppShell appearance seam: iOS delivers a light/dark flip ONLY through a trait
// environment, so this VC re-broadcasts it on an app-wide notification the AppShell capability
// observes for its `colorScheme` stream (CanopyHostAppearance.h).
#import "../Bridge/CanopyHostAppearance.h"

using namespace facebook;

namespace {

os_log_t CanopyBootLog() {
  static os_log_t log = os_log_create("com.canopyhost.canopy", "CanopyBoot");
  return log;
}

// Build the emit closure that closes the runtime-pointer gap (contract §3.4). It captures
// the held runtime and emits on the MAIN QUEUE. All of Author D's event sources (taps,
// pan, text, switch) fire on the main thread already, so the common path calls straight
// through; the dispatch_async guard makes it correct even if some future source fires
// off-main. Only this closure touches the runtime for events.
canopy::CanopyEmitFn makeEmitClosure(jsi::Runtime* rt) {
  return [rt](canopy::Handle h, const std::string& name, const std::string& payloadJson) {
    auto emit = [rt, h, name, payloadJson]() {
      if (rt == nullptr) return;
      try {
        canopy::canopyEmitEvent(*rt, h, name, payloadJson);
      } catch (jsi::JSError& err) {
        // A throw inside the app's update (the press/gesture handler) becomes a logged
        // surface, not a SIGABRT (contract §3.2 red-box posture).
        os_log_error(CanopyBootLog(), "canopy: event '%{public}s' threw: %{public}s",
                     name.c_str(), err.getMessage().c_str());
      } catch (const std::exception& ex) {
        os_log_error(CanopyBootLog(), "canopy: event '%{public}s' native error: %{public}s",
                     name.c_str(), ex.what());
      } catch (...) {
        os_log_error(CanopyBootLog(), "canopy: event '%{public}s' unknown error", name.c_str());
      }
    };
    if (NSThread.isMainThread) {
      emit();
    } else {
      dispatch_async(dispatch_get_main_queue(), ^{ emit(); });
    }
  };
}

}  // namespace

// =======================================================================================

@implementation CanopyHostViewController {
  std::unique_ptr<jsi::Runtime>            _runtime;     // THE held runtime (main-queue only)
  std::shared_ptr<canopy::CanopyHost>      _host;        // the Fabric mount surface (Author C)
  CanopyModuleHost*                        _moduleHost;  // owns the registry (contract §3.3)
  canopy::Handle                           _rootTag;
  BOOL                                     _booted;
  UIStatusBarStyle                         _statusBarStyle;
}

- (instancetype)initWithNibName:(nullable NSString*)nibNameOrNil
                         bundle:(nullable NSBundle*)nibBundleOrNil {
  if ((self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil])) {
    _rootTag = -1;
    _booted = NO;
    _statusBarStyle = UIStatusBarStyleDefault;
  }
  return self;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = [UIColor blackColor];
  [self bootCanopy];
}

// ---- the boot sequence (contract §3.2), all on the main queue --------------------------

- (void)bootCanopy {
  if (_booted) return;
  _booted = YES;

  // 1. Create the JS engine on the main queue (which is the JS thread for this host).
  // Fully qualified: with `using namespace facebook;` active and the real Hermes headers (which
  // ALSO declare a top-level ::hermes VM namespace), a bare `hermes::` is ambiguous and clang
  // rejects it. The Android sibling (CanopyHostJni.cpp) qualifies for the same reason.
  _runtime = facebook::hermes::makeHermesRuntime();

  // 2. Build the emit closure (closes the runtime-pointer gap, §3.4) and construct the host
  //    WITH it. The host stores emit_ and threads it to every interactive view; it never
  //    holds a jsi::Runtime* (contract §5.1). CanopyHostMake is Author C's factory.
  canopy::CanopyEmitFn emit = makeEmitClosure(_runtime.get());
  _host = canopy::CanopyHostMake(self.view, emit);

  // 3. Install the __fabric_* render seam backed by the host.
  canopy::installCanopyFabric(*_runtime, _host);

  // 4. Construct the module host with the held runtime + the main-queue postToJs hop, then
  //    install the __canopy_* effect ABI (installCanopyModules + registry wiring). The hop
  //    is what lets a capability finish on any GCD queue and re-enter the runtime safely.
  _moduleHost = [[CanopyModuleHost alloc]
      initWithRuntime:_runtime.get()
             postToJs:[](std::function<void()> fn) {
               dispatch_async(dispatch_get_main_queue(), ^{ fn(); });
             }];
  [_moduleHost installInto:*_runtime];

  // 5. Polyfill `console` (bare Hermes has none; the bundle references it). Before eval.
  [_moduleHost installConsolePolyfill:*_runtime];

  // 6. Register every capability NativeModule (Echo + bridge modules + Core ML) and hand
  //    the Core ML model path to the inference module (contract §3.5).
  [_moduleHost registerAll];

  // 7-9. Guarded: a bundle syntax error, a missing __canopy_boot, or a throw in the first
  //      synchronous view(model) becomes a logged red-box surface, not a SIGABRT — there is
  //      no running program to recover into, so this is fatal-but-survivable (§3.2).
  [self guardedBoot];
}

- (void)guardedBoot {
  try {
    // 7. Evaluate the compiled bundle (defines globalThis.__canopy_boot + the program).
    NSString* src = [self loadBundleSource];
    if (src == nil) {
      os_log_fault(CanopyBootLog(),
                   "canopy: canopy.bundle.js not found in app bundle — nothing to boot");
      return;
    }
    _runtime->evaluateJavaScript(
        std::make_shared<jsi::StringBuffer>(std::string(src.UTF8String)),
        "canopy.bundle.js");

    // 8. Create the root surface view and mount it.
    _rootTag = _host->createView("RCTRootView", "{\"style\":{\"flex\":\"1\"}}");

    // 9. Boot the program against the root. It then drives the whole tree through __fabric_*
    //    and emits events back through emit_ (the closure from step 2).
    canopy::canopyBoot(*_runtime, _rootTag, "{}");
  } catch (jsi::JSError& err) {
    [self reportFatal:[NSString stringWithFormat:@"boot: %s", err.getMessage().c_str()]
                stack:[NSString stringWithUTF8String:err.getStack().c_str()]];
  } catch (const std::exception& ex) {
    [self reportFatal:[NSString stringWithFormat:@"boot (native): %s", ex.what()] stack:nil];
  } catch (...) {
    [self reportFatal:@"boot (unknown native exception)" stack:nil];
  }
}

- (nullable NSString*)loadBundleSource {
  NSBundle* bundle = [NSBundle mainBundle];
  NSString* path = [bundle pathForResource:@"canopy.bundle" ofType:@"js"];
  if (path == nil) return nil;
  NSError* err = nil;
  NSString* src = [NSString stringWithContentsOfFile:path
                                            encoding:NSUTF8StringEncoding
                                               error:&err];
  if (src == nil) {
    os_log_error(CanopyBootLog(), "canopy: failed to read canopy.bundle.js: %{public}s",
                 err.localizedDescription.UTF8String);
  }
  return src;
}

// Surface a fatal boot error. A production host renders an on-screen red box; here we log
// loudly and tint the surface so a blank-screen boot failure is visibly diagnosable rather
// than a silent crash.
- (void)reportFatal:(NSString*)message stack:(nullable NSString*)stack {
  os_log_fault(CanopyBootLog(), "canopy red-box: %{public}s\n%{public}s",
               message.UTF8String, stack ? stack.UTF8String : "");
  dispatch_async(dispatch_get_main_queue(), ^{
    self.view.backgroundColor = [UIColor colorWithRed:0.55 green:0.0 blue:0.0 alpha:1.0];
  });
}

// ---- status bar (driven by AppShell, contract §3.6) -----------------------------------

- (void)setHostStatusBarStyle:(UIStatusBarStyle)style {
  dispatch_async(dispatch_get_main_queue(), ^{
    self->_statusBarStyle = style;
    [self setNeedsStatusBarAppearanceUpdate];
  });
}

- (UIStatusBarStyle)preferredStatusBarStyle {
  return _statusBarStyle;
}

// ---- color-scheme re-broadcast (drives AppShell's colorScheme stream, contract §3.6) --------

// iOS has no global light/dark notification — the system delivers the flip ONLY through this
// trait environment. We detect a userInterfaceStyle change and re-broadcast it app-wide so the
// AppShell capability (which cannot see this VC) can emit on its `colorScheme` channel. The
// Android parallel is AppShellModule's ComponentCallbacks.onConfigurationChanged uiMode hook.
//
// -traitCollectionDidChange: is soft-deprecated on iOS 17 (in favour of -registerForTraitChanges,
// which is iOS 17-only) but remains the single API that works from the iOS 15 deployment floor
// up; the deprecation is a warning, not an error (no -Werror in the build).
- (void)traitCollectionDidChange:(nullable UITraitCollection *)previousTraitCollection {
  [super traitCollectionDidChange:previousTraitCollection];
  UIUserInterfaceStyle now = self.traitCollection.userInterfaceStyle;
  if (previousTraitCollection != nil && previousTraitCollection.userInterfaceStyle == now) {
    return;  // some other trait changed (size class, etc.) — not a light/dark flip
  }
  NSString *scheme = (now == UIUserInterfaceStyleDark) ? @"dark" : @"light";
  [NSNotificationCenter.defaultCenter
      postNotificationName:CanopyHostColorSchemeDidChangeNotification
                    object:self
                  userInfo:@{ @"scheme": scheme }];
}

@end
