// CanopyStreamingModuleBase.mm — the generic streaming capability base implementation.
//
// Mirrors StreamingJniModule.cpp's bookkeeping exactly (streams_ / lastByChannel_ + first-
// subscriber notify + prime-on-subscribe + emit-to-all), but driven by ObjC handlers and UIKit
// event sources rather than a JNI nativeEmit bridge. See the header for the contract.
//
// Compiled as Objective-C++ with ARC (the .mm extension is for symmetry with the rest of the
// bridge; the body is plain ObjC).

#import "CanopyStreamingModuleBase.h"

NS_ASSUME_NONNULL_BEGIN

@implementation CanopyStreamingModuleBase {
  NSString *_name;
  NSMutableDictionary<NSString *, CanopyMethodHandler> *_handlers;
  NSMutableSet<NSString *> *_streamingMethods;
  BOOL _handlersRegistered;

  // Stream bookkeeping (the iOS parallel of StreamingJniModule::streams_ / lastByChannel_):
  //   _sinkByCallId      callId  → the live complete sink   (for cancel + single-target emit)
  //   _channelByCallId   callId  → the channel it joined    (so cancel can find its channel)
  //   _callIdsByChannel  channel → ordered live callIds      (emit-to-all + last-unsubscribe)
  //   _lastByChannel     channel → last emitted event JSON   (prime a fresh subscriber)
  // All guarded by _lock; emit() may be called from any thread, invoke()/cancel() from main.
  NSLock *_lock;
  NSMutableDictionary<NSString *, CanopyComplete> *_sinkByCallId;
  NSMutableDictionary<NSString *, NSString *> *_channelByCallId;
  NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *_callIdsByChannel;
  NSMutableDictionary<NSString *, NSString *> *_lastByChannel;
}

- (instancetype)initWithModuleName:(NSString *)name {
  if ((self = [super init])) {
    _name = [name copy];
    _handlers = [NSMutableDictionary dictionary];
    _streamingMethods = [NSMutableSet set];
    _lock = [[NSLock alloc] init];
    _sinkByCallId = [NSMutableDictionary dictionary];
    _channelByCallId = [NSMutableDictionary dictionary];
    _callIdsByChannel = [NSMutableDictionary dictionary];
    _lastByChannel = [NSMutableDictionary dictionary];
  }
  return self;
}

- (instancetype)init {
  NSString *cls = NSStringFromClass([self class]);
  NSRange dot = [cls rangeOfString:@"." options:NSBackwardsSearch];  // strip Swift "Module." prefix
  if (dot.location != NSNotFound) { cls = [cls substringFromIndex:dot.location + 1]; }
  if ([cls hasPrefix:@"Canopy"]) { cls = [cls substringFromIndex:6]; }
  if ([cls hasSuffix:@"Module"]) { cls = [cls substringToIndex:cls.length - 6]; }
  return [self initWithModuleName:cls];
}

- (NSString *)name { return _name; }
- (NSString *)moduleName { return _name; }

// ---- subclass override points (defaults) --------------------------------------------------

- (void)registerHandlers { /* subclass registers via -onMethod:handler: */ }
- (void)onFirstSubscriber:(NSString *)channel args:(NSString *)argsJson { /* subclass observes */ }
- (void)onLastUnsubscribe:(NSString *)channel { /* subclass stops observing */ }

// ---- handler / streaming registration -----------------------------------------------------

- (void)onMethod:(NSString *)method handler:(CanopyMethodHandler)handler {
  if (method.length == 0 || handler == nil) { return; }
  _handlers[method] = [handler copy];
}

- (void)setStreamingMethods:(NSArray<NSString *> *)methods {
  [_streamingMethods removeAllObjects];
  if (methods) { [_streamingMethods addObjectsFromArray:methods]; }
}

// ---- the CanopyModule entry point ---------------------------------------------------------

- (BOOL)invokeMethod:(NSString *)method
                args:(NSString *)argsJson
              callId:(NSString *)callId
            complete:(CanopyComplete)complete {
  if (!_handlersRegistered) {
    _handlersRegistered = YES;
    [self registerHandlers];
  }

  CanopyMethodHandler handler = _handlers[method];
  if (handler == nil) {
    return NO;  // unknown method → dispatcher reports -1 / ModuleNotFound
  }

  NSString *safeArgs = argsJson ?: @"{}";
  NSString *safeCallId = callId ?: @"";

  if ([_streamingMethods containsObject:method]) {
    // STREAMING subscribe (StreamingJniModule.cpp:42-68): record the sink, detect first-on-
    // channel, capture the primed last value — all under the lock.
    BOOL firstOnChannel = NO;
    NSString *primed = nil;
    [_lock lock];
    NSMutableArray<NSString *> *ids = _callIdsByChannel[method];
    if (ids == nil) {
      ids = [NSMutableArray array];
      _callIdsByChannel[method] = ids;
    }
    firstOnChannel = (ids.count == 0);
    if (![ids containsObject:safeCallId]) { [ids addObject:safeCallId]; }
    _sinkByCallId[safeCallId] = [complete copy];
    _channelByCallId[safeCallId] = method;
    primed = _lastByChannel[method];
    [_lock unlock];

    // First subscriber → tell the subclass to begin observing the OS (lazily). On the main
    // queue (UIKit observers must be added there); we're already on the JS/main thread.
    if (firstOnChannel) {
      [self onFirstSubscriber:method args:safeArgs];
    }
    // Prime the fresh subscriber with the last known value so the UI is correct at once, without
    // waiting for the next change. No terminal {"$done":true} — these feeds end only on cancel.
    if (primed != nil) {
      complete(nil, primed);  // → postToJs → __canopy_resolve (a streamed event)
    }
    // Let the subclass run its per-subscribe handler (e.g. confirm/prime via its own state).
    handler(safeArgs, safeCallId, complete);
    return YES;  // keep the call open
  }

  // ONE-SHOT: just run the handler (it resolves once via complete).
  handler(safeArgs, safeCallId, complete);
  return YES;
}

- (void)cancelCallId:(NSString *)callId {
  if (callId.length == 0) { return; }
  NSString *channel = nil;
  BOOL channelNowEmpty = NO;
  [_lock lock];
  channel = _channelByCallId[callId];
  if (channel != nil) {
    NSMutableArray<NSString *> *ids = _callIdsByChannel[channel];
    [ids removeObject:callId];
    channelNowEmpty = (ids.count == 0);
  }
  [_sinkByCallId removeObjectForKey:callId];
  [_channelByCallId removeObjectForKey:callId];
  [_lock unlock];

  if (channel != nil && channelNowEmpty) {
    [self onLastUnsubscribe:channel];  // last subscriber gone → stop observing
  }
}

// ---- emit -----------------------------------------------------------------------------------

- (void)emitOnChannel:(NSString *)channel event:(NSString *)eventJson {
  if (channel.length == 0) { return; }
  NSString *json = eventJson ?: @"{}";
  NSArray<CanopyComplete> *sinks;
  [_lock lock];
  _lastByChannel[channel] = json;  // cache to prime future subscribers
  NSArray<NSString *> *ids = [_callIdsByChannel[channel] copy];
  NSMutableArray<CanopyComplete> *live = [NSMutableArray arrayWithCapacity:ids.count];
  for (NSString *cid in ids) {
    CanopyComplete s = _sinkByCallId[cid];
    if (s) { [live addObject:s]; }
  }
  sinks = live;
  [_lock unlock];

  // Each sink's complete hops to the JS thread via the registry postToJs, so emit is safe from
  // any thread (NSNotification on main, a StoreKit Task, traitCollectionDidChange).
  for (CanopyComplete sink in sinks) {
    sink(nil, json);
  }
}

- (nullable CanopyComplete)streamSinkForCallId:(NSString *)callId {
  if (callId.length == 0) { return nil; }
  [_lock lock];
  CanopyComplete sink = _sinkByCallId[callId];
  [_lock unlock];
  return sink;
}

- (NSArray<NSString *> *)streamCallIdsForChannel:(NSString *)channel {
  if (channel.length == 0) { return @[]; }
  [_lock lock];
  NSArray<NSString *> *ids = [_callIdsByChannel[channel] copy];
  [_lock unlock];
  return ids ?: @[];
}

@end

NS_ASSUME_NONNULL_END
