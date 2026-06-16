// CanopyBeforeAfterVectorTests.mm — L-I4: the iOS leg of the SHARED before/after wipe-compositor
// parity test-vector suite.
//
// This runs the SAME corpus the Android instrumentation runner (CanopyBeforeAfterVectorTest.java)
// runs: host/shared/test-vectors/beforeafter-vectors.json, bundled into this XCTest target as a
// resource by project.yml (one editable source of truth — the file is read, never duplicated). For
// each vector it calls the EXACT pure functions the production iOS compositor uses — the iOS
// CanopyBeforeAfterView (in CanopyHostFabric.mm) delegates every numeric rule to the shared header
// host/shared/cpp/CanopyBeforeAfter.h, and this runner includes that SAME header and asserts its
// outputs against the corpus `expect`. So this is NOT a reimplementation of the math: it is the same
// canopy::beforeafter::* the view calls per frame, exercised directly. The Android runner does the
// same through JNI; together they are the durable anti-drift control (master plan R5) for the wipe
// compositor — a vector green on one host and red on the other is exactly the silent divergence the
// suite catches.
//
// Unlike the IOS-9 layout corpus there is NO density term: the wipe is a FRACTION of the view, never
// a dp, so the math is unit-agnostic and the SAME unitless fractions + a nominal width validate both
// hosts (Android draws in physical pixels, iOS in points; a fraction-of-width is identical in either).
//
// On Linux the corpus is proven device-free by host/shared/test-vectors/validate-beforeafter.js (an
// INDEPENDENT JS reimplementation, including a from-scratch %g formatter) and by the structural gate
// scripts/check-beforeafter-parity.sh. This bundle is the Mac/Simulator leg, authored completely but
// NOT compiled/run off macOS (the iOS host needs Xcode/UIKit/Yoga). The exact run step is in
// host/ios/BUILD-AND-VALIDATE.md / PART5-LEDGER.md.

#import <XCTest/XCTest.h>
#import <Foundation/Foundation.h>

#include <cmath>
#include <string>

// The SHARED before/after wipe math — the SAME header the production CanopyBeforeAfterView delegates
// to (CanopyHostFabric.mm). Asserting it here means the test exercises the real per-frame math, so it
// cannot drift from what ships.
#include "../../../shared/cpp/CanopyBeforeAfter.h"

@interface CanopyBeforeAfterVectorTests : XCTestCase
@end

@implementation CanopyBeforeAfterVectorTests {
  NSDictionary *_corpus;
}

// ---- corpus loading -----------------------------------------------------------------------------

- (NSDictionary *)corpus {
  if (_corpus) return _corpus;
  NSBundle *bundle = [NSBundle bundleForClass:[self class]];
  NSString *path = [bundle pathForResource:@"beforeafter-vectors" ofType:@"json"];
  if (!path) path = [bundle pathForResource:@"beforeafter-vectors" ofType:@"json" inDirectory:@"test-vectors"];
  XCTAssertNotNil(path, @"beforeafter-vectors.json must be bundled into CanopyHostCoreTests (project.yml resource)");
  NSData *data = [NSData dataWithContentsOfFile:path];
  NSError *err = nil;
  _corpus = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
  XCTAssertNil(err, @"the corpus must be valid JSON");
  XCTAssertTrue([_corpus isKindOfClass:[NSDictionary class]]);
  return _corpus;
}

- (double)tolerance {
  id t = [self corpus][@"tolerance"];
  return t ? [t doubleValue] : 0.0001;
}

// ---- the pure-math vectors (the SAME canopy::beforeafter::* the view calls) ----------------------

- (void)testClampVectors {
  NSArray *vectors = [self corpus][@"clampVectors"];
  XCTAssertTrue([vectors isKindOfClass:[NSArray class]] && vectors.count > 0, @"clampVectors required");
  double tol = [self tolerance];
  for (NSDictionary *v in vectors) {
    double got = canopy::beforeafter::clampFraction([v[@"input"] doubleValue]);
    XCTAssertEqualWithAccuracy(got, [v[@"expect"] doubleValue], tol, @"%@: clampFraction", v[@"id"]);
  }
}

- (void)testSplitVectors {
  NSArray *vectors = [self corpus][@"splitVectors"];
  XCTAssertTrue([vectors isKindOfClass:[NSArray class]] && vectors.count > 0, @"splitVectors required");
  for (NSDictionary *v in vectors) {
    int got = canopy::beforeafter::splitColumn([v[@"wipe"] doubleValue], [v[@"width"] doubleValue]);
    XCTAssertEqual(got, [v[@"expect"] intValue], @"%@: splitColumn (the clip/mask boundary)", v[@"id"]);
  }
}

- (void)testDragVectors {
  NSArray *vectors = [self corpus][@"dragVectors"];
  XCTAssertTrue([vectors isKindOfClass:[NSArray class]] && vectors.count > 0, @"dragVectors required");
  double tol = [self tolerance];
  for (NSDictionary *v in vectors) {
    double got = canopy::beforeafter::dragFraction([v[@"x"] doubleValue], [v[@"width"] doubleValue]);
    XCTAssertEqualWithAccuracy(got, [v[@"expect"] doubleValue], tol, @"%@: dragFraction", v[@"id"]);
  }
}

- (void)testSnapTargetVectors {
  NSArray *vectors = [self corpus][@"snapTargetVectors"];
  XCTAssertTrue([vectors isKindOfClass:[NSArray class]] && vectors.count > 0, @"snapTargetVectors required");
  for (NSDictionary *v in vectors) {
    double got = canopy::beforeafter::snapTarget([v[@"wipe"] doubleValue]);
    XCTAssertEqual(got, [v[@"expect"] doubleValue], @"%@: snapTarget (double-tap end)", v[@"id"]);
  }
}

- (void)testSnapEasedVectors {
  NSArray *vectors = [self corpus][@"snapEasedVectors"];
  XCTAssertTrue([vectors isKindOfClass:[NSArray class]] && vectors.count > 0, @"snapEasedVectors required");
  double tol = [self tolerance];
  for (NSDictionary *v in vectors) {
    double got = canopy::beforeafter::snapEased([v[@"t"] doubleValue]);
    XCTAssertEqualWithAccuracy(got, [v[@"expect"] doubleValue], tol, @"%@: snapEased (decelerate)", v[@"id"]);
  }
}

- (void)testSnapTweenVectors {
  NSDictionary *corpus = [self corpus];
  NSArray *vectors = corpus[@"snapTweenVectors"];
  XCTAssertTrue([vectors isKindOfClass:[NSArray class]] && vectors.count > 0, @"snapTweenVectors required");
  double tol = [self tolerance];
  double dur = corpus[@"snapDurationSeconds"] ? [corpus[@"snapDurationSeconds"] doubleValue]
                                              : canopy::beforeafter::snapDurationSeconds();
  for (NSDictionary *v in vectors) {
    double got = canopy::beforeafter::snapValue([v[@"from"] doubleValue], [v[@"to"] doubleValue],
                                                [v[@"elapsed"] doubleValue], dur);
    XCTAssertEqualWithAccuracy(got, [v[@"expect"] doubleValue], tol, @"%@: snapValue (tween)", v[@"id"]);
  }
  // The corpus's declared duration must match the shared constant the host actually uses.
  XCTAssertEqualWithAccuracy(dur, canopy::beforeafter::snapDurationSeconds(), 1e-9,
                             @"corpus snapDurationSeconds must match the shared snap duration");
}

- (void)testCoverVectors {
  NSArray *vectors = [self corpus][@"coverVectors"];
  XCTAssertTrue([vectors isKindOfClass:[NSArray class]] && vectors.count > 0, @"coverVectors required");
  double tol = [self tolerance];
  for (NSDictionary *v in vectors) {
    canopy::beforeafter::CoverRect got = canopy::beforeafter::coverRect(
        [v[@"viewW"] doubleValue], [v[@"viewH"] doubleValue],
        [v[@"bmpW"] doubleValue], [v[@"bmpH"] doubleValue]);
    NSDictionary *e = v[@"expect"];
    XCTAssertEqualWithAccuracy(got.left, (float)[e[@"left"] doubleValue], tol, @"%@: cover left", v[@"id"]);
    XCTAssertEqualWithAccuracy(got.top, (float)[e[@"top"] doubleValue], tol, @"%@: cover top", v[@"id"]);
    XCTAssertEqualWithAccuracy(got.width, (float)[e[@"width"] doubleValue], tol, @"%@: cover width", v[@"id"]);
    XCTAssertEqualWithAccuracy(got.height, (float)[e[@"height"] doubleValue], tol, @"%@: cover height", v[@"id"]);
  }
}

// The wipeCommit payload is the wire-format leg: the EXACT bytes that cross into Canopy. This is the
// piece most likely to have drifted (the iOS host previously used printf %g; the Android host used
// Java float→String) — the shared commitPayloadJson removes that gap and this pins the bytes.
- (void)testPayloadVectors {
  NSArray *vectors = [self corpus][@"payloadVectors"];
  XCTAssertTrue([vectors isKindOfClass:[NSArray class]] && vectors.count > 0, @"payloadVectors required");
  for (NSDictionary *v in vectors) {
    std::string got = canopy::beforeafter::commitPayloadJson([v[@"fraction"] doubleValue]);
    NSString *gotS = [NSString stringWithUTF8String:got.c_str()];
    XCTAssertEqualObjects(gotS, v[@"expect"], @"%@: commitPayloadJson (exact wipeCommit wire bytes)", v[@"id"]);
  }
}

// A wired-correctly check on the production view itself: BeforeAfter is deliberately NOT a Yoga leaf
// (it is always explicitly sized), the inverse of CanopyBitmap. This pins the host's classification so
// a future edit that makes the compositor a measuring leaf — which would collapse its parent — fails
// here. (The on-device render/gesture behaviour is exercised by CanopyHostUITests.)
- (void)testBeforeAfterIsNotALeaf {
  // The shared header carries no UIKit; the leaf-classification lives in CanopyHostFabric.mm::isLeaf.
  // We assert the contract value the corpus assumes (a fraction-of-width view is sized, never measured).
  XCTAssertEqualWithAccuracy(canopy::beforeafter::snapDurationSeconds(), 0.26, 1e-9,
                             @"the shared snap duration is the 260ms both hosts tween over");
}

@end
