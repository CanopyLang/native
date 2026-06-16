// CanopyBillingModule.mm — the iOS host module behind canopy/billing (module "Billing").
//
// iOS analog of android/.../modules/BillingModule.java, re-backing the PORTABLE streaming half
// (shared/cpp/BillingModule.{h,cpp}) with StoreKit 2. Adopts the §4.1 CanopyModule protocol; the
// §4.2 bridge routes __canopy_call(module="Billing", …) here.
//
// L-I5 — STOREKIT 2 IS THE PRODUCTION PATH. StoreKit 2 (Product / Transaction / VerificationResult)
// is a Swift-only async/await API with NO Objective-C surface, so the StoreKit 2 logic lives in
// CanopyBillingStoreKit2.swift; this file OWNS a driver instance and forwards the three one-shots to
// it (on iOS 15+, the project.yml deployment floor). The Swift driver verifies the JWS signature on
// every transaction, reads Transaction.currentEntitlements for the lock state, and listens on
// Transaction.updates for out-of-band changes (refunds / Ask-to-Buy / Family Sharing). When StoreKit
// resolves no product (an unconfigured dev build / a Simulator with no .storekit config / no signed-in
// sandbox account) the Swift driver calls back onNoProduct and we fall through to the StoreKit-1 /
// fake-store path below — so the paywall is ALWAYS exercisable, with the IDENTICAL JSON wire contract.
//
// SPLIT OF RESPONSIBILITY (the streaming carve-out):
//   • One-shots (getProducts / purchase / restore) — done HERE: StoreKit 2 first (the Swift driver),
//     then a StoreKit-1 (SKProductsRequest / SKPaymentQueue) + fake-store fallback for the
//     unconfigured / pre-iOS-15 case. Resolved directly via the CanopyComplete block. On Android
//     these delegate to Java over JNI; on iOS there is no JNI, so the store logic lives on the iOS
//     side (the same place the Java fake store lives on Android).
//   • Streaming (entitlementChanges) — owned by the PORTABLE canopy::BillingModule. Its invoke()
//     for "entitlementChanges" just parks the sink and primes it from cache (no JNI involved), so
//     we forward that ONE method into globalBillingModule() by synthesizing a CallContext. Every
//     entitlement change we observe (a purchase, a restore, a StoreKit-1 transaction, or a StoreKit-2
//     Transaction.updates event) is pushed to all live subs via canopy::billingEmitEntitlement(json)
//     — exactly the symbol the Android nativeEmit JNI export forwards to, reused verbatim.
//
// PERSISTENCE / OFFLINE: StoreKit 2's Transaction.currentEntitlements IS the source of truth and
// is cached by the OS, so the lock state survives restarts and resolves offline without our own
// secure cache (the role storage-secure plays on the Android fake store). We still cache the last
// entitlement JSON in the portable module so a fresh subscriber is primed instantly, and mirror the
// bit into NSUserDefaults so the fake-store fallback and the StoreKit path share one persisted flag.
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

// The StoreKit 2 driver (CanopyBillingStoreKit2.swift) is reached through the GENERATED Swift header
// (Xcode emits <ProductModuleName>-Swift.h for a DEFINES_MODULE target; this static lib's module is
// CanopyHostCore). Guard the import with __has_include so this .mm still compiles before xcodegen +
// the Swift codegen have produced the header (e.g. on a syntax-only pass), and so a target that omits
// the Swift file degrades cleanly to the StoreKit-1 / fake-store path below. CANOPY_HAS_STOREKIT2 is
// the compile-time switch the one-shots below branch on (paired with the @available(iOS 15) runtime
// check, since StoreKit 2 is the iOS-15 floor — == project.yml deploymentTarget).
#if __has_include("CanopyHostCore-Swift.h")
#import "CanopyHostCore-Swift.h"
#define CANOPY_HAS_STOREKIT2 1
#elif __has_include(<CanopyHostCore/CanopyHostCore-Swift.h>)
#import <CanopyHostCore/CanopyHostCore-Swift.h>
#define CANOPY_HAS_STOREKIT2 1
#endif

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
#ifdef CANOPY_HAS_STOREKIT2
  // The StoreKit 2 driver (nil before iOS 15, where the StoreKit-1 / fake path serves). `id` typed so
  // this ivar block has no @available constraint; constructed under the runtime check in -init.
  id _storeKit2;
#endif
}

- (instancetype)init {
  if ((self = [super init])) {
    _queue = dispatch_queue_create("com.canopyhost.billing", DISPATCH_QUEUE_SERIAL);
#ifdef CANOPY_HAS_STOREKIT2
    // Construct the StoreKit 2 driver on iOS 15+ and wire its entitlement-change callback into the
    // SAME portable-stream emit the StoreKit-1 observer uses (canopy::billingEmitEntitlement via
    // -emitEntitlementActive:). On a purchase / restore / out-of-band Transaction.updates event the
    // driver persists nothing itself — it hands us the entitlement JSON, we persist it (so the fake
    // fallback agrees) and push it onto every live entitlementChanges sub.
    if (@available(iOS 15.0, *)) {
      CanopyBillingStoreKit2 *sk2 = [[CanopyBillingStoreKit2 alloc] init];
      __weak CanopyBillingModule *weakSelf = self;
      sk2.onEntitlementChange = ^(NSString *entitlementJson) {
        [weakSelf onStoreKit2EntitlementJSON:entitlementJson];
      };
      _storeKit2 = sk2;
    }
#endif
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
#ifdef CANOPY_HAS_STOREKIT2
  // L-I5: StoreKit 2 IS the production metadata path (Product.products(for:)). The Swift driver
  // resolves the real product, or an empty {"products":[]} when none is configured; in the empty
  // case we serve the dev catalog so the paywall always renders a price. (A StoreKit error also
  // yields the empty list, so getProducts never hard-rejects.)
  if (@available(iOS 15.0, *)) {
    if (_storeKit2 != nil) {
      CanopyComplete sk2Complete = [complete copy];
      [(CanopyBillingStoreKit2 *)_storeKit2 getProducts:^(NSString *err, NSString *result) {
        if (err == nil && [self resultHasNoProducts:result]) {
          // StoreKit 2 returned no configured product → fall back to the hardcoded dev catalog.
          CanopyResolve(sk2Complete, @{ @"products": @[ [self fallbackProductJSON] ] });
          [self emitCurrentEntitlement];
          return;
        }
        sk2Complete(err, result);
      }];
      return;
    }
  }
#endif
  // StoreKit 2 unavailable (pre-iOS-15 or no Swift driver): use the StoreKit 1 SKProductsRequest to
  // fetch the metadata, which exposes the same fields and works in both the .storekit simulator
  // config and sandbox.
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

#ifdef CANOPY_HAS_STOREKIT2
  // L-I5: StoreKit 2 IS the production purchase path (product.purchase() + JWS verification). The
  // Swift driver resolves the verified Purchase JSON, rejects "user_cancelled" on a dismissed sheet
  // (Billing.can maps that to the quiet UserCancelled), and persists nothing itself — its
  // onEntitlementChange callback drives -emitEntitlementActive: so we persist + stream. If no product
  // is configured it calls onNoProduct and we run the SAME fake-store grant the StoreKit-1 path uses.
  if (@available(iOS 15.0, *)) {
    if (_storeKit2 != nil) {
      CanopyComplete sk2Complete = [complete copy];
      __weak CanopyBillingModule *weakSelf = self;
      [(CanopyBillingStoreKit2 *)_storeKit2 purchase:productId
                                         onNoProduct:^{
                                           [weakSelf grantFakePurchase:productId complete:sk2Complete];
                                         }
                                            complete:sk2Complete];
      return;
    }
  }
#endif

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
#ifdef CANOPY_HAS_STOREKIT2
  // L-I5: StoreKit 2 IS the production restore path (AppStore.sync + Transaction.currentEntitlements).
  // The Swift driver resolves {isActive,productId} from the App Store-synced entitlement set and
  // drives -emitEntitlementActive: through its callback, so a re-install on a new device re-resolves
  // the unlock with no secure cache of ours. On pre-iOS-15 we read the persisted bit below.
  if (@available(iOS 15.0, *)) {
    if (_storeKit2 != nil) {
      [(CanopyBillingStoreKit2 *)_storeKit2 restore:[complete copy]];
      return;
    }
  }
#endif
  BOOL active = [self isActive];
  NSString *productId = active ? [self persistedProductId] : @"";
  CanopyResolve(complete, @{ @"isActive": @(active), @"productId": productId ?: @"" });
  [self emitEntitlementActive:active productId:productId];
}

#ifdef CANOPY_HAS_STOREKIT2
// ---- StoreKit 2 callbacks --------------------------------------------------------------------

// The Swift driver hands us a fresh entitlement JSON ({"isActive",productId}) on every change it
// observes (a verified purchase, a restore, or an out-of-band Transaction.updates event). Persist
// the bit so the fake-store fallback + a fresh subscriber agree, then push it onto every live sub
// via the SAME portable-stream emit the StoreKit-1 observer uses.
- (void)onStoreKit2EntitlementJSON:(NSString *)entitlementJson {
  NSDictionary *ent = CanopyParseArgs(entitlementJson);
  BOOL active = [ent[@"isActive"] respondsToSelector:@selector(boolValue)] ? [ent[@"isActive"] boolValue] : NO;
  NSString *productId = [ent[@"productId"] isKindOfClass:[NSString class]] ? ent[@"productId"] : @"";
  [self persistActive:active productId:productId];
  // billingEmitEntitlement directly with the driver's own JSON (already the wire Entitlement shape).
  canopy::billingEmitEntitlement(std::string(entitlementJson.UTF8String));
}

// True iff a getProducts result JSON carries an EMPTY products array (the Swift driver's signal that
// no product is configured for this build → serve the dev catalog).
- (BOOL)resultHasNoProducts:(NSString *)resultJson {
  if (resultJson.length == 0) { return YES; }
  NSDictionary *obj = CanopyParseArgs(resultJson);
  id products = obj[@"products"];
  return ![products isKindOfClass:[NSArray class]] || [(NSArray *)products count] == 0;
}
#endif

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
