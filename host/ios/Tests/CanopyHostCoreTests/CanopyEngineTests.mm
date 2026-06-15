// CanopyEngineTests.mm — host-side unit tests for the parts of the Canopy iOS engine that run
// WITHOUT a rendered UIView, a jsi::Runtime, or a launched app (logic tests). They exercise the
// shared C++ currency (the BlobRegistry + the pure-pixel CanopyImage ops) and the ObjC streaming
// base's subscribe/emit/cancel bookkeeping — the cross-platform contracts whose correctness is
// platform-independent and so can be pinned on the build host before any Simulator run. The
// on-device render/event/capability behaviour is covered by CanopyHostUITests + the Part-5
// validation checklist (BUILD-AND-VALIDATE.md §5).
//
// This is an ObjC++ XCTest bundle (CanopyHostCoreTests in project.yml), linked against the
// CanopyHostCore static lib so globalBlobRegistry()/imageCompositeOver/CanopyStreamingModuleBase
// resolve at link.

#import <XCTest/XCTest.h>

#include "../../../shared/cpp/CanopyBlobs.h"   // BlobRegistry, Blob, globalBlobRegistry()
#include "../../../shared/cpp/CanopyImage.h"   // imageCompositeOver, imageWipeColumns

#import "../../CanopyHostCore/Bridge/CanopyStreamingModuleBase.h"  // streaming bookkeeping

using namespace canopy;

@interface CanopyEngineTests : XCTestCase
@end

@implementation CanopyEngineTests

// ---- BlobRegistry: refcount lifecycle (C1 §2.3, §7.2) -------------------------------------

- (void)testBlobRegistryRefcountLifecycle {
  BlobRegistry &reg = globalBlobRegistry();
  const size_t before = reg.liveCount();

  Blob b;
  b.kind = "rgba8";
  b.width = 2; b.height = 1;
  b.bytes = {1, 2, 3, 4, 5, 6, 7, 8};
  BlobHandle h = reg.put(std::move(b));

  XCTAssertGreaterThan(h, 0, @"put() mints a positive handle");
  XCTAssertEqual(reg.liveCount(), before + 1);

  auto got = reg.get(h);
  XCTAssertTrue(got != nullptr, @"get() returns the live blob");
  XCTAssertEqual(got->width, 2);
  XCTAssertEqual(got->bytes.size(), (size_t)8);

  reg.retain(h);            // two consumers
  reg.release(h);           // one drops — still alive
  XCTAssertTrue(reg.get(h) != nullptr, @"a retained handle survives one release");

  reg.release(h);           // last drop — freed
  XCTAssertTrue(reg.get(h) == nullptr, @"freed handle reads back null");
  XCTAssertEqual(reg.liveCount(), before, @"no handle leaks across the test");
}

- (void)testBlobRegistryUnknownHandleIsNull {
  XCTAssertTrue(globalBlobRegistry().get(0) == nullptr, @"handle 0 is never valid");
  XCTAssertTrue(globalBlobRegistry().get(999999) == nullptr);
}

// ---- CanopyImage: pure-pixel ops (C2) -----------------------------------------------------

- (void)testImageCompositeOverOpaqueReplaces {
  BlobRegistry &reg = globalBlobRegistry();

  Blob dst; dst.kind = "rgba8"; dst.width = 2; dst.height = 2; dst.bytes.assign(2 * 2 * 4, 0);
  Blob src; src.kind = "rgba8"; src.width = 2; src.height = 2; src.bytes.assign(2 * 2 * 4, 0);
  for (int px = 0; px < 4; ++px) {                 // fully-opaque coloured src
    src.bytes[px * 4 + 0] = 10;
    src.bytes[px * 4 + 1] = 20;
    src.bytes[px * 4 + 2] = 30;
    src.bytes[px * 4 + 3] = 255;
  }
  BlobHandle dh = reg.put(std::move(dst));
  BlobHandle sh = reg.put(std::move(src));

  BlobHandle out = imageCompositeOver(dh, sh, 0, 0);
  XCTAssertGreaterThan(out, 0);
  auto o = reg.get(out);
  XCTAssertTrue(o != nullptr);
  // source-over with alpha 255 ⇒ the source fully replaces the destination.
  XCTAssertEqual(o->bytes[0], 10);
  XCTAssertEqual(o->bytes[1], 20);
  XCTAssertEqual(o->bytes[2], 30);
  XCTAssertEqual(o->bytes[3], 255);

  reg.release(dh); reg.release(sh); reg.release(out);
}

- (void)testImageCompositeOverTransparentKeepsDestination {
  BlobRegistry &reg = globalBlobRegistry();
  Blob dst; dst.kind = "rgba8"; dst.width = 1; dst.height = 1; dst.bytes = {100, 110, 120, 255};
  Blob src; src.kind = "rgba8"; src.width = 1; src.height = 1; src.bytes = {0, 0, 0, 0};  // alpha 0
  BlobHandle dh = reg.put(std::move(dst));
  BlobHandle sh = reg.put(std::move(src));

  auto o = reg.get(imageCompositeOver(dh, sh, 0, 0));
  XCTAssertTrue(o != nullptr);
  XCTAssertEqual(o->bytes[0], 100, @"fully transparent src leaves dst untouched");
  XCTAssertEqual(o->bytes[1], 110);
  XCTAssertEqual(o->bytes[2], 120);
}

- (void)testImageWipeColumnsSplit {
  BlobRegistry &reg = globalBlobRegistry();
  Blob a; a.kind = "rgba8"; a.width = 2; a.height = 1; a.bytes = {1, 1, 1, 1, 1, 1, 1, 1};
  Blob b; b.kind = "rgba8"; b.width = 2; b.height = 1; b.bytes = {2, 2, 2, 2, 2, 2, 2, 2};
  BlobHandle ah = reg.put(std::move(a));
  BlobHandle bh = reg.put(std::move(b));

  auto o = reg.get(imageWipeColumns(ah, bh, /*splitX*/ 1));   // col 0 from a, col 1 from b
  XCTAssertTrue(o != nullptr);
  XCTAssertEqual(o->bytes[0], 1, @"left of split comes from a");
  XCTAssertEqual(o->bytes[4], 2, @"right of split comes from b");
}

- (void)testImageOpsRejectMismatchedKinds {
  BlobRegistry &reg = globalBlobRegistry();
  Blob a; a.kind = "jpeg"; a.width = 1; a.height = 1; a.bytes = {0, 0, 0, 0};
  BlobHandle ah = reg.put(std::move(a));
  XCTAssertEqual(imageCompositeOver(ah, ah, 0, 0), 0, @"non-rgba8 input returns handle 0");
}

// ---- CanopyStreamingModuleBase: subscribe / prime / emit / cancel (C1 §4.4) ---------------

- (void)testStreamingSubscribeEmitCancel {
  CanopyStreamingModuleBase *mod = [[CanopyStreamingModuleBase alloc] initWithModuleName:@"T"];
  [mod setStreamingMethods:@[ @"ticks" ]];
  [mod onMethod:@"ticks" handler:^(NSString *a, NSString *c, CanopyComplete comp) { /* observe */ }];

  __block NSMutableArray<NSString *> *got = [NSMutableArray array];
  CanopyComplete sink = ^(NSString *err, NSString *res) {
    XCTAssertNil(err);
    if (res) { [got addObject:res]; }
  };

  XCTAssertTrue([mod invokeMethod:@"ticks" args:@"{}" callId:@"c1" complete:sink],
                @"subscribe to a declared streaming method keeps the call open");
  [mod emitOnChannel:@"ticks" event:@"{\"n\":1}"];
  [mod emitOnChannel:@"ticks" event:@"{\"n\":2}"];
  XCTAssertEqualObjects(got, (@[ @"{\"n\":1}", @"{\"n\":2}" ]), @"both events reach the sink");

  [mod cancelCallId:@"c1"];
  [mod emitOnChannel:@"ticks" event:@"{\"n\":3}"];
  XCTAssertEqual(got.count, (NSUInteger)2, @"no events after cancel");
}

- (void)testStreamingPrimesLateSubscriber {
  CanopyStreamingModuleBase *mod = [[CanopyStreamingModuleBase alloc] initWithModuleName:@"T"];
  [mod setStreamingMethods:@[ @"state" ]];
  [mod onMethod:@"state" handler:^(NSString *a, NSString *c, CanopyComplete comp) {}];

  [mod invokeMethod:@"state" args:@"{}" callId:@"a" complete:^(NSString *e, NSString *r) {}];
  [mod emitOnChannel:@"state" event:@"{\"v\":1}"];        // cache the last value

  __block NSString *primed = nil;
  [mod invokeMethod:@"state" args:@"{}" callId:@"b" complete:^(NSString *e, NSString *r) {
    if (primed == nil) { primed = r; }                    // first delivery is the primed value
  }];
  XCTAssertEqualObjects(primed, @"{\"v\":1}", @"a fresh subscriber is primed with the last event");
}

- (void)testStreamingUnknownMethodReturnsNo {
  CanopyStreamingModuleBase *mod = [[CanopyStreamingModuleBase alloc] initWithModuleName:@"T"];
  XCTAssertFalse([mod invokeMethod:@"nope" args:@"{}" callId:@"c" complete:^(NSString *e, NSString *r) {}],
                 @"an unregistered method returns NO (→ ModuleNotFound)");
}

@end
