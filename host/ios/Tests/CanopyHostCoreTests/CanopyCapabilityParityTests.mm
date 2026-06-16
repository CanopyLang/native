// CanopyCapabilityParityTests.mm — IOS-7: the DEVICE-FREE legs of the iOS<->Android capability
// parity ledger.
//
// IOS-7 closes the iOS<->Android capability divergence by authoring the missing iOS capability
// twins (Vibration/Battery/DeviceInfo/NetInfo/Haptics/Brightness) so an app loses NO capability on
// iOS. The REAL hardware behaviour of each twin (a buzz, a battery read, a haptic tap) is exercised
// on a Simulator/device by CanopyHostUITests; but several legs of "the twin is wired correctly" are
// PURE, platform-independent contract checks that need no launched app — exactly the role
// CanopyValidationLedgerTests.mm plays for the Part-5 render rules. This bundle pins those legs:
//
//   • PROTOCOL conformance — each Canopy<Name>Module resolves by name (the way the §4.2 by-name
//     bridge resolves it at boot), adopts <CanopyModule>, and reports the matching -moduleName.
//   • DISPATCH contract — an UNKNOWN method returns NO (→ the dispatcher reports ModuleNotFound),
//     and the .can-declared methods return YES (the call is accepted / kept open). This is the
//     exact bool contract ObjCNativeModule::invoke relies on (CanopyNativeModule.mm:84).
//   • REJECTION shape — the CanopyModuleSupport reject/resolve helpers build the {code,message}
//     JSON the Canopy side decodes into Native.Module.Rejected (pure, no UIKit), so the error
//     wire shape every twin shares is pinned here.
//
// These run on the build host as part of `xcodebuild test` (the CanopyHostCoreTests bundle); the
// structural completeness of the SAME parity is also gated device-free on Linux by
// scripts/check-ios-capability-parity.sh. The twin classes are file-private @interfaces inside
// their .mm files, so this bundle resolves them by NSClassFromString — precisely how the boot-time
// by-name registrar finds them — rather than importing a header.

#import <XCTest/XCTest.h>
#import <Foundation/Foundation.h>

#import "../../CanopyHostCore/Bridge/CanopyModule.h"          // the <CanopyModule> protocol
#import "../../CanopyHostCore/Modules/CanopyModuleSupport.h"  // CanopyReject/Resolve helpers
#include "../../../shared/cpp/CanopyModules.h"                // L-I3: canopy::NativeModule (complete
                                                             // type so shared_ptr<NativeModule> is
                                                             // well-formed + name() is callable)

@interface CanopyCapabilityParityTests : XCTestCase
@end

@implementation CanopyCapabilityParityTests

// Resolve a Canopy<name>Module class the way the §4.2 by-name bridge does (NSClassFromString),
// trying the plain ObjC name and the Swift product-module-mangled forms.
- (Class)resolveModuleClassNamed:(NSString *)name {
  NSString *plain = [NSString stringWithFormat:@"Canopy%@Module", name];
  Class cls = NSClassFromString(plain);
  if (cls != Nil) { return cls; }
  for (NSString *prefix in @[ @"CanopyHost", @"CanopyHostApp", @"CanopyHostCore" ]) {
    Class c = NSClassFromString([NSString stringWithFormat:@"%@.%@", prefix, plain]);
    if (c != Nil) { return c; }
  }
  return Nil;
}

// ---- PROTOCOL conformance: every twin resolves, conforms, and names itself correctly ----------

- (void)testEveryParityTwinResolvesAndConforms {
  for (NSDictionary *cap in @[
         @{ @"name": @"Vibration" }, @{ @"name": @"Battery" }, @{ @"name": @"DeviceInfo" },
         @{ @"name": @"NetInfo" },   @{ @"name": @"Haptics" }, @{ @"name": @"Brightness" } ]) {
    NSString *name = cap[@"name"];
    Class cls = [self resolveModuleClassNamed:name];
    XCTAssertNotNil(cls, @"the IOS-7 twin Canopy%@Module must resolve by name (boot registrar path)",
                    name);
    XCTAssertTrue([cls conformsToProtocol:@protocol(CanopyModule)],
                  @"Canopy%@Module must adopt <CanopyModule>", name);

    id<CanopyModule> module = [[cls alloc] init];
    XCTAssertNotNil(module, @"Canopy%@Module must have a no-arg -init (registrar requirement)", name);
    XCTAssertEqualObjects([module moduleName], name,
                          @"Canopy%@Module -moduleName must be the capability name", name);
  }
}

// ---- DISPATCH contract: unknown method → NO (ModuleNotFound), known method → YES --------------

- (void)testUnknownMethodReturnsNoForEveryTwin {
  for (NSDictionary *cap in @[
         @{ @"name": @"Vibration" }, @{ @"name": @"Battery" }, @{ @"name": @"DeviceInfo" },
         @{ @"name": @"NetInfo" },   @{ @"name": @"Haptics" }, @{ @"name": @"Brightness" } ]) {
    NSString *name = cap[@"name"];
    Class cls = [self resolveModuleClassNamed:name];
    if (cls == Nil) { continue; }  // covered as a failure by the conformance test
    id<CanopyModule> module = [[cls alloc] init];

    BOOL known = [module invokeMethod:@"thisMethodDoesNotExist"
                                 args:@"{}"
                               callId:@"c-unknown"
                             complete:^(NSString *e, NSString *r) { /* must never fire */ }];
    XCTAssertFalse(known,
                   @"Canopy%@Module must return NO for an unknown method (→ ModuleNotFound)", name);
  }
}

- (void)testDeclaredMethodsAreAccepted {
  // Each .can-declared method must be ACCEPTED (return YES) — the call is dispatched, not reported
  // as ModuleNotFound. The real async work runs on the main/serial queue and resolves later; here
  // we only assert the synchronous accept contract (device-free), not the hardware outcome.
  NSArray<NSDictionary *> *caps = @[
    @{ @"name": @"Vibration",  @"methods": @[ @"vibrate", @"cancel" ] },
    @{ @"name": @"Battery",    @"methods": @[ @"status" ] },
    @{ @"name": @"DeviceInfo", @"methods": @[ @"info" ] },
    @{ @"name": @"NetInfo",    @"methods": @[ @"status" ] },
    @{ @"name": @"Haptics",    @"methods": @[ @"impact", @"notification", @"selection" ] },
    @{ @"name": @"Brightness", @"methods": @[ @"get" ] },
  ];
  for (NSDictionary *cap in caps) {
    NSString *name = cap[@"name"];
    Class cls = [self resolveModuleClassNamed:name];
    if (cls == Nil) { continue; }
    id<CanopyModule> module = [[cls alloc] init];

    for (NSString *method in cap[@"methods"]) {
      BOOL known = [module invokeMethod:method
                                   args:@"{}"
                                 callId:[NSString stringWithFormat:@"c-%@-%@", name, method]
                               complete:^(NSString *e, NSString *r) { /* resolves later */ }];
      XCTAssertTrue(known,
                    @"Canopy%@Module must ACCEPT its .can method '%@' (return YES, not ModuleNotFound)",
                    name, method);
    }
  }
}

// ---- DeviceInfo.info is fully SYNCHRONOUS + device-free, so pin its real output here -----------

- (void)testDeviceInfoInfoResolvesTheContractShape {
  // DeviceInfo reads uname/UIDevice/NSProcessInfo — all available on the build host with no app,
  // and it resolves synchronously inside -invokeMethod:. So we can assert its REAL wire payload.
  Class cls = [self resolveModuleClassNamed:@"DeviceInfo"];
  XCTAssertNotNil(cls);
  id<CanopyModule> module = [[cls alloc] init];

  __block NSString *resultJson = nil;
  __block NSString *errJson = nil;
  BOOL known = [module invokeMethod:@"info"
                               args:@"{}"
                             callId:@"c-info"
                           complete:^(NSString *e, NSString *r) { errJson = e; resultJson = r; }];
  XCTAssertTrue(known);
  XCTAssertNil(errJson, @"DeviceInfo.info must resolve, not reject, on the build host");
  XCTAssertNotNil(resultJson, @"DeviceInfo.info must produce a result payload");

  NSData *data = [resultJson dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *info = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  XCTAssertTrue([info isKindOfClass:[NSDictionary class]]);
  // The exact field set DeviceInfo.can decodes (Info: model/manufacturer/systemVersion/sdkInt).
  XCTAssertTrue([info[@"model"] isKindOfClass:[NSString class]], @"info.model is a string");
  XCTAssertEqualObjects(info[@"manufacturer"], @"Apple", @"iOS manufacturer is Apple");
  XCTAssertTrue([info[@"systemVersion"] isKindOfClass:[NSString class]], @"info.systemVersion string");
  XCTAssertTrue([info[@"sdkInt"] isKindOfClass:[NSNumber class]], @"info.sdkInt is an Int");
  XCTAssertGreaterThan([info[@"sdkInt"] integerValue], 0, @"sdkInt is the major OS version (>0)");
}

// ---- The shared reject/resolve wire shape every twin uses (pure, no UIKit) ---------------------

- (void)testRejectHelperBuildsTheCodeMessageShape {
  __block NSString *errJson = nil;
  __block NSString *resJson = nil;
  CanopyComplete sink = ^(NSString *e, NSString *r) { errJson = e; resJson = r; };

  CanopyReject(sink, @"rejected", @"boom");
  XCTAssertNotNil(errJson, @"reject sets errJson (the failure leg)");
  XCTAssertNil(resJson,    @"reject leaves resultJson nil");
  NSDictionary *err =
      [NSJSONSerialization JSONObjectWithData:[errJson dataUsingEncoding:NSUTF8StringEncoding]
                                      options:0 error:nil];
  XCTAssertEqualObjects(err[@"code"], @"rejected", @"the error carries the code");
  XCTAssertEqualObjects(err[@"message"], @"boom", @"the error carries the message");
}

- (void)testResolveNullIsTheLiteralNull {
  // The {} -> null methods (Vibration.vibrate/cancel, Haptics.*) resolve the literal JSON null.
  __block NSString *errJson = @"unset";
  __block NSString *resJson = nil;
  CanopyComplete sink = ^(NSString *e, NSString *r) { errJson = e; resJson = r; };
  CanopyResolveNull(sink);
  XCTAssertNil(errJson, @"resolveNull is a success (errJson nil)");
  XCTAssertEqualObjects(resJson, @"null", @"resolveNull emits the literal JSON null");
}

// ================================================================================================
// L-I2 — Lumen capability parity (Photos/Album/ShareImage/StorageSecure/Notify/Image).
//
// These are the capability twins the Lumen litmus flow (examples/lumen-probe/src/Main.can) drives:
// pick → restore → save → share → store → notify. IOS-7 above pinned the permission-free hardware
// twins; this block pins the DEVICE-FREE legs of the Lumen set the same way — protocol conformance,
// the unknown→NO / known→YES dispatch contract for EACH .can method these modules expose, and the
// two legs that are fully synchronous + library-free (StorageSecure local round-trip; the
// unknown-handle reject that exercises the consumer modules' arg-parse path). The real device
// behaviour (a PHPicker, a gallery save into the named album, a share sheet, a posted notification)
// is exercised on a Simulator/device by CanopyHostUITests; this is its cheap device-free net.
// ================================================================================================

// Every method name each Lumen capability's .can contract calls — the parity-of-methods set the
// iOS twin MUST accept (return YES) and route. Mirrors check-ios-capability-parity.sh step (4),
// pinned here so a dropped/renamed method fails on the build host BEFORE a Simulator run.
- (NSDictionary<NSString *, NSArray<NSString *> *> *)lumenCapabilityMethods {
  return @{
    @"Photos":        @[ @"pick", @"release" ],
    @"Album":         @[ @"save" ],
    @"ShareImage":    @[ @"image" ],
    @"StorageSecure": @[ @"get", @"set", @"remove" ],
    @"Notify":        @[ @"show" ],
    @"Image":         @[ @"decode", @"dimensions", @"resize", @"encodeToFile", @"composite", @"release" ],
  };
}

- (void)testEveryLumenTwinResolvesConformsAndNamesItself {
  for (NSString *name in [self lumenCapabilityMethods]) {
    Class cls = [self resolveModuleClassNamed:name];
    XCTAssertNotNil(cls, @"the Lumen twin Canopy%@Module must resolve by name (boot registrar path)",
                    name);
    XCTAssertTrue([cls conformsToProtocol:@protocol(CanopyModule)],
                  @"Canopy%@Module must adopt <CanopyModule>", name);
    id<CanopyModule> module = [[cls alloc] init];
    XCTAssertNotNil(module, @"Canopy%@Module must have a no-arg -init (registrar requirement)", name);
    XCTAssertEqualObjects([module moduleName], name,
                          @"Canopy%@Module -moduleName must be the capability name", name);
  }
}

- (void)testLumenTwinsAcceptTheirCanMethodsAndRejectUnknown {
  NSDictionary<NSString *, NSArray<NSString *> *> *caps = [self lumenCapabilityMethods];
  for (NSString *name in caps) {
    Class cls = [self resolveModuleClassNamed:name];
    if (cls == Nil) { continue; }  // covered as a failure by the conformance test above
    id<CanopyModule> module = [[cls alloc] init];

    // Every .can-declared method is ACCEPTED (return YES → dispatched, not ModuleNotFound).
    for (NSString *method in caps[name]) {
      BOOL known = [module invokeMethod:method
                                   args:@"{}"
                                 callId:[NSString stringWithFormat:@"c-%@-%@", name, method]
                               complete:^(NSString *e, NSString *r) { /* resolves later */ }];
      XCTAssertTrue(known,
                    @"Canopy%@Module must ACCEPT its .can method '%@' (return YES, not ModuleNotFound)",
                    name, method);
    }

    // An unknown method is REJECTED at the dispatcher (return NO → ModuleNotFound).
    BOOL unknown = [module invokeMethod:@"noSuchMethod"
                                   args:@"{}"
                                 callId:@"c-unknown"
                               complete:^(NSString *e, NSString *r) { /* must never fire */ }];
    XCTAssertFalse(unknown,
                   @"Canopy%@Module must return NO for an unknown method (→ ModuleNotFound)", name);
  }
}

// StorageSecure.local is NSUserDefaults-backed — fully synchronous-capable + device-free, so we can
// pin a real set→get→remove→get round-trip on the build host (the same contract AlbumModule's
// entitlement cache relies on). The module dispatches on a serial queue, so we wait on each step.
- (void)testStorageSecureLocalRoundTripOnBuildHost {
  Class cls = [self resolveModuleClassNamed:@"StorageSecure"];
  XCTAssertNotNil(cls);
  id<CanopyModule> module = [[cls alloc] init];

  NSString *key = [NSString stringWithFormat:@"li2-rt-%@", [[NSUUID UUID] UUIDString]];

  // set ns=local
  XCTestExpectation *setDone = [self expectationWithDescription:@"set"];
  NSString *setArgs = [NSString stringWithFormat:
      @"{\"ns\":\"local\",\"key\":\"%@\",\"value\":\"active-2026\"}", key];
  __block NSString *setErr = @"unset";
  [module invokeMethod:@"set" args:setArgs callId:@"c-set"
              complete:^(NSString *e, NSString *r) { setErr = e; [setDone fulfill]; }];
  [self waitForExpectations:@[ setDone ] timeout:5];
  XCTAssertNil(setErr, @"StorageSecure.set(local) must succeed on the build host");

  // get ns=local → the stored value
  XCTestExpectation *getDone = [self expectationWithDescription:@"get"];
  NSString *getArgs = [NSString stringWithFormat:@"{\"ns\":\"local\",\"key\":\"%@\"}", key];
  __block NSString *getRes = nil;
  [module invokeMethod:@"get" args:getArgs callId:@"c-get"
              complete:^(NSString *e, NSString *r) { getRes = r; [getDone fulfill]; }];
  [self waitForExpectations:@[ getDone ] timeout:5];
  NSDictionary *got = [NSJSONSerialization
      JSONObjectWithData:[getRes dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
  XCTAssertEqualObjects(got[@"value"], @"active-2026", @"get returns the value that was set");

  // remove, then get → null (absent key)
  XCTestExpectation *rmDone = [self expectationWithDescription:@"remove"];
  [module invokeMethod:@"remove" args:getArgs callId:@"c-rm"
              complete:^(NSString *e, NSString *r) { [rmDone fulfill]; }];
  [self waitForExpectations:@[ rmDone ] timeout:5];

  XCTestExpectation *get2 = [self expectationWithDescription:@"get-after-remove"];
  __block NSString *get2Res = nil;
  [module invokeMethod:@"get" args:getArgs callId:@"c-get2"
              complete:^(NSString *e, NSString *r) { get2Res = r; [get2 fulfill]; }];
  [self waitForExpectations:@[ get2 ] timeout:5];
  NSDictionary *gone = [NSJSONSerialization
      JSONObjectWithData:[get2Res dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
  XCTAssertEqualObjects(gone[@"value"], [NSNull null], @"a removed key reads back as JSON null");
}

// Album.save now honors the `album` name (L-I2 parity with AlbumModule.java's Pictures/<album>).
// We can't reach the Photo Library on the build host, but we CAN pin that the new `album` arg flows
// through the dispatcher and that an unknown image handle rejects cleanly (the arg-parse + consumer
// path the named-album save shares). A real named-album save is a Simulator/device leg.
- (void)testAlbumSaveAcceptsAlbumArgAndRejectsUnknownHandle {
  Class cls = [self resolveModuleClassNamed:@"Album"];
  XCTAssertNotNil(cls);
  id<CanopyModule> module = [[cls alloc] init];

  XCTestExpectation *done = [self expectationWithDescription:@"album-save-bad-handle"];
  __block NSString *errJson = nil;
  __block NSString *resJson = @"unset";
  // image:0 is never a live blob handle → the consumer GET fails and the module rejects, all WITHOUT
  // touching PHPhotoLibrary. The `album` field is the Lumen wire shape; this proves it parses.
  BOOL known = [module invokeMethod:@"save"
                               args:@"{\"album\":\"Lumen\",\"image\":0,\"format\":\"jpeg\"}"
                             callId:@"c-album-save"
                           complete:^(NSString *e, NSString *r) {
                             errJson = e; resJson = r; [done fulfill];
                           }];
  XCTAssertTrue(known, @"Album must ACCEPT save (return YES) even with the named-album arg");
  [self waitForExpectations:@[ done ] timeout:5];
  XCTAssertNotNil(errJson, @"an unknown image handle rejects (no Photo Library access needed)");
  XCTAssertNil(resJson, @"a rejection leaves resultJson nil");
  NSDictionary *err = [NSJSONSerialization
      JSONObjectWithData:[errJson dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
  XCTAssertEqualObjects(err[@"code"], @"rejected", @"unknown-handle save is a clean rejection");
}

@end

// ================================================================================================
// L-I5 — StoreKit 2 paywall (canopy/billing on iOS).
//
// Billing is the ONE capability that is NOT a parity twin in the §4.2 by-name registrar's eyes — it
// is the bespoke streaming module (entitlementChanges) whose one-shots (getProducts/purchase/restore)
// run against StoreKit 2 (CanopyBillingStoreKit2.swift) with a StoreKit-1 / fake-store fallback. The
// REAL store flow (a purchase sheet, a verified Transaction, a restore against the App Store) is
// Apple- and store-config-gated and runs on a Simulator with the Products.storekit config (or a real
// sandbox device) under CanopyHostUITests; the DEVICE-FREE legs of "the Billing module is wired
// correctly" are pinned here the same way every other capability's are:
//
//   • PROTOCOL conformance — CanopyBillingModule resolves by name (the boot registrar path), adopts
//     <CanopyModule>, and names itself "Billing".
//   • DISPATCH contract — getProducts/purchase/restore/entitlementChanges are ACCEPTED (return YES);
//     an unknown method returns NO (→ ModuleNotFound). This is the exact bool contract the streaming
//     bridge relies on.
//   • WIRE shapes — getProducts ALWAYS resolves a non-empty products array carrying the contract
//     fields (id/title/description/priceText/priceMicros/currencyCode), even with no store configured
//     (the fake/fallback catalog), so the paywall can always render a price; a re-purchase while
//     already entitled rejects "already_owned"; a non-existent product rejects "item_unavailable".
//   • restore — resolves the {isActive,productId} Entitlement shape device-free.
//
// The class is a file-private @interface inside CanopyBillingModule.mm, so — like the parity twins —
// we resolve it by NSClassFromString (the boot registrar path) rather than importing a header.
// ================================================================================================

@interface CanopyCapabilityParityTests (Billing)
@end

@implementation CanopyCapabilityParityTests (Billing)

- (id<CanopyModule>)billingModule {
  Class cls = [self resolveModuleClassNamed:@"Billing"];
  XCTAssertNotNil(cls, @"CanopyBillingModule must resolve by name (the boot registrar path)");
  if (cls == Nil) { return nil; }
  XCTAssertTrue([cls conformsToProtocol:@protocol(CanopyModule)],
                @"CanopyBillingModule must adopt <CanopyModule>");
  id<CanopyModule> module = [[cls alloc] init];
  XCTAssertNotNil(module, @"CanopyBillingModule must have a no-arg -init (registrar requirement)");
  XCTAssertEqualObjects([module moduleName], @"Billing",
                        @"-moduleName must be the capability name routed by __canopy_call");
  return module;
}

- (void)testBillingResolvesConformsAndNamesItself {
  (void)[self billingModule];
}

// The dispatch (YES/NO) contract: every .can-declared Billing method is accepted; an unknown method
// returns NO. entitlementChanges (the Sub) is accepted too — the streaming bridge keeps it open.
- (void)testBillingDispatchContract {
  id<CanopyModule> module = [self billingModule];
  if (module == nil) { return; }

  for (NSString *method in @[ @"getProducts", @"purchase", @"restore", @"entitlementChanges" ]) {
    BOOL known = [module invokeMethod:method
                                 args:(([method isEqualToString:@"purchase"])
                                         ? @"{\"productId\":\"lifetime_unlock\"}" : @"{}")
                               callId:[@"c-bill-" stringByAppendingString:method]
                             complete:^(NSString *e, NSString *r) { /* resolves later / streams */ }];
    XCTAssertTrue(known, @"Billing must ACCEPT its .can method '%@' (return YES, not ModuleNotFound)",
                  method);
  }

  BOOL unknown = [module invokeMethod:@"noSuchMethod" args:@"{}" callId:@"c-bill-unknown"
                             complete:^(NSString *e, NSString *r) { /* must never fire */ }];
  XCTAssertFalse(unknown, @"Billing must return NO for an unknown method (→ ModuleNotFound)");
}

// getProducts ALWAYS resolves a non-empty catalog with the contract product fields — even with no
// store configured (the fake/fallback catalog), so the paywall can always render a price. On the
// build host StoreKit returns no products, so this exercises the fallback path device-free.
- (void)testBillingGetProductsResolvesTheContractCatalog {
  id<CanopyModule> module = [self billingModule];
  if (module == nil) { return; }

  XCTestExpectation *done = [self expectationWithDescription:@"getProducts"];
  __block NSString *errJson = @"unset";
  __block NSString *resJson = nil;
  [module invokeMethod:@"getProducts" args:@"{}" callId:@"c-bill-products"
              complete:^(NSString *e, NSString *r) { errJson = e; resJson = r; [done fulfill]; }];
  [self waitForExpectations:@[ done ] timeout:10];

  XCTAssertNil(errJson, @"getProducts must resolve, never reject (the paywall always needs a price)");
  XCTAssertNotNil(resJson, @"getProducts must produce a result payload");
  NSDictionary *out = [NSJSONSerialization
      JSONObjectWithData:[resJson dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
  NSArray *products = out[@"products"];
  XCTAssertTrue([products isKindOfClass:[NSArray class]] && products.count > 0,
                @"getProducts resolves a non-empty products array (fallback catalog on the build host)");
  NSDictionary *p = products.firstObject;
  XCTAssertEqualObjects(p[@"id"], @"lifetime_unlock", @"the product id is the lifetime unlock");
  for (NSString *field in @[ @"id", @"title", @"description", @"priceText", @"priceMicros", @"currencyCode" ]) {
    XCTAssertNotNil(p[field], @"the Product carries the contract field '%@'", field);
  }
  XCTAssertTrue([p[@"priceMicros"] isKindOfClass:[NSNumber class]], @"priceMicros is a number");
}

// A non-existent product rejects "item_unavailable" — the arg-validation leg, fully device-free
// (it never touches StoreKit, rejecting before any store call).
- (void)testBillingPurchaseRejectsUnknownProduct {
  id<CanopyModule> module = [self billingModule];
  if (module == nil) { return; }

  XCTestExpectation *done = [self expectationWithDescription:@"purchase-bad-product"];
  __block NSString *errJson = nil;
  __block NSString *resJson = @"unset";
  BOOL known = [module invokeMethod:@"purchase"
                               args:@"{\"productId\":\"no_such_product\"}"
                             callId:@"c-bill-bad"
                           complete:^(NSString *e, NSString *r) {
                             errJson = e; resJson = r; [done fulfill];
                           }];
  XCTAssertTrue(known, @"purchase is accepted (return YES) even for a bad product id");
  [self waitForExpectations:@[ done ] timeout:5];
  XCTAssertNotNil(errJson, @"an unknown product id rejects (no StoreKit access needed)");
  XCTAssertNil(resJson, @"a rejection leaves resultJson nil");
  NSDictionary *err = [NSJSONSerialization
      JSONObjectWithData:[errJson dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
  XCTAssertEqualObjects(err[@"code"], @"item_unavailable",
                        @"a non-existent product id is item_unavailable (the wire code Billing.can maps)");
}

// restore resolves the {isActive,productId} Entitlement shape. On the build host with no entitlement
// it resolves isActive=false — the device-free leg of the restore contract.
- (void)testBillingRestoreResolvesTheEntitlementShape {
  id<CanopyModule> module = [self billingModule];
  if (module == nil) { return; }

  XCTestExpectation *done = [self expectationWithDescription:@"restore"];
  __block NSString *errJson = @"unset";
  __block NSString *resJson = nil;
  [module invokeMethod:@"restore" args:@"{}" callId:@"c-bill-restore"
              complete:^(NSString *e, NSString *r) { errJson = e; resJson = r; [done fulfill]; }];
  [self waitForExpectations:@[ done ] timeout:10];

  XCTAssertNil(errJson, @"restore must resolve, never reject");
  NSDictionary *ent = [NSJSONSerialization
      JSONObjectWithData:[resJson dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
  XCTAssertTrue([ent[@"isActive"] isKindOfClass:[NSNumber class]],
                @"restore resolves an Entitlement with an isActive Bool");
  XCTAssertNotNil(ent[@"productId"], @"restore resolves an Entitlement with a productId field");
}

@end

// ================================================================================================
// L-I3 — RestoreEngine on iOS (Core ML / ANE).
//
// RestoreEngine is the ONE capability that is NOT a name-registered id<CanopyModule>: it is the
// Core ML restore module reached through the weak C++ factory canopy::CanopyMakeCoreMLRestoreModule
// (CanopyModuleHost.mm -registerAll, step 2). The ObjC class CanopyRestoreEngineModule still adopts
// <CanopyModule> (the factory wraps it in a C++ NativeModule via RestoreEngineObjCModule), so the
// DEVICE-FREE legs of "the Core ML restore path is wired correctly" are pinnable here exactly like
// every other capability — protocol conformance, the dispatch (YES/NO) contract, deviceTier's ANE
// report, the no-model / unknown-handle rejections, AND the weak factory producing a non-null
// NativeModule named "RestoreEngine". The REAL Core ML inference on the ANE (load restore.mlpackage,
// predict, write the super-res blob) is Apple-only and is exercised on a device by CanopyHostUITests;
// the converter's arithmetic equivalence to the Android ORT path is gated device-free on Linux by
// the convert_restore.py rebuild (scripts/check-ios-restore-coreml.sh).
//
// The class is a file-private @interface inside CanopyRestoreEngineModule.mm, so — like the parity
// twins — we resolve it by NSClassFromString rather than importing a header. -setModelURL: is part
// of that private @interface; we exercise it only through the public <CanopyModule> surface here.
// ================================================================================================

// The weak factory the host reaches for. Declared weak (matches CanopyModuleHost.mm:59-60) so this
// test bundle links whether or not the module .mm is in the target; the test fails with a clear
// message if the symbol is null rather than failing to link. (canopy::NativeModule is the complete
// type from CanopyModules.h, included above.)
namespace canopy {
__attribute__((weak)) std::shared_ptr<NativeModule>
CanopyMakeCoreMLRestoreModule(const std::string& modelPath);
}  // namespace canopy

@interface CanopyCapabilityParityTests (RestoreEngine)
@end

@implementation CanopyCapabilityParityTests (RestoreEngine)

- (void)testRestoreEngineResolvesConformsAndNamesItself {
  Class cls = [self resolveModuleClassNamed:@"RestoreEngine"];
  XCTAssertNotNil(cls, @"CanopyRestoreEngineModule must resolve by name (the boot factory path)");
  XCTAssertTrue([cls conformsToProtocol:@protocol(CanopyModule)],
                @"CanopyRestoreEngineModule must adopt <CanopyModule>");
  id<CanopyModule> module = [[cls alloc] init];
  XCTAssertNotNil(module, @"CanopyRestoreEngineModule must have a no-arg -init");
  XCTAssertEqualObjects([module moduleName], @"RestoreEngine",
                        @"-moduleName must be the capability name routed by __canopy_call");
}

// deviceTier is fully synchronous + device-free and resolves INSIDE -invokeMethod:, so its real
// payload is pinnable on the build host: it reports the strongest compute unit ("ane" on iOS 13+).
- (void)testRestoreEngineDeviceTierResolvesAne {
  Class cls = [self resolveModuleClassNamed:@"RestoreEngine"];
  XCTAssertNotNil(cls);
  id<CanopyModule> module = [[cls alloc] init];

  __block NSString *errJson = @"unset";
  __block NSString *resJson = nil;
  BOOL known = [module invokeMethod:@"deviceTier" args:@"{}" callId:@"c-tier"
                           complete:^(NSString *e, NSString *r) { errJson = e; resJson = r; }];
  XCTAssertTrue(known, @"deviceTier is a known method (return YES)");
  XCTAssertNil(errJson, @"deviceTier resolves, never rejects");
  NSDictionary *tier = [NSJSONSerialization
      JSONObjectWithData:[resJson dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
  XCTAssertEqualObjects(tier[@"tier"], @"ane",
                        @"on iOS 13+ the Core ML restore reports the Neural Engine tier");
}

// The dispatch (YES/NO) contract: the .can-declared methods (process/release/deviceTier) are
// accepted, an unknown method returns NO (→ ModuleNotFound). Mirrors the parity-twin test.
- (void)testRestoreEngineDispatchContract {
  Class cls = [self resolveModuleClassNamed:@"RestoreEngine"];
  XCTAssertNotNil(cls);
  id<CanopyModule> module = [[cls alloc] init];

  for (NSString *method in @[ @"deviceTier", @"release" ]) {
    BOOL known = [module invokeMethod:method args:@"{}" callId:[@"c-" stringByAppendingString:method]
                             complete:^(NSString *e, NSString *r) { /* resolves later */ }];
    XCTAssertTrue(known, @"RestoreEngine must ACCEPT its .can method '%@'", method);
  }
  // process is accepted too (it dispatches onto the serial queue and rejects later without a model).
  BOOL processKnown = [module invokeMethod:@"process"
                                      args:@"{\"image\":0,\"options\":{\"strength\":1}}"
                                    callId:@"c-process-accept"
                                  complete:^(NSString *e, NSString *r) { /* later */ }];
  XCTAssertTrue(processKnown, @"RestoreEngine must ACCEPT process (return YES, dispatched)");

  BOOL unknown = [module invokeMethod:@"noSuchMethod" args:@"{}" callId:@"c-unknown"
                             complete:^(NSString *e, NSString *r) { /* must never fire */ }];
  XCTAssertFalse(unknown, @"RestoreEngine must return NO for an unknown method (→ ModuleNotFound)");
}

// process with an unknown blob handle rejects cleanly — the arg-parse + blob-lookup path runs on
// the serial queue and never touches Core ML (the input blob is missing before any model run), so
// this is fully device-free. Proves a bad call fails the ONE call, not the whole capability.
- (void)testRestoreEngineProcessRejectsUnknownHandle {
  Class cls = [self resolveModuleClassNamed:@"RestoreEngine"];
  XCTAssertNotNil(cls);
  id<CanopyModule> module = [[cls alloc] init];

  XCTestExpectation *done = [self expectationWithDescription:@"restore-bad-handle"];
  __block NSString *errJson = nil;
  __block NSString *resJson = @"unset";
  BOOL known = [module invokeMethod:@"process"
                              args:@"{\"image\":999999,\"options\":{\"strength\":1}}"
                            callId:@"c-restore-bad"
                          complete:^(NSString *e, NSString *r) {
                            errJson = e; resJson = r; [done fulfill];
                          }];
  XCTAssertTrue(known, @"process is accepted (return YES) even for a bad handle");
  [self waitForExpectations:@[ done ] timeout:5];
  XCTAssertNotNil(errJson, @"an unknown rgba8 handle rejects (no Core ML / model access needed)");
  XCTAssertNil(resJson, @"a rejection leaves resultJson nil");
  NSDictionary *err = [NSJSONSerialization
      JSONObjectWithData:[errJson dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
  XCTAssertEqualObjects(err[@"code"], @"rejected", @"unknown-handle process is a clean rejection");
}

// The weak C++ factory the host reaches (CanopyModuleHost.mm step 2) must produce a NON-NULL
// NativeModule named "RestoreEngine" — the audit's dead-weak-symbol defect (the symbol was declared
// but never defined, so RestoreEngine was silently absent on iOS). Passing an empty model path is
// the no-model case: the module still constructs (process() rejects with "no model bytes set"
// rather than the capability being missing). This is the link-level proof the symbol is now strong.
- (void)testWeakFactoryProducesNonNullRestoreModule {
  if (canopy::CanopyMakeCoreMLRestoreModule == nullptr) {
    XCTFail(@"canopy::CanopyMakeCoreMLRestoreModule is null at link — the strong definition in "
            @"CanopyRestoreEngineModule.mm is not in the test target (the dead-weak-symbol defect)");
    return;
  }
  std::shared_ptr<canopy::NativeModule> mod = canopy::CanopyMakeCoreMLRestoreModule(std::string());
  XCTAssertTrue(mod != nullptr,
                @"the Core ML restore factory must NEVER return null — it self-handles a missing "
                @"model (process rejects) rather than leaving RestoreEngine absent");
  if (mod != nullptr) {
    XCTAssertEqual(mod->name(), std::string("RestoreEngine"),
                   @"the wrapped NativeModule must report name()==\"RestoreEngine\" so the registry "
                   @"routes __canopy_call(module=\"RestoreEngine\", …) to it");
  }
}

@end
