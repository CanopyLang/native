// CanopyNativeModule.h — the ObjC↔C++ NativeModule glue (SHARED CONTRACT §4.2, §6.4).
//
// THE C1 BRIDGE. This is the iOS analog of CanopyJni.cpp's JniModule + callJavaModule +
// resolveModule, collapsed into a single direct-dispatch path because the host holds the
// runtime + registry in-process (no JNI). CanopyNativeModuleBridge wraps an id<CanopyModule>
// (CanopyModule.h) into a private C++ canopy::NativeModule (ObjCNativeModule, in the .mm) and
// registers it into a canopy::ModuleRegistry. From then on:
//
//   JS:   Native.Module.call("Photos","pick",argsJson,decoder)
//          → __canopy_call("Photos","pick",argsJson,callId)        (CanopyModules.cpp)
//          → ModuleRegistry::dispatch → ObjCNativeModule::invoke(ctx)
//               builds a CanopyComplete block wrapping ctx.complete
//               → [module invokeMethod:@"pick" args:… callId:… complete:block]   (direct ObjC)
//   ObjC: PhotosModule does the real async work (PHPicker, decode, StoreKit, Core ML …) on any
//         GCD queue / Task, then calls complete(err,res)
//          → ctx.complete(err,res) → (registry postToJs → main) → canopyResolveCall
//          → __canopy_resolve(callId, …)                          (the C1 hop, CanopyModules.cpp)
//
// So the threading invariant is identical to Android's, minus JNI: the capability's work NEVER
// touches the jsi::Runtime; only the block (→ ctx.complete → postToJs) does. Streaming uses the
// SAME block called repeatedly; a final complete(nil,"{\"$done\":true}") tears the JS listener
// down (contract §4.4). The matching Android files are CanopyJni.{h,cpp} + StreamingJniModule.
//
// Depends only on the portable CanopyModules.h (canopy::ModuleRegistry / NativeModule). It is
// the ONE place ObjC meets the C++ ABI (contract §4.2). Swift never imports this file — only
// CanopyModuleHost / a CanopyCapabilities aggregator (ObjC++) does, to register capabilities.

#pragma once

#import <Foundation/Foundation.h>

#import "CanopyModule.h"

#ifdef __cplusplus
#include "CanopyModules.h"  // canopy::ModuleRegistry / NativeModule (resolved via HEADER_SEARCH_PATHS)
#endif

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus

/// Wraps an id<CanopyModule> capability into a C++ canopy::NativeModule and registers it.
/// The single seam between the ObjC capability layer and the portable C++ effect ABI.
@interface CanopyNativeModuleBridge : NSObject

/// Wrap `module` into a C++ NativeModule (named module.moduleName) and register it into
/// `registry`. Call at boot (CanopyModuleHost registerAll / a CanopyCapabilities aggregator),
/// AFTER installCanopyModules. The bridge retains `module` for the process lifetime of the
/// registered NativeModule, so the capability object stays alive across calls. Idempotent in
/// the sense that re-registering the same name replaces the prior module (registry semantics,
/// CanopyModules.cpp:35-37). No-op if `module` is nil or `registry` is null.
+ (void)registerModule:(id<CanopyModule>)module
            inRegistry:(canopy::ModuleRegistry *)registry;

/// Convention-based registration — the iOS analog of CanopyJni's
/// "com/canopyhost/modules/<Name>Module" class resolution (CanopyJni.cpp:92). Resolves the
/// ObjC/Swift class `Canopy<name>Module` (e.g. name="Photos" → CanopyPhotosModule), instantiates
/// it via -init, and registers it. Because a Swift class's runtime name is mangled with the
/// product-module prefix ("MyApp.CanopyPhotosModule"), each prefix in `swiftModulePrefixes` is
/// also tried. The class must adopt <CanopyModule> and have a no-arg -init.
///
/// `streamingMethods` (optional) is forwarded to the module's -setStreamingMethods: if it
/// responds — the iOS parallel of StreamingJniModule's streamingMethods set, so a generic
/// streaming capability learns which of its methods are channels.
///
/// Returns YES if a class was found, instantiated, and registered; NO if no such class exists
/// (so the integrator can fall back / log "module unavailable"). Mirrors callJavaModule's
/// "class not found → false" posture (CanopyJni.cpp:94-98).
+ (BOOL)registerModuleNamed:(NSString *)name
                 inRegistry:(canopy::ModuleRegistry *)registry
       swiftModulePrefixes:(nullable NSArray<NSString *> *)swiftModulePrefixes
          streamingMethods:(nullable NSArray<NSString *> *)streamingMethods;

@end

#endif  // __cplusplus

NS_ASSUME_NONNULL_END
