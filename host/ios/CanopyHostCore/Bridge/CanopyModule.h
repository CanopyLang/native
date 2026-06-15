// CanopyModule.h — the ObjC protocol every iOS capability adopts (SHARED CONTRACT §4.1, §6.4).
//
// One capability = one ObjC/Swift object adopting <CanopyModule>. CanopyNativeModuleBridge
// (CanopyNativeModule.h) wraps it in a C++ canopy::NativeModule and registers it, so
// __canopy_call(module, method, argsJson, callId) routes straight to -invokeMethod:…. This is
// the iOS replacement for Android's JNI module mechanism (CanopyJni.h): there is no FindClass
// reflection, no pending JNI table, no resolveModule entry point, no scheduleOnJs Looper hop —
// the host already holds the jsi::Runtime* and the ModuleRegistry in-process, and the only
// thread hop is the registry's postToJs (= dispatch_async(dispatch_get_main_queue()) on iOS).
//
// THE RESOLVE/REJECT CONVENTION (CanopyComplete), matched by every capability + the
// CanopyModuleSupport helpers (CanopyResolve / CanopyReject / CanopyResolveNull):
//   • errJson == nil           → SUCCESS; resultJson is the payload JSON ("{}" / "null" / {...}).
//   • errJson != nil           → REJECTION; a {"code":…,"message":…} JSON object. resultJson is
//                                ignored (pass nil).
//   • complete(nil, "{\"$done\":true}") → STREAM TEARDOWN: ends a subscription's JS-side listener
//                                (the Echo "ticks" / billing-updates shape).
// The block may be called from ANY queue, now or later, and REPEATEDLY for a subscription. It
// is internally bridged to canopy::CallContext::complete, which re-marshals onto the JS thread
// before touching the runtime (CanopyModules.cpp:62-70), so a capability finishes on any GCD
// queue / Task / delegate callback and calls the block from there with NO manual main-hop.
//
// Threading invariant (contract §0.2): the JS thread IS the main thread; the runtime is touched
// only on the main queue. A capability never touches the runtime — it only calls this block.
//
// Portable C++ is NOT included here so Swift can import this header cleanly through the bridging
// header. The C++↔block glue lives entirely in CanopyNativeModule.mm.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The resolve/reject sink handed to a capability for one in-flight call. See the file header
/// for the nil=success / non-nil=reject / {"$done":true}=stream-end convention. Thread-safe to
/// call from any queue; may be called once (one-shot) or many times (subscription).
typedef void (^CanopyComplete)(NSString *_Nullable errJson, NSString *_Nullable resultJson);

/// Every iOS capability (CanopyImageModule, CanopyPhotosModule, CanopyBillingModule, …) adopts
/// this. -moduleName is the PascalCase capability name routed on by __canopy_call and returned
/// by the wrapping NativeModule::name() — the exact strings in contract §6.5: "Echo", "Photos",
/// "Album", "ShareImage", "StorageSecure", "Notify", "Image", "Billing", "Lifecycle",
/// "AppShell", "RestoreEngine".
@protocol CanopyModule <NSObject>

/// The capability name routed by __canopy_call (matches NativeModule::name()).
- (NSString *)moduleName;

/// Dispatch one call.
///   • Return YES if `method` is known (even if it completes asynchronously, or — for a
///     subscription — never resolves until cancelled). The dispatcher keeps the call open.
///   • Return NO if `method` is UNKNOWN on this module. The bridge reports it the same way as an
///     unknown module: the dispatcher returns -1 and JS maps it to ModuleNotFound; the callId is
///     forgotten. (Mirrors NativeModule::invoke's bool contract, CanopyModules.h:62-64.)
/// `complete` may be invoked synchronously inside this call, later from any queue, or repeatedly
/// (a stream). `argsJson` is the JSON the .can Cmd/Sub encoded — never nil ("{}" when the method
/// takes no args, matching the no-arg marshal). For a one-shot, call `complete` exactly once;
/// for a subscription, call it on each event and hold the block until -cancelCallId: drops it.
- (BOOL)invokeMethod:(NSString *)method
                args:(NSString *)argsJson
              callId:(NSString *)callId
            complete:(CanopyComplete)complete;

@optional

/// Best-effort, idempotent cancel of an in-flight call / live subscription started under
/// `callId` (the JS side called __canopy_cancel). A one-shot that already completed may ignore
/// it; a subscription drops its sink so no further events emit. A capability that cannot cancel
/// simply omits this method (the bridge checks -respondsToSelector:). Mirrors
/// NativeModule::cancel (CanopyModules.h:66-68).
- (void)cancelCallId:(NSString *)callId;

/// Advisory metadata: declare which of this module's methods are SUBSCRIPTIONS (channels), the
/// iOS parallel of StreamingJniModule's streamingMethods set (StreamingJniModule.h:67). Optional
/// — only a generic streaming base (CanopyStreamingModuleBase) needs it; a hand-written
/// capability tracks its own subscriptions. The convention registrar
/// (+registerModuleNamed:…streamingMethods:) calls this if the module responds.
- (void)setStreamingMethods:(NSArray<NSString *> *)methods;

@end

NS_ASSUME_NONNULL_END
