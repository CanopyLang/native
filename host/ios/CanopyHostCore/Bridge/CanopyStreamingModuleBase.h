// CanopyStreamingModuleBase.h — optional generic streaming capability base (iOS analog of
// StreamingJniModule, SHARED CONTRACT §4.4).
//
// WHY THIS EXISTS (the streaming carve-out, generalized for iOS):
// Most capabilities are one-shots (pick, decode, save, share) — they adopt <CanopyModule>
// directly and call complete(...) once. But a SUBSCRIPTION (a .can Sub via
// Native.Module.callStreaming) emits MANY events on ONE callId and ends only on cancel:
// appState / memoryPressure / backPressed (Lifecycle), colorScheme (AppShell),
// entitlementChanges (Billing), batch progress. On Android these graduate to a real C++
// NativeModule that owns per-channel sink lists (BillingModule / StreamingJniModule). On iOS
// the same pattern is this ObjC base: a capability subclasses it, declares its streaming
// methods + per-method handlers, and gets the per-channel sink bookkeeping, prime-on-subscribe,
// emit-to-all-subscribers, and cancel for free — the exact shape of StreamingJniModule, but
// driven by UIKit/Foundation event sources (NSNotificationCenter, traitCollectionDidChange,
// StoreKit Transaction.updates) instead of a JNI nativeEmit bridge.
//
// THE SHAPE (1:1 with StreamingJniModule):
//   • One-shot methods       → registered via -onMethod:handler:; resolve once.
//   • Streaming methods       → declared via -setStreamingMethods: (or the convention registrar);
//     (channels)                invoke() stores `complete` in a per-CHANNEL sink list keyed by
//                               callId (NOT erase-on-resolve), calls -onFirstSubscriber:args: the
//                               first time a channel gets a subscriber (so the subclass can begin
//                               observing the OS lazily), and primes a fresh subscriber with the
//                               last cached event (StreamingJniModule.cpp:43-68).
//   • -emitOnChannel:event:    → pushes one event to every live sink on a channel, caching it to
//                               prime future subscribers (StreamingJniModule::emit). Safe from any
//                               thread (each sink hops to the JS thread via the registry postToJs).
//   • -cancelCallId:           → drops the sink from its channel; if it was the LAST subscriber,
//                               calls -onLastUnsubscribe: so the subclass can stop observing.
//
// A capability does NOT have to use this — adopting <CanopyModule> and tracking its own
// subscriptions is always allowed. This is the convenience for the half-dozen streaming ones.
//
// Depends only on CanopyModule.h (the protocol). No portable C++ leaks here, so a Swift
// capability can subclass it through the bridging header. The matching Android file is
// StreamingJniModule.h.

#import <Foundation/Foundation.h>

#import "CanopyModule.h"

NS_ASSUME_NONNULL_BEGIN

/// A per-method handler. Decode `argsJson`, do the work (sync or on a queue), and call
/// `complete`. For a subscription this is called ONCE per subscribe (the base has already
/// recorded the sink and primed the last value before calling it); the handler typically just
/// kicks off / confirms observation. For a one-shot, resolve `complete` exactly once.
typedef void (^CanopyMethodHandler)(NSString *argsJson, NSString *callId, CanopyComplete complete);

@interface CanopyStreamingModuleBase : NSObject <CanopyModule>

/// The capability name (contract §6.5). A subclass sets it via -initWithModuleName: or by
/// overriding -moduleName. -init derives it from the class name (strip leading "Canopy",
/// trailing "Module", and any Swift "Module." prefix).
@property (nonatomic, copy, readonly) NSString *name;

- (instancetype)initWithModuleName:(NSString *)name NS_DESIGNATED_INITIALIZER;
- (instancetype)init;

// ---- subclass override points -------------------------------------------------------------

/// Register per-method handlers here (called once, lazily, before the first invoke). Override
/// and call -onMethod:handler: for each method. Default registers nothing.
- (void)registerHandlers;

/// Called the FIRST time `channel` gains a subscriber (StreamingJniModule's "tell the OS to
/// begin observing"). Begin observing the OS event source here (add an NSNotification observer,
/// a Transaction.updates listener, …). Default does nothing. Always called on the main queue.
- (void)onFirstSubscriber:(NSString *)channel args:(NSString *)argsJson;

/// Called when the LAST subscriber on `channel` unsubscribes (cancel). Stop observing the OS
/// event source here. Default does nothing.
- (void)onLastUnsubscribe:(NSString *)channel;

// ---- subclass helpers ---------------------------------------------------------------------

/// Register one method handler (call from -registerHandlers).
- (void)onMethod:(NSString *)method handler:(CanopyMethodHandler)handler;

/// Declare which methods are subscriptions (channels). Also settable by the convention
/// registrar via the <CanopyModule> optional -setStreamingMethods:.
- (void)setStreamingMethods:(NSArray<NSString *> *)methods;

/// Push one event to EVERY live sink subscribed on `channel`, caching it to prime future
/// subscribers — the iOS StreamingJniModule::emit. Safe to call from any thread (each sink's
/// complete hops to the JS thread via the registry postToJs). errJson is always nil here (an
/// event is a success); to END a stream emit complete(nil,"{\"$done\":true}") via a sink from
/// -streamSinkForCallId: instead.
- (void)emitOnChannel:(NSString *)channel event:(NSString *)eventJson;

/// The live `complete` sink for one subscription callId (nil if cancelled / not a subscription).
/// Lets a subclass target a single subscriber (e.g. send that subscriber a terminal
/// {"$done":true}).
- (nullable CanopyComplete)streamSinkForCallId:(NSString *)callId;

/// The live subscriber callIds on `channel` (empty if none).
- (NSArray<NSString *> *)streamCallIdsForChannel:(NSString *)channel;

@end

NS_ASSUME_NONNULL_END
