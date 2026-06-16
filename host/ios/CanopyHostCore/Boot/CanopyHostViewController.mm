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

// RNV-4: the Hermes engine symbol is no longer named here. The held runtime is created through the
// ONE shared factory (host/shared/cpp/CanopyHermes.{h,cpp}), the same seam the Android boot site
// uses — so a Hermes engine swap (or the move to the stable C-vtable backend once RNV-6 vendors a
// standalone Hermes) is a one-file change, not a per-platform boot edit. This .mm keeps including
// <jsi/jsi.h> (via the headers below) for the runtime it HOLDS, but never <hermes/hermes.h>.
#include "CanopyHermes.h"             // canopy::makeRuntime() — the ONE Hermes runtime factory

#include <cstdint>
#include <exception>
#include <memory>
#include <string>

// RNV-2/RNV-7: the shared Hermes ABI gate. checkHermesAbi (RNV-2) compares the LIVE Hermes
// bytecode version off the runtime we just created against the pin baked from vendor.lock.json —
// the boot-time engine canary. checkBundleBytecode (RNV-7) gates a real .hbc bundle's stamped
// bytecode-format version against that same pin BEFORE evaluation (a no-op for plain JS source).
// Pure + dependency-free (host/shared/cpp).
#include "CanopyAbiGate.h"

// RNV-2 ABI canary ONLY: HermesRuntime::getBytecodeVersion() is a STATIC on the linked engine —
// the one ABI number Hermes computes about itself. This is the iOS twin of the Android boot site's
// `#include <hermes/hermes.h>` (CanopyHostJni.cpp:18). The hermes-engine pod ships this header; it
// is the sole place this .mm names a Hermes type beyond the RNV-4 makeRuntime() seam, and it is
// frozen to the RN-coupling allowlist (scripts/check-rn-coupling.sh) exactly like the Android twin.
// The runtime FACTORY still routes through canopy::makeRuntime() (CanopyHermes.h) — this include is
// read-only provenance, never a second runtime-creation path.
#include <hermes/hermes.h>

// Author C's iOS render header: declares canopy::CanopyEmitFn (§6.1) and the factory
// canopy::CanopyHostMake(UIView*, CanopyEmitFn) (§6.2), and transitively includes the
// portable CanopyFabric.h (CanopyHost, installCanopyFabric, canopyEmitEvent, canopyBoot).
// This is the B↔C handoff (§7.1): B constructs `emit` from the held runtime; C stores it.
#include "../Render/CanopyHostFabric.h"

// The host→AppShell appearance seam: iOS delivers a light/dark flip ONLY through a trait
// environment, so this VC re-broadcasts it on an app-wide notification the AppShell capability
// observes for its `colorScheme` stream (CanopyHostAppearance.h).
#import "../Bridge/CanopyHostAppearance.h"

// DEV-12: the dev red-box overlay surfaced on a failed reload / a pushed build error. A plain-UIKit
// overlay (no Canopy walker) so it survives even a renderer crash; the debug-loop twin of Android's
// CanopyRedBox. Compiled into every variant (it is harmless UIKit), but only ever reached from the
// debug-only CanopyDevClient or a failed -reloadWithBundle:.
#import "../DevLoop/CanopyDevRedBox.h"

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
  // DEV-12 in-process reload state. guardedBoot creates the root surface ONCE and caches its handle
  // + the boot flags here; -reloadWithBundle: re-boots onto the SAME cached root with the SAME flags
  // (so the host view tree under the root + the user's TEA model survive the reload). The iOS twin of
  // CanopyHostJni.cpp's g_rootTag / g_bootFlags.
  std::string                              _bootFlags;
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

// First-light render gate (Part-5 §5.1 "root pinned full-size to surface_", IOS-5). bootCanopy runs
// in -viewDidLoad, where self.view.bounds is still the nib/zero frame — so the host's setRoot pins
// the root CanopyContainerView to a zero surface. The root already carries
// FlexibleWidth|FlexibleHeight, so UIKit GROWS it to the window size on the first real layout pass;
// this override makes that pin EXPLICIT and idempotent (and re-asserts it on rotation / safe-area /
// split-view resize): force every direct subview of the surface to track self.view.bounds, then ask
// it to re-run its Yoga relayout. We touch ONLY self.view + its subviews (public UIKit) — no
// cross-author host API — so this stays inside the Boot lane while guaranteeing the first screen is
// laid out at the real surface size, not a 0×0 boot frame. The iOS analog of Android's FrameLayout
// surface re-laying its mounted root in onLayout (MainActivity).
- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  CGRect b = self.view.bounds;
  if (CGRectIsEmpty(b)) return;  // nothing real to pin to yet
  for (UIView* sub in self.view.subviews) {
    if (!CGRectEqualToRect(sub.frame, b)) sub.frame = b;  // re-pin the mounted root to the surface
    [sub setNeedsLayout];                                  // re-run the root's Yoga calculateLayout
  }
}

// ---- the boot sequence (contract §3.2), all on the main queue --------------------------

- (void)bootCanopy {
  if (_booted) return;
  _booted = YES;

  // 1. Create the JS engine on the main queue (which is the JS thread for this host) through the
  // RNV-4 seam. canopy::makeRuntime() returns a Hermes-backed jsi::Runtime; this boot site no longer
  // names a Hermes engine symbol (the Android sibling CanopyHostJni.cpp routes through the SAME
  // factory). The active backend (C++ makeHermesRuntime, or the stable C-vtable wrapper under
  // -DCANOPY_HERMES_CABI) is chosen at compile time in CanopyHermes.cpp.
  os_log(OS_LOG_DEFAULT, "CanopyHermes: creating runtime via %{public}s",
         canopy::makeRuntimeBackendName());
  _runtime = canopy::makeRuntime();

  // 1b. RNV-2 boot-time ABI canary. Read the LIVE Hermes bytecode version off the engine we just
  //     created and compare it to the pin baked from host/vendor.lock.json (canopy::checkHermesAbi)
  //     BEFORE installing the ABI or evaluating any JS. A mismatched libhermes/Hermes.xcframework
  //     (a partial revendor, a swapped binary, an xcframework whose JSI headers drift from its
  //     libhermes) boots FINE here and then corrupts/SIGABRTs on a real device the first time a
  //     non-trivial JSI Value crosses the seam (Risk #1). This is the iOS twin of the Android boot
  //     site's enforceHermesAbiGate (CanopyHostJni.cpp). Fail-closed: a mismatch is reported LOUD
  //     (the reportFatal red-box surface) and we ABORT boot — a mismatched engine must NEVER run
  //     user JS. The same gate CI enforces headless via scripts/check-abi.sh (the [iOS] boot-site
  //     assertion proves this call can't be silently deleted).
  if (![self enforceHermesAbiGate]) {
    _runtime.reset();
    return;
  }

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
    // 7. Load the compiled bundle BYTES. RNV-7: prefer a real Hermes .hbc (canopy.bundle.hbc) and
    //    run its bytecode directly; fall back to canopy.bundle.js source. Raw bytes (NSData), not
    //    an NSString, so binary bytecode survives intact.
    NSData* src = [self loadBundleData];
    if (src == nil) {
      os_log_fault(CanopyBootLog(),
                   "canopy: neither canopy.bundle.hbc nor canopy.bundle.js found in app bundle — "
                   "nothing to boot");
      return;
    }
    std::string srcStr(reinterpret_cast<const char*>(src.bytes), src.length);

    // RNV-7: gate the bundle's bytecode version (if it is a real .hbc) against the vendored engine
    // pin BEFORE evaluating — a wrong-toolchain .hbc would otherwise be rejected by Hermes mid-eval.
    // A no-op for plain JS source. Fail LOUD (the iOS reportFatal surface) on a mismatch.
    canopy::AbiCheckResult bcGate = canopy::checkBundleBytecode(
        reinterpret_cast<const uint8_t*>(srcStr.data()), srcStr.size());
    if (!bcGate.ok) {
      [self reportFatal:[NSString stringWithUTF8String:bcGate.message.c_str()]
                  stack:@"Hermes .hbc load gate (RNV-7)"];
      return;
    }

    // 7b. Evaluate the compiled bundle (defines globalThis.__canopy_boot + the program). For an
    //     .hbc buffer Hermes detects the HBC magic and runs bytecode with no parse.
    const bool isHbc = canopy::looksLikeHermesBytecode(
        reinterpret_cast<const uint8_t*>(srcStr.data()), srcStr.size());
    _runtime->evaluateJavaScript(
        std::make_shared<jsi::StringBuffer>(srcStr),
        isHbc ? "canopy.bundle.hbc" : "canopy.bundle.js");

    // 8. Create the root surface view and mount it. Cached for the DEV-12 in-process reload, which
    //    re-boots onto this SAME handle so the host root view + surface are preserved across an edit.
    _rootTag = _host->createView("RCTRootView", "{\"style\":{\"flex\":\"1\"}}");

    // 9. Boot the program against the root. It then drives the whole tree through __fabric_*
    //    and emits events back through emit_ (the closure from step 2). Cache the flags so a reload
    //    re-boots with the SAME flags (the iOS twin of Android's g_bootFlags).
    _bootFlags = "{}";
    canopy::canopyBoot(*_runtime, _rootTag, _bootFlags);
  } catch (jsi::JSError& err) {
    [self reportFatal:[NSString stringWithFormat:@"boot: %s", err.getMessage().c_str()]
                stack:[NSString stringWithUTF8String:err.getStack().c_str()]];
  } catch (const std::exception& ex) {
    [self reportFatal:[NSString stringWithFormat:@"boot (native): %s", ex.what()] stack:nil];
  } catch (...) {
    [self reportFatal:@"boot (unknown native exception)" stack:nil];
  }
}

// ---- DEV-12 in-process, state-preserving reload ----------------------------------------
//
// The iOS half of the dev loop's edit→see cycle without a fresh process. Re-evaluates the new bundle
// on the SAME held Hermes runtime and re-boots onto the SAME cached root, preserving the host view
// tree (only the program's mounted subtree under the root is rebuilt) and the user's TEA model (the
// host half of the DEV-2 reload seam; native.js owns the JS half: __canopy_captureState /
// __canopy_teardown / __canopy_remount). This is a line-for-line port of Android's
// Java_com_canopyhost_CanopyHost_nativeReload (CanopyHostJni.cpp) onto the held _runtime — the same
// seams, the same 7-step sequence, driven device-free by harness/run-reload-seam.js.
//
// THREADING: the reload MUST run on the JS thread (which IS the main queue for this direct-views
// host, where _runtime + every __fabric_* mount live). -reloadWithBundle: marshals onto the main
// queue so a caller from any thread (the CanopyDevClient's NSURLSession delegate queue, a red-box
// "Reload" button) is safe; an already-on-main caller still dispatch_async'es (runs next turn) so
// the current frame settles first.
- (void)reloadWithBundle:(NSString *)bundleJs {
  if (bundleJs.length == 0) return;  // an empty/nil bundle is a no-op (never re-eval "")
  std::string srcStr(bundleJs.UTF8String ? bundleJs.UTF8String : "");
  dispatch_async(dispatch_get_main_queue(), ^{
    [self performReload:srcStr];
  });
}

// The reload body, on the main queue. Mirrors CanopyHostJni.cpp's nativeReload sequence exactly:
//   1. captureState() — read the live TEA model so it survives the new-bundle eval (an opaque
//      { model } carrier; null in a release bundle / never-booted runtime → a cold reload).
//   2. teardown()     — stop the running Subs (so the reload does not double-subscribe) and release
//      THIS program's mounted subtree under the cached root, leaving a clean root view.
//   3. clear globalThis.Canopy + scope.Canopy (+ the Elm alias) — the host reset: the compiler's
//      _Platform_export rejects a duplicate Canopy.Main on the same runtime, so a re-eval must clear
//      it first (DEV-4's plan note: "verify IIFE re-eval is idempotent; fall back to reboot if not").
//   4. evaluateJavaScript(newBundle) — re-eval on the SAME runtime (same modules, same console/ABI).
//      The dev loop pushes JS SOURCE (a fast edit→see cycle, no hermesc round-trip); the .hbc path is
//      the baked-asset boot in -guardedBoot.
//   5. canopyBoot(cachedRootTag, flags) — re-boot onto the SAME root handle (host view preserved).
//   6. remount(captured) — restore the captured model into the freshly-booted program (DEV-8: only
//      when the new bundle's Model type-hash matches the captured one; on a mismatch it keeps the
//      fresh init model and posts a 'Model changed' notice instead).
//   7. drain any 'Model changed' notice the remount posted (surfaced to the developer).
//
// Guarded end-to-end: a syntax error / throw in the NEW bundle becomes a dev red-box (fatal: the old
// program is already torn down, so there is no running program to fall back to), not a SIGABRT.
- (void)performReload:(const std::string&)srcStr {
  if (_runtime == nullptr || _rootTag < 0) {
    // Never booted (or a boot that aborted at the ABI gate): nothing to reload onto. A red-box
    // explains it rather than silently doing nothing.
    [self showDevRedBox:@"reload: no booted runtime to reload onto"
                  stack:@"DEV-12 in-process reload"
                  fatal:YES];
    return;
  }
  try {
    jsi::Runtime& rt = *_runtime;

    // (1) capture the live model (survives the new eval). The carrier is an opaque JS object the
    // walker minted; we hold it on the C++ stack across the eval and thread it back into remount.
    jsi::Value captured = jsi::Value::null();
    {
      jsi::Value cap = rt.global().getProperty(rt, "__canopy_captureState");
      if (cap.isObject() && cap.getObject(rt).isFunction(rt)) {
        captured = cap.getObject(rt).getFunction(rt).call(rt);
      }
    }

    // (2) tear the live program down (stop Subs + release the mounted subtree under the root).
    {
      jsi::Value td = rt.global().getProperty(rt, "__canopy_teardown");
      if (td.isObject() && td.getObject(rt).isFunction(rt)) {
        td.getObject(rt).getFunction(rt).call(rt);
      }
    }

    // (3) the host reset: clear Canopy (the canonical export target _Platform_export checks) plus the
    // Elm back-compat alias, so the re-eval's _Platform_export accepts the new Canopy.Main. We clear
    // on the global and on `scope` (the compiler exports under either depending on the IIFE shape);
    // a missing property is harmless (setting it to undefined is idempotent).
    rt.global().setProperty(rt, "Canopy", jsi::Value::undefined());
    rt.global().setProperty(rt, "Elm", jsi::Value::undefined());
    {
      jsi::Value scope = rt.global().getProperty(rt, "scope");
      if (scope.isObject()) {
        scope.getObject(rt).setProperty(rt, "Canopy", jsi::Value::undefined());
        scope.getObject(rt).setProperty(rt, "Elm", jsi::Value::undefined());
      }
    }

    // (4) re-evaluate the NEW bundle on the SAME runtime.
    rt.evaluateJavaScript(std::make_shared<jsi::StringBuffer>(srcStr),
                          "canopy.bundle.js (reload)");

    // (5) re-boot onto the SAME cached root handle (host root view + surface untouched) with the SAME
    // flags the program first booted with.
    canopy::canopyBoot(rt, _rootTag, _bootFlags);

    // (6) restore the captured model into the freshly-booted program. A null carrier (release bundle
    // / no live state) makes remount a no-op — the reloaded program keeps its init model.
    jsi::Value rem = rt.global().getProperty(rt, "__canopy_remount");
    if (rem.isObject() && rem.getObject(rt).isFunction(rt)) {
      rem.getObject(rt).getFunction(rt).call(rt, captured);
    }

    // (7) surface any 'Model changed' notice remount posted (an incompatible reload discarded the
    // model). A compatible reload posts nothing, so this is a no-op then.
    [self drainReloadNotice:rt];

  } catch (jsi::JSError& err) {
    [self showDevRedBox:[NSString stringWithFormat:@"reload: %s", err.getMessage().c_str()]
                  stack:[NSString stringWithUTF8String:err.getStack().c_str()]
                  fatal:YES];
  } catch (const std::exception& ex) {
    [self showDevRedBox:[NSString stringWithFormat:@"reload (native): %s", ex.what()]
                  stack:nil
                  fatal:YES];
  } catch (...) {
    [self showDevRedBox:@"reload (unknown native exception)" stack:nil fatal:YES];
  }
}

// DEV-8 / DEV-12 — drain the developer-facing notice native.js posts on
// globalThis.__canopy_reloadNotice when a state-preserving reload had to DISCARD the captured model
// because the new bundle's Model type-hash differs from the old one (an incompatible Model shape
// across the edit). We log it (the os_log channel survives with no dev UI) and CLEAR the global so a
// later compatible reload — which posts nothing — is not mistaken for a repeat. The iOS twin of
// CanopyHostJni.cpp's drainReloadNotice (which forwards to a Java toast); here we surface it as a
// short non-fatal red-box note so the developer sees why state was reset. Runs on the JS/main thread.
- (void)drainReloadNotice:(jsi::Runtime&)rt {
  jsi::Value v = rt.global().getProperty(rt, "__canopy_reloadNotice");
  if (!v.isObject()) return;
  jsi::Object o = v.getObject(rt);
  auto readStr = [&](const char* key) -> std::string {
    jsi::Value f = o.getProperty(rt, key);
    return f.isString() ? f.getString(rt).utf8(rt) : std::string();
  };
  std::string kind = readStr("kind");
  std::string message = readStr("message");
  // Clear the global first so the notice is consumed exactly once.
  rt.global().setProperty(rt, "__canopy_reloadNotice", jsi::Value::undefined());
  if (!message.empty()) {
    os_log(CanopyBootLog(), "canopy reload notice [%{public}s]: %{public}s",
           kind.c_str(), message.c_str());
  }
}

// DEV-12 — surface a dev-server BUILD error (a compile failure pushed by the dev server) as a
// NON-FATAL dev red-box, leaving the last-good program up underneath (DEV-11 recovery posture). The
// CanopyDevClient calls this on an `error` frame.
- (void)showDevBuildError:(NSString *)report {
  [self showDevRedBox:@"Build failed"
                stack:(report.length ? report : @"(no report)")
                fatal:NO];
}

// Render the dev red-box. fatal:YES tints the surface crimson and keeps the message up (the program
// is gone — a reload that failed to apply); fatal:NO is a build-error overlay over the still-running
// last-good tree. This is the debug-loop twin of Android's CanopyRedBox.show(dev=true). It reuses
// -reportFatal's os_log + surface-tint path (kept deliberately UIKit-light so it survives even a
// renderer crash); a richer scrollable overlay with Dismiss/Reload is CanopyDevRedBox (DevLoop/).
- (void)showDevRedBox:(NSString *)message stack:(nullable NSString *)stack fatal:(BOOL)fatal {
  os_log(CanopyBootLog(), "canopy dev red-box (%{public}s): %{public}s\n%{public}s",
         fatal ? "fatal" : "build", message.UTF8String, stack ? stack.UTF8String : "");
  NSString* msg = message;
  NSString* st = stack;
  BOOL isFatal = fatal;
  dispatch_async(dispatch_get_main_queue(), ^{
    [CanopyDevRedBox showOnView:self.view
                          title:isFatal ? @"Reload failed" : @"Build failed"
                        message:msg
                          stack:st
                          fatal:isFatal
                         reload:^(NSString* _Nullable _) { /* dev server re-pushes on next save */ }];
  });
}

// RNV-2: the boot-time Hermes/JSI ABI canary. Reads the LIVE bytecode version off the held runtime
// (HermesRuntime::getBytecodeVersion() — a static on the LINKED engine — plus the VM description)
// and compares it to the pin baked from host/vendor.lock.json (canopy::checkHermesAbi). The iOS
// twin of Android's enforceHermesAbiGate (CanopyHostJni.cpp). Returns YES when the ABI matches
// (boot proceeds), NO on mismatch (the caller resets the runtime and aborts boot before evaluating
// any user JS — a mismatched engine must not run). On mismatch we surface the SAME message both to
// the os_log fault channel (survives release, no UI) AND the on-screen red-box (reportFatal), so a
// debug boot stops on a visible, diagnosable screen instead of a later silent corruption/SIGABRT.
- (BOOL)enforceHermesAbiGate {
  const int liveBytecode =
      static_cast<int>(facebook::hermes::HermesRuntime::getBytecodeVersion());
  std::string vmDesc;
  try {
    vmDesc = _runtime->description();
  } catch (...) {
    vmDesc = "<unavailable>";
  }
  canopy::AbiCheckResult res = canopy::checkHermesAbi(liveBytecode, vmDesc);
  if (res.ok) {
    os_log(CanopyBootLog(), "CanopyAbiGate: %{public}s", res.message.c_str());
    return YES;
  }
  // Fail-closed. The reportFatal path emits an os_log_fault (the only signal in a release build
  // with no dev overlay) and tints the surface red so a mismatched-engine boot is visibly stopped.
  [self reportFatal:[NSString stringWithUTF8String:res.message.c_str()]
              stack:@"Hermes/JSI ABI canary (RNV-2)"];
  return NO;
}

// RNV-7: load the bundle bytes, preferring the real Hermes .hbc (canopy.bundle.hbc) over the JS
// source bundle (canopy.bundle.js). Returns nil only if NEITHER is in the app bundle.
- (nullable NSData*)loadBundleData {
  NSBundle* bundle = [NSBundle mainBundle];
  NSString* hbcPath = [bundle pathForResource:@"canopy.bundle" ofType:@"hbc"];
  NSString* path = hbcPath ?: [bundle pathForResource:@"canopy.bundle" ofType:@"js"];
  if (path == nil) return nil;
  NSError* err = nil;
  NSData* data = [NSData dataWithContentsOfFile:path options:0 error:&err];
  if (data == nil) {
    os_log_error(CanopyBootLog(), "canopy: failed to read %{public}s: %{public}s",
                 path.lastPathComponent.UTF8String, err.localizedDescription.UTF8String);
  }
  return data;
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
