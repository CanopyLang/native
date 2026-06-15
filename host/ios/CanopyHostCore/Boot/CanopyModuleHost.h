// CanopyModuleHost.h — owner of the C1 native-module dispatcher on iOS (contract §3.3).
//
// This is Author B's half of the boot: CanopyHostViewController owns the held
// jsi::Runtime* and the Fabric host; CanopyModuleHost owns the ModuleRegistry, the
// main-queue postToJs hop, the console polyfill, and registerAll() — the iOS analog of
// the registry-wiring block in Android's CanopyHostJni.cpp:216-249.
//
// The registry holds the runtime pointer (setRuntime) and the JS-thread hop (setPostToJs).
// A module's ctx.complete is wrapped by the registry so it re-marshals onto the JS thread
// (= the main queue on iOS) before calling __canopy_resolve — so a Swift/ObjC capability
// may finish on any GCD queue and call complete() from there with no manual main-hop
// (contract §4.2, §4.3). Touch the runtime ONLY on the main queue (contract §0.2).
//
// Pure Objective-C++ (compiled as .mm): the @interface is ObjC, the typedefs + members
// are C++. Swift never imports this file; only CanopyHostViewController.mm drives it.

#pragma once

#import <Foundation/Foundation.h>

#include <functional>
#include <memory>

#include "../../../shared/cpp/CanopyModules.h"  // canopy::ModuleRegistry, NativeModule

namespace canopy {

// The JS-thread hop (contract §6.1). On iOS this is dispatch_async(dispatch_get_main_queue()).
// Declared here (Author B's file) per §6.1; guarded so a future shared header can also
// declare the identical alias without an ODR clash.
#ifndef CANOPY_POSTTOJSFN_DEFINED
#define CANOPY_POSTTOJSFN_DEFINED
using PostToJsFn = std::function<void(std::function<void()>)>;
#endif

}  // namespace canopy

NS_ASSUME_NONNULL_BEGIN

/// Owns the C1 native-module dispatcher (the `__canopy_*` effect ABI) on iOS.
///
/// Lifecycle (driven by CanopyHostViewController, all on the main queue):
///   1. -initWithRuntime:postToJs:   — construct, holding the held runtime + the main hop.
///   2. -installInto:                — installCanopyModules + registry.setRuntime/setPostToJs.
///   3. -installConsolePolyfill:     — bare Hermes ships no `console`; the bundle needs it.
///   4. -registerAll                 — register Echo + every capability NativeModule + CoreML,
///                                      and hand the Core ML model path to the inference module.
@interface CanopyModuleHost : NSObject

/// Construct the module host. `rt` is the held Hermes runtime (owned by the view
/// controller, created on the main queue). `post` is the JS-thread hop — on iOS,
/// `dispatch_async(dispatch_get_main_queue(), ...)`. Neither is retained beyond the host's
/// lifetime; the controller outlives this object.
- (instancetype)initWithRuntime:(facebook::jsi::Runtime *)rt
                       postToJs:(canopy::PostToJsFn)post NS_DESIGNATED_INITIALIZER;

/// Install the `__canopy_call`/`__canopy_cancel` globals and wire the registry's runtime
/// pointer + postToJs hop. Call once, after installCanopyFabric and before evaluating the
/// bundle (contract §3.2 step 4).
- (void)installInto:(facebook::jsi::Runtime &)rt;

/// Install a minimal `console` (log/info/warn/error/debug/trace) onto the runtime — bare
/// Hermes has none and the compiled bundle's effect-manager runtime references it
/// (mirrors Android installConsole, CanopyHostJni.cpp:166-197). Call before evaluating the
/// bundle (contract §3.2 step 5).
- (void)installConsolePolyfill:(facebook::jsi::Runtime &)rt;

/// Register every capability NativeModule (contract §3.5): Echo (shared C++), the Core ML
/// RestoreEngine (Author F), and one bridge per Swift/ObjC capability (Author E). Also
/// performs the model-bytes handoff: locates `restore.mlpackage` in the app bundle and
/// hands its path to the Core ML module before first use. Call once, after -installInto:.
- (void)registerAll;

/// The owned registry — exposed for tests (CanopyBridgeTests, contract §3.3).
- (canopy::ModuleRegistry *)registry;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
