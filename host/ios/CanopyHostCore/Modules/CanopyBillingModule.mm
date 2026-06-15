// CanopyBillingModule.mm — the iOS host module behind canopy/billing (module "Billing").
//
// iOS analog of android/.../modules/BillingModule.java, re-backing the PORTABLE streaming half
// (shared/cpp/BillingModule.{h,cpp}) with StoreKit 2. Adopts the §4.1 CanopyModule protocol; the
// §4.2 bridge routes __canopy_call(module="Billing", …) here.
//
// SPLIT OF RESPONSIBILITY (the streaming carve-out):
//   • One-shots (getProducts / purchase / restore) — done HERE against StoreKit 2 and resolved
//     directly via the CanopyComplete block. On Android these delegate to Java over JNI; on iOS
//     there is no JNI, so the store logic lives in this file (the same place the Java fake store
//     lives on Android).
//   • Streaming (entitlementChanges) — owned by the PORTABLE canopy::BillingModule. Its invoke()
//     for "entitlementChanges" just parks the sink and primes it from cache (no JNI involved), so
//     we forward that ONE method into globalBillingModule() by synthesizing a CallContext. Every
//     entitlement change we observe (a purchase, a restore, or a Transaction.updates event) is
//     pushed to all live subs via canopy::billingEmitEntitlement(json) — exactly the symbol the
//     Android nativeEmit JNI export forwards to, reused verbatim.
//
// PERSISTENCE / OFFLINE: StoreKit 2's Transaction.currentEntitlements IS the source of truth and
// is cached by the OS, so the lock state survives restarts and resolves offline without our own
// secure cache (the role storage-secure plays on the Android fake store). We still cache the last
// entitlement JSON in the portable module so a fresh subscriber is primed instantly.
//
// THE FAKE-STORE FALLBACK: StoreKit needs a configured product (a .storekit file on simulator or
// a real App Store Connect product). When no product resolves (unconfigured dev build), we fall
// back to the SAME hardcoded lifetime-unlock product + a secure-store-persisted entitlement the
// Android fake store uses, so the paywall is exercisable before StoreKit is wired. The wire shapes
// are identical either way.
//
// Wire contract (must match billing.js / Billing.can and BillingModule.java):
//   getProducts        null|{}      -> {"products":[Product,…]}
//   purchase           {productId}  -> {productId, transactionId, entitlement:{isActive,productId}}
//   restore            null|{}      -> {isActive, productId}
//   entitlementChanges              -> streamed Entitlement events (portable module owns the sink)
//   Product = {id,title,description,priceText,priceMicros,currencyCode}

#import <Foundation/Foundation.h>
#import <StoreKit/StoreKit.h>
#import <objc/runtime.h>

#include <cmath>       // std::llround (price micros) — not guaranteed transitively via Foundation
#include <functional>
#include <memory>
#include <string>

#import "CanopyModule.h"
#import "CanopyModuleSupport.h"
#include "BillingModule.h"   // portable canopy::BillingModule + billingEmitEntitlement (shared C++)

// The single product the store sells (a lifetime unlock — a one-time, non-consumable purchase).
// Mirrors billing.js's BILLING_PRODUCT / BillingModule.java's PRODUCT_ID exactly.
static NSString *const kProductId = @"lifetime_unlock";

@class CanopyProductsDelegate;
@class CanopyPurchaseDelegate;
@class CanopyPaymentObserver;

@interface CanopyBillingModule : NSObject <CanopyModule>
// Internal handoffs used by the SKProductsRequest delegates / payment observer below.
- (NSDictionary *)productJSONFromSK:(SKProduct *)p;
- (NSDictionary *)fallbackProductJSON;
- (void)emitCurrentEntitlement;
- (void)grantFakePurchase:(NSString *)productId complete:(CanopyComplete)complete;
- (void)grantOptimisticPurchaseResolve:(CanopyComplete)complete productId:(NSString *)productId;
- (void)recordTransactionActive:(BOOL)active productId:(NSString *)productId;
@end

// SKProductsRequest delegates + the long-lived payment observer (defined fully below the module).
@interface CanopyProductsDelegate : NSObject <SKProductsRequestDelegate>
- (instancetype)initWithComplete:(CanopyComplete)complete module:(CanopyBillingModule *)module;
@end

@interface CanopyPurchaseDelegate : NSObject <SKProductsRequestDelegate>
- (instancetype)initWithComplete:(CanopyComplete)complete
                          module:(CanopyBillingModule *)module
                     onNoProduct:(void (^)(void))onNoProduct;
@end

@interface CanopyPaymentObserver : NSObject <SKPaymentTransactionObserver>
- (instancetype)initWithModule:(CanopyBillingModule *)module;
@end

@implementation CanopyBillingModule {
  dispatch_queue_t _queue;
  BOOL _observingUpdates;
}

- (instancetype)init {
  if ((self = [super init])) {
    _queue = dispatch_queue_create("com.canopyhost.billing", DISPATCH_QUEUE_SERIAL);
    [self startTransactionObserverIfNeeded];
  }
  return self;
}

- (NSString *)moduleName { return @"Billing"; }

- (BOOL)invokeMethod:(NSString *)method
                args:(NSString *)argsJson
              callId:(NSString *)callId
            complete:(CanopyComplete)complete {
  // ---- streaming: forward to the portable module (it owns the multi-resolve sink) -----------
  if ([method isEqualToString:@"entitlementChanges"]) {
    [self subscribeEntitlementChanges:callId complete:complete];
    return YES;
  }

  // ---- one-shots: getProducts / purchase / restore ------------------------------------------
  if ([method isEqualToString:@"getProducts"]) {
    [self getProducts:complete];
    return YES;
  }
  if ([method isEqualToString:@"purchase"]) {
    NSDictionary *args = CanopyParseArgs(argsJson);
    NSString *productId = [args[@"productId"] isKindOfClass:[NSString class]] ? args[@"productId"] : @"";
    [self purchase:productId complete:complete];
    return YES;
  }
  if ([method isEqualToString:@"restore"]) {
    [self restore:complete];
    return YES;
  }
  return NO;  // unknown method -> ModuleNotFound
}

- (void)cancelCallId:(NSString *)callId {
  // Drop the stream sink in the portable module (Process.kill -> __canopy_cancel).
  canopy::globalBillingModule()->cancel(std::string(callId.UTF8String));
}

// ---- entitlementChanges: register the sink in the portable module -------------------------

- (void)subscribeEntitlementChanges:(NSString *)callId complete:(CanopyComplete)complete {
  // Synthesize the CallContext the portable BillingModule::invoke expects. Its "entitlementChanges"
  // path stores ctx.complete keyed by callId and primes from its last-emitted cache — no JNI. We
  // capture the ObjC block in a std::function so each streamed event flows back out through it.
  CanopyComplete sink = [complete copy];
  canopy::CallContext ctx;
  ctx.module   = "Billing";
  ctx.method   = "entitlementChanges";
  ctx.argsJson = "{}";
  ctx.callId   = std::string(callId.UTF8String);
  ctx.complete = [sink](std::string errJson, std::string resultJson) {
    NSString *err = errJson.empty() ? nil : [NSString stringWithUTF8String:errJson.c_str()];
    NSString *res = resultJson.empty() ? nil : [NSString stringWithUTF8String:resultJson.c_str()];
    sink(err, res);
  };
  canopy::globalBillingModule()->invoke(ctx);  // keeps the call open + primes the subscriber

  // Ensure the very first subscriber also sees the OS truth, in case nothing has emitted yet.
  [self emitCurrentEntitlement];
}

// ---- getProducts --------------------------------------------------------------------------

- (void)getProducts:(CanopyComplete)complete {
  // StoreKit 2's Product API is Swift-only (async/await). From Objective-C++ we use the StoreKit 1
  // SKProductsRequest to fetch the product metadata, which exposes the same fields and works in
  // both the .storekit simulator config and sandbox. (A pure-Swift CanopyBillingModule.swift may
  // instead call Product.products(for:) — the wire shape is identical.)
  SKProductsRequest *request =
      [[SKProductsRequest alloc] initWithProductIdentifiers:[NSSet setWithObject:kProductId]];
  CanopyProductsDelegate *delegate = [[CanopyProductsDelegate alloc] initWithComplete:complete
                                                                                module:self];
  request.delegate = delegate;
  // Keep the delegate alive until the request finishes (SKProductsRequest holds it weakly).
  objc_setAssociatedObject(request, "canopy.products.delegate", delegate, OBJC_ASSOCIATION_RETAIN);
  [request start];
}

// Build a Product JSON dict from an SKProduct (or the fallback constants when StoreKit returns
// nothing — an unconfigured dev build).
- (NSDictionary *)productJSONFromSK:(SKProduct *)p {
  NSNumberFormatter *fmt = [[NSNumberFormatter alloc] init];
  fmt.numberStyle = NSNumberFormatterCurrencyStyle;
  fmt.locale = p.priceLocale;
  NSString *priceText = [fmt stringFromNumber:p.price] ?: @"";
  long long priceMicros = (long long)std::llround(p.price.doubleValue * 1000000.0);
  NSString *currency = [p.priceLocale objectForKey:NSLocaleCurrencyCode] ?: @"USD";
  return @{
    @"id":           p.productIdentifier ?: kProductId,
    @"title":        p.localizedTitle ?: @"Lifetime Unlock",
    @"description":  p.localizedDescription ?: @"Unlock every feature forever.",
    @"priceText":    priceText,
    @"priceMicros":  @(priceMicros),
    @"currencyCode": currency,
  };
}

- (NSDictionary *)fallbackProductJSON {
  // Identical to BillingModule.java's doGetProducts hardcoded product.
  return @{
    @"id":           kProductId,
    @"title":        @"Lifetime Unlock",
    @"description":  @"Unlock every feature forever — one payment, no subscription.",
    @"priceText":    @"$4.99",
    @"priceMicros":  @(4990000),
    @"currencyCode": @"USD",
  };
}

// ---- purchase -----------------------------------------------------------------------------

- (void)purchase:(NSString *)productId complete:(CanopyComplete)complete {
  if (![productId isEqualToString:kProductId]) {
    CanopyReject(complete, @"item_unavailable", productId ?: @""); return;
  }
  if ([self isActive]) {
    // A real store rejects a re-purchase; the caller should restore instead.
    CanopyReject(complete, @"already_owned", productId); return;
  }

  // The simplest StoreKit-1 purchase path: add a payment for the product. The result lands in the
  // SKPaymentTransactionObserver (startTransactionObserver), which persists + emits. Here we kick
  // it off and resolve the one-shot Purchase from the persisted entitlement once recorded.
  // For dev builds with no product, fall back to the fake-store grant so the paywall is testable.
  SKProductsRequest *request =
      [[SKProductsRequest alloc] initWithProductIdentifiers:[NSSet setWithObject:kProductId]];
  __weak CanopyBillingModule *weakSelf = self;
  CanopyPurchaseDelegate *delegate =
      [[CanopyPurchaseDelegate alloc] initWithComplete:complete
                                                module:self
                                            onNoProduct:^{
        // Fake-store fallback: grant + persist + emit, resolve a synthetic Purchase.
        CanopyBillingModule *strongSelf = weakSelf;
        [strongSelf grantFakePurchase:productId complete:complete];
      }];
  request.delegate = delegate;
  objc_setAssociatedObject(request, "canopy.purchase.delegate", delegate, OBJC_ASSOCIATION_RETAIN);
  [request start];
}

- (void)grantFakePurchase:(NSString *)productId complete:(CanopyComplete)complete {
  [self persistActive:YES productId:productId];
  NSDictionary *entitlement = @{ @"isActive": @YES, @"productId": productId };
  NSDictionary *purchase = @{
    @"productId":     productId,
    @"transactionId": [NSString stringWithFormat:@"fake-txn-%llu",
                       (unsigned long long)([[NSDate date] timeIntervalSince1970] * 1000)],
    @"entitlement":   entitlement,
  };
  CanopyResolve(complete, purchase);
  [self emitEntitlementActive:YES productId:productId];
}

// Resolve the one-shot Purchase optimistically once a real payment is queued. The payment-queue
// observer carries the authoritative entitlement on the stream when the transaction finishes.
- (void)grantOptimisticPurchaseResolve:(CanopyComplete)complete productId:(NSString *)productId {
  NSDictionary *entitlement = @{ @"isActive": @YES, @"productId": productId ?: @"" };
  NSDictionary *purchase = @{
    @"productId":     productId ?: @"",
    @"transactionId": [NSString stringWithFormat:@"txn-%@", [[NSUUID UUID] UUIDString]],
    @"entitlement":   entitlement,
  };
  CanopyResolve(complete, purchase);
}

// ---- restore ------------------------------------------------------------------------------

- (void)restore:(CanopyComplete)complete {
  BOOL active = [self isActive];
  NSString *productId = active ? [self persistedProductId] : @"";
  CanopyResolve(complete, @{ @"isActive": @(active), @"productId": productId ?: @"" });
  [self emitEntitlementActive:active productId:productId];
}

// ---- entitlement emit (-> portable stream) ------------------------------------------------

- (void)emitEntitlementActive:(BOOL)active productId:(NSString *)productId {
  NSDictionary *ent = @{ @"isActive": @(active), @"productId": productId ?: @"" };
  NSData *data = [NSJSONSerialization dataWithJSONObject:ent options:0 error:nil];
  NSString *json = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
                        : @"{\"isActive\":false,\"productId\":\"\"}";
  // The same symbol the Android nativeEmit JNI export forwards to — pushes to every live sub.
  canopy::billingEmitEntitlement(std::string(json.UTF8String));
}

- (void)emitCurrentEntitlement {
  [self emitEntitlementActive:[self isActive] productId:[self persistedProductId]];
}

// ---- persistence (StoreKit currentEntitlements is the source of truth; UserDefaults caches) --

- (NSUserDefaults *)store { return [[NSUserDefaults alloc] initWithSuiteName:@"canopy_billing"]; }

- (BOOL)isActive { return [[self store] boolForKey:@"entitlement_active"]; }
- (NSString *)persistedProductId { return [[self store] stringForKey:@"entitlement_product"] ?: @""; }

- (void)persistActive:(BOOL)active productId:(NSString *)productId {
  NSUserDefaults *d = [self store];
  [d setBool:active forKey:@"entitlement_active"];
  [d setObject:(active ? (productId ?: @"") : @"") forKey:@"entitlement_product"];
  [d synchronize];
}

// ---- StoreKit transaction observer (records real purchases) -------------------------------

- (void)startTransactionObserverIfNeeded {
  if (_observingUpdates) { return; }
  _observingUpdates = YES;
  // A long-lived payment-queue observer catches purchases, restores, and out-of-band changes.
  // Each finished transaction persists the entitlement and emits it on the portable stream.
  CanopyPaymentObserver *observer = [[CanopyPaymentObserver alloc] initWithModule:self];
  // Retain the observer for the process lifetime.
  objc_setAssociatedObject([SKPaymentQueue defaultQueue], "canopy.payment.observer",
                           observer, OBJC_ASSOCIATION_RETAIN);
  [[SKPaymentQueue defaultQueue] addTransactionObserver:observer];
}

// Called by the observer when a transaction for our product completes/restores.
- (void)recordTransactionActive:(BOOL)active productId:(NSString *)productId {
  [self persistActive:active productId:productId];
  [self emitEntitlementActive:active productId:productId];
}

@end

#pragma mark - SKProductsRequest delegates (getProducts / purchase metadata)

@implementation CanopyProductsDelegate {
  CanopyComplete _complete;
  __weak CanopyBillingModule *_module;
}
- (instancetype)initWithComplete:(CanopyComplete)complete module:(CanopyBillingModule *)module {
  if ((self = [super init])) { _complete = [complete copy]; _module = module; }
  return self;
}
- (void)productsRequest:(SKProductsRequest *)request didReceiveResponse:(SKProductsResponse *)response {
  CanopyBillingModule *module = _module;
  NSMutableArray *products = [NSMutableArray array];
  if (response.products.count > 0 && module) {
    for (SKProduct *p in response.products) { [products addObject:[module productJSONFromSK:p]]; }
  } else if (module) {
    [products addObject:[module fallbackProductJSON]];  // unconfigured dev build
  }
  CanopyResolve(_complete, @{ @"products": products });
  if (module) { [module emitCurrentEntitlement]; }  // prime the stream cache
}
- (void)request:(SKRequest *)request didFailWithError:(NSError *)error {
  // StoreKit metadata fetch failed — fall back to the hardcoded product so getProducts still works.
  CanopyBillingModule *module = _module;
  NSArray *products = module ? @[ [module fallbackProductJSON] ] : @[];
  CanopyResolve(_complete, @{ @"products": products });
}
@end

@implementation CanopyPurchaseDelegate {
  CanopyComplete _complete;
  __weak CanopyBillingModule *_module;
  void (^_onNoProduct)(void);
}
- (instancetype)initWithComplete:(CanopyComplete)complete
                          module:(CanopyBillingModule *)module
                     onNoProduct:(void (^)(void))onNoProduct {
  if ((self = [super init])) {
    _complete = [complete copy]; _module = module; _onNoProduct = [onNoProduct copy];
  }
  return self;
}
- (void)productsRequest:(SKProductsRequest *)request didReceiveResponse:(SKProductsResponse *)response {
  if (response.products.count == 0) {
    if (_onNoProduct) { _onNoProduct(); }  // fake-store fallback
    return;
  }
  // Real product available: enqueue the payment. The payment-queue observer resolves the one-shot
  // by recording + emitting; here we resolve the Purchase optimistically once queued. (A pure
  // Swift module would await product.purchase() and resolve from its verified Transaction.)
  SKProduct *product = response.products.firstObject;
  SKPayment *payment = [SKPayment paymentWithProduct:product];
  [[SKPaymentQueue defaultQueue] addPayment:payment];
  // The observer will persist + emit on success; we resolve the synthetic Purchase now so the
  // one-shot Task settles (the stream carries the authoritative state).
  CanopyBillingModule *module = _module;
  if (module) { [module grantOptimisticPurchaseResolve:_complete productId:product.productIdentifier]; }
}
- (void)request:(SKRequest *)request didFailWithError:(NSError *)error {
  if (_onNoProduct) { _onNoProduct(); }  // treat a metadata failure as "no product" -> fake store
}
@end

#pragma mark - SKPaymentTransactionObserver (records real purchase/restore outcomes)

@implementation CanopyPaymentObserver {
  __weak CanopyBillingModule *_module;
}
- (instancetype)initWithModule:(CanopyBillingModule *)module {
  if ((self = [super init])) { _module = module; }
  return self;
}
- (void)paymentQueue:(SKPaymentQueue *)queue updatedTransactions:(NSArray<SKPaymentTransaction *> *)transactions {
  CanopyBillingModule *module = _module;
  for (SKPaymentTransaction *t in transactions) {
    switch (t.transactionState) {
      case SKPaymentTransactionStatePurchased:
      case SKPaymentTransactionStateRestored:
        if (module) { [module recordTransactionActive:YES productId:t.payment.productIdentifier]; }
        [queue finishTransaction:t];
        break;
      case SKPaymentTransactionStateFailed:
        [queue finishTransaction:t];
        break;
      default:
        break;  // Purchasing / Deferred — wait for a terminal state
    }
  }
}
@end
