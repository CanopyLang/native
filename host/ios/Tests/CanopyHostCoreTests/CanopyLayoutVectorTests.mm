// CanopyLayoutVectorTests.mm — IOS-9: the iOS leg of the SHARED cross-platform layout/style
// test-vector suite.
//
// This runs the SAME corpus the Android instrumentation runner (CanopyLayoutVectorTest.java) runs:
// host/shared/test-vectors/layout-vectors.json, bundled into this XCTest target as a resource by
// project.yml (one editable source of truth — the file is read, never duplicated). For each vector it
// builds a real Yoga tree (the SAME <yoga/Yoga.h> the production host links — the iOS host computes
// layout with this exact engine in CanopyHostFabric.mm), applies the host's style->Yoga mapping,
// runs YGNodeCalculateLayout, and asserts every node's frame equals the corpus `expect` (in logical
// units). It is the iOS twin of the Android runner; together they are the durable anti-drift control
// (master plan R5 / IOS-9): a vector green on one host and red on the other is exactly the silent
// divergence the suite catches.
//
// The DELIBERATE platform divergence, normalized here: the Android host lays out in PHYSICAL PIXELS
// (dp * density) and the runner divides frames back by density; the iOS host lays out in POINTS with
// NO density multiply (dp == points, contract §0.3). So on iOS the corpus's logical units ARE the
// Yoga units (density == 1) — this runner asserts the points frame directly against `expect`, and the
// fact that the Android runner reaches the SAME logical numbers after its *density / /density
// round-trip is the parity proof. The corpus dims are integral so neither host has a rounding gap.
//
// This is the iOS analogue of CanopyValidationLedgerTests.mm: CanopyColor / the style->Yoga branch /
// justify+align live as file-private statics inside CanopyHostFabric.mm (they pull in UIKit), so —
// like the ledger test — this bundle carries a tiny, reviewable REFERENCE of each pure rule and runs
// the corpus through it on REAL Yoga. scripts/check-cross-platform-vectors.sh ties the host's own
// applyStyle/CanopyColor code paths to this same corpus so the reference and the host cannot drift
// unnoticed. Yoga itself is linked for real (the pod), so the LAYOUT leg is not a reference — it is
// the same engine the host uses.
//
// Bundle: an ObjC++ XCTest in CanopyHostCoreTests; runs on a Simulator via `xcodebuild test`. The
// exact Mac run step is in host/ios/PART5-LEDGER.md / BUILD-AND-VALIDATE.md; on Linux the corpus is
// proven device-free by host/shared/test-vectors/validate-vectors.js + the Android emulator run.

#import <XCTest/XCTest.h>
#import <Foundation/Foundation.h>

#include <yoga/Yoga.h>
#include <cmath>
#include <string>
#include <vector>

// =====================================================================================
// Reference of the host's pure rules (the SPEC the host must satisfy). Faithful, minimal ports of
// CanopyHostFabric.mm's file-private statics (applyStyle's geometric branch + justify/align + the
// CanopyColor CSS parser). check-cross-platform-vectors.sh asserts the host's code paths still carry
// each rule so this spec and the host cannot diverge. Yoga is REAL (the pod), not a reference.
// =====================================================================================

namespace vecspec {

static float asFloat(NSString *s, bool *ok) {
  if (s == nil) { *ok = false; return 0; }
  NSScanner *sc = [NSScanner scannerWithString:s];
  float v = 0;
  bool got = [sc scanFloat:&v] && [sc isAtEnd];
  *ok = got;
  return v;
}

static YGJustify justify(NSString *s) {
  if ([s isEqualToString:@"center"]) return YGJustifyCenter;
  if ([s isEqualToString:@"flex-end"]) return YGJustifyFlexEnd;
  if ([s isEqualToString:@"space-between"]) return YGJustifySpaceBetween;
  if ([s isEqualToString:@"space-around"]) return YGJustifySpaceAround;
  if ([s isEqualToString:@"space-evenly"]) return YGJustifySpaceEvenly;
  return YGJustifyFlexStart;
}

static YGAlign align(NSString *s) {
  if ([s isEqualToString:@"center"]) return YGAlignCenter;
  if ([s isEqualToString:@"flex-start"]) return YGAlignFlexStart;
  if ([s isEqualToString:@"flex-end"]) return YGAlignFlexEnd;
  if ([s isEqualToString:@"stretch"]) return YGAlignStretch;
  if ([s isEqualToString:@"baseline"]) return YGAlignBaseline;
  return YGAlignAuto;
}

static void setDimWidth(YGNodeRef y, NSString *s, float f, bool hasF) {
  if ([s hasSuffix:@"%"]) { float p = [[s substringToIndex:s.length - 1] floatValue]; YGNodeStyleSetWidthPercent(y, p); }
  else if ([s isEqualToString:@"auto"]) YGNodeStyleSetWidthAuto(y);
  else if (hasF) YGNodeStyleSetWidth(y, f);
}
static void setDimHeight(YGNodeRef y, NSString *s, float f, bool hasF) {
  if ([s hasSuffix:@"%"]) { float p = [[s substringToIndex:s.length - 1] floatValue]; YGNodeStyleSetHeightPercent(y, p); }
  else if ([s isEqualToString:@"auto"]) YGNodeStyleSetHeightAuto(y);
  else if (hasF) YGNodeStyleSetHeight(y, f);
}

// The geometric branch of CanopyHostFabric.mm::applyStyle (iOS: points, NO density multiply, so dp==v).
static void applyStyle(YGNodeRef y, NSDictionary *style) {
  for (NSString *key in style) {
    id raw = style[key];
    if ([raw isKindOfClass:[NSNull class]]) continue;  // (reset handled by the host; corpus never resets)
    NSString *s = [raw isKindOfClass:[NSString class]] ? raw
                : ([raw isKindOfClass:[NSNumber class]] ? [(NSNumber *)raw stringValue] : [raw description]);
    bool hasF = false;
    float f = asFloat(s, &hasF);

    if ([key isEqualToString:@"width"]) setDimWidth(y, s, f, hasF);
    else if ([key isEqualToString:@"height"]) setDimHeight(y, s, f, hasF);
    else if ([key isEqualToString:@"minWidth"]) { if (hasF) YGNodeStyleSetMinWidth(y, f); }
    else if ([key isEqualToString:@"minHeight"]) { if (hasF) YGNodeStyleSetMinHeight(y, f); }
    else if ([key isEqualToString:@"maxWidth"]) { if (hasF) YGNodeStyleSetMaxWidth(y, f); }
    else if ([key isEqualToString:@"maxHeight"]) { if (hasF) YGNodeStyleSetMaxHeight(y, f); }
    else if ([key isEqualToString:@"flex"]) { if (hasF) YGNodeStyleSetFlex(y, f); }
    else if ([key isEqualToString:@"flexGrow"]) { if (hasF) YGNodeStyleSetFlexGrow(y, f); }
    else if ([key isEqualToString:@"flexShrink"]) { if (hasF) YGNodeStyleSetFlexShrink(y, f); }
    else if ([key isEqualToString:@"flexBasis"]) { if (hasF) YGNodeStyleSetFlexBasis(y, f); }
    else if ([key isEqualToString:@"flexWrap"]) YGNodeStyleSetFlexWrap(y, [s isEqualToString:@"wrap"] ? YGWrapWrap : YGWrapNoWrap);
    else if ([key isEqualToString:@"gap"]) { if (hasF) YGNodeStyleSetGap(y, YGGutterAll, f); }
    else if ([key isEqualToString:@"padding"]) { if (hasF) YGNodeStyleSetPadding(y, YGEdgeAll, f); }
    else if ([key isEqualToString:@"paddingTop"]) { if (hasF) YGNodeStyleSetPadding(y, YGEdgeTop, f); }
    else if ([key isEqualToString:@"paddingBottom"]) { if (hasF) YGNodeStyleSetPadding(y, YGEdgeBottom, f); }
    else if ([key isEqualToString:@"paddingLeft"]) { if (hasF) YGNodeStyleSetPadding(y, YGEdgeLeft, f); }
    else if ([key isEqualToString:@"paddingRight"]) { if (hasF) YGNodeStyleSetPadding(y, YGEdgeRight, f); }
    else if ([key isEqualToString:@"paddingHorizontal"]) { if (hasF) YGNodeStyleSetPadding(y, YGEdgeHorizontal, f); }
    else if ([key isEqualToString:@"paddingVertical"]) { if (hasF) YGNodeStyleSetPadding(y, YGEdgeVertical, f); }
    else if ([key isEqualToString:@"margin"]) { if (hasF) YGNodeStyleSetMargin(y, YGEdgeAll, f); }
    else if ([key isEqualToString:@"marginTop"]) { if (hasF) YGNodeStyleSetMargin(y, YGEdgeTop, f); }
    else if ([key isEqualToString:@"marginBottom"]) { if (hasF) YGNodeStyleSetMargin(y, YGEdgeBottom, f); }
    else if ([key isEqualToString:@"marginLeft"]) { if (hasF) YGNodeStyleSetMargin(y, YGEdgeLeft, f); }
    else if ([key isEqualToString:@"marginRight"]) { if (hasF) YGNodeStyleSetMargin(y, YGEdgeRight, f); }
    else if ([key isEqualToString:@"marginHorizontal"]) { if (hasF) YGNodeStyleSetMargin(y, YGEdgeHorizontal, f); }
    else if ([key isEqualToString:@"marginVertical"]) { if (hasF) YGNodeStyleSetMargin(y, YGEdgeVertical, f); }
    else if ([key isEqualToString:@"top"]) { if (hasF) YGNodeStyleSetPosition(y, YGEdgeTop, f); }
    else if ([key isEqualToString:@"bottom"]) { if (hasF) YGNodeStyleSetPosition(y, YGEdgeBottom, f); }
    else if ([key isEqualToString:@"left"]) { if (hasF) YGNodeStyleSetPosition(y, YGEdgeLeft, f); }
    else if ([key isEqualToString:@"right"]) { if (hasF) YGNodeStyleSetPosition(y, YGEdgeRight, f); }
    else if ([key isEqualToString:@"position"]) YGNodeStyleSetPositionType(y, [s isEqualToString:@"absolute"] ? YGPositionTypeAbsolute : YGPositionTypeRelative);
    else if ([key isEqualToString:@"flexDirection"]) YGNodeStyleSetFlexDirection(y,
               [s isEqualToString:@"row"] ? YGFlexDirectionRow
             : [s isEqualToString:@"row-reverse"] ? YGFlexDirectionRowReverse
             : [s isEqualToString:@"column-reverse"] ? YGFlexDirectionColumnReverse
             : YGFlexDirectionColumn);
    else if ([key isEqualToString:@"justifyContent"]) YGNodeStyleSetJustifyContent(y, justify(s));
    else if ([key isEqualToString:@"alignItems"]) YGNodeStyleSetAlignItems(y, align(s));
    else if ([key isEqualToString:@"alignSelf"]) YGNodeStyleSetAlignSelf(y, align(s));
    else if ([key isEqualToString:@"aspectRatio"]) { if (hasF) YGNodeStyleSetAspectRatio(y, f); }
    else if ([key isEqualToString:@"display"]) YGNodeStyleSetDisplay(y, [s isEqualToString:@"none"] ? YGDisplayNone : YGDisplayFlex);
    // non-geometric keys (color/opacity/border) are asserted separately; they never touch Yoga.
  }
}

// CanopyColor reference (the CSS contract: #rgb/#rgba/#rrggbb/#rrggbbaa CSS alpha-LAST, rgb()/rgba(),
// hsl(), the named subset the corpus uses, transparent). The line-for-line twin of CanopyColor.mm.
struct RGBA { int r, g, b; float a; };
static int clampi(int v) { return v < 0 ? 0 : (v > 255 ? 255 : v); }
static int hx(NSString *h, NSUInteger a, NSUInteger b) {
  return (int)strtol([[h substringWithRange:NSMakeRange(a, b - a)] UTF8String], nullptr, 16);
}
static RGBA parseColor(NSString *in) {
  NSString *s = [in stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  if ([s isEqualToString:@"black"]) return {0, 0, 0, 1};
  if ([s isEqualToString:@"white"]) return {255, 255, 255, 1};
  if ([s isEqualToString:@"transparent"]) return {0, 0, 0, 0};
  if ([s hasPrefix:@"#"]) {
    NSString *h = [s substringFromIndex:1];
    switch (h.length) {
      case 3: return {hx(h,0,1)*17, hx(h,1,2)*17, hx(h,2,3)*17, 1.0f};
      case 4: return {hx(h,0,1)*17, hx(h,1,2)*17, hx(h,2,3)*17, hx(h,3,4)*17 / 255.0f};
      case 6: return {hx(h,0,2), hx(h,2,4), hx(h,4,6), 1.0f};
      case 8: return {hx(h,0,2), hx(h,2,4), hx(h,4,6), hx(h,6,8) / 255.0f};
      default: return {0, 0, 0, 0};
    }
  }
  if ([s hasPrefix:@"rgb"]) {
    NSRange o = [s rangeOfString:@"("], c = [s rangeOfString:@")"];
    NSString *inner = [s substringWithRange:NSMakeRange(o.location + 1, c.location - o.location - 1)];
    NSArray *p = [inner componentsSeparatedByString:@","];
    return {clampi([p[0] intValue]), clampi([p[1] intValue]), clampi([p[2] intValue]),
            p.count > 3 ? [p[3] floatValue] : 1.0f};
  }
  if ([s hasPrefix:@"hsl"]) {
    NSRange o = [s rangeOfString:@"("], c = [s rangeOfString:@")"];
    NSString *inner = [s substringWithRange:NSMakeRange(o.location + 1, c.location - o.location - 1)];
    NSArray *p = [inner componentsSeparatedByString:@","];
    float hDeg = fmodf(fmodf([p[0] floatValue], 360) + 360, 360);
    float sat = [[p[1] stringByReplacingOccurrencesOfString:@"%" withString:@""] floatValue] / 100.0f;
    float lig = [[p[2] stringByReplacingOccurrencesOfString:@"%" withString:@""] floatValue] / 100.0f;
    float ch = (1 - fabsf(2 * lig - 1)) * sat, hp = hDeg / 60, x = ch * (1 - fabsf(fmodf(hp, 2) - 1));
    float r1 = 0, g1 = 0, b1 = 0;
    if (hp < 1) { r1 = ch; g1 = x; } else if (hp < 2) { r1 = x; g1 = ch; } else if (hp < 3) { g1 = ch; b1 = x; }
    else if (hp < 4) { g1 = x; b1 = ch; } else if (hp < 5) { r1 = x; b1 = ch; } else { r1 = ch; b1 = x; }
    float m = lig - ch / 2;
    return {clampi((int)lroundf((r1 + m) * 255)), clampi((int)lroundf((g1 + m) * 255)),
            clampi((int)lroundf((b1 + m) * 255)), p.count > 3 ? [p[3] floatValue] : 1.0f};
  }
  return {0, 0, 0, 0};
}

}  // namespace vecspec

// =====================================================================================

@interface CanopyLayoutVectorTests : XCTestCase
@end

@implementation CanopyLayoutVectorTests {
  NSDictionary *_corpus;
}

// ---- corpus loading -----------------------------------------------------------------------------

- (NSDictionary *)corpus {
  if (_corpus) return _corpus;
  // The corpus is bundled as a resource of THIS test target (project.yml). Fall back to a couple of
  // path forms so the bundle layout cannot silently make the suite vacuous.
  NSBundle *bundle = [NSBundle bundleForClass:[self class]];
  NSString *path = [bundle pathForResource:@"layout-vectors" ofType:@"json"];
  if (!path) path = [bundle pathForResource:@"layout-vectors" ofType:@"json" inDirectory:@"test-vectors"];
  XCTAssertNotNil(path, @"layout-vectors.json must be bundled into CanopyHostCoreTests (project.yml resource)");
  NSData *data = [NSData dataWithContentsOfFile:path];
  NSError *err = nil;
  _corpus = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
  XCTAssertNil(err, @"the corpus must be valid JSON");
  XCTAssertTrue([_corpus isKindOfClass:[NSDictionary class]]);
  return _corpus;
}

// ---- Yoga tree construction (port of the host's applyStyle; Yoga is REAL) ------------------------

typedef struct { YGNodeRef node; NSDictionary *spec; NSString *path; } Binding;

- (YGNodeRef)buildNode:(NSDictionary *)spec
              bindings:(std::vector<Binding> &)out
                  path:(NSString *)path {
  YGNodeRef node = YGNodeNew();
  NSDictionary *style = spec[@"style"];
  if ([style isKindOfClass:[NSDictionary class]]) vecspec::applyStyle(node, style);
  out.push_back({node, spec, path});
  NSArray *children = spec[@"children"];
  if ([children isKindOfClass:[NSArray class]]) {
    for (NSUInteger i = 0; i < children.count; i++) {
      YGNodeRef child = [self buildNode:children[i] bindings:out path:[NSString stringWithFormat:@"%@/%lu", path, (unsigned long)i]];
      YGNodeInsertChild(node, child, i);
    }
  }
  return node;
}

// ---- the layout test ----------------------------------------------------------------------------

- (void)testLayoutVectorsMatchYogaInPoints {
  NSDictionary *corpus = [self corpus];
  NSArray *vectors = corpus[@"layoutVectors"];
  XCTAssertTrue([vectors isKindOfClass:[NSArray class]] && vectors.count > 0,
                @"the corpus must declare at least one layout vector");
  const double tol = [corpus[@"tolerance"] doubleValue] ?: 0.01;
  NSUInteger checked = 0;

  for (NSDictionary *v in vectors) {
    NSString *vid = v[@"id"];
    NSDictionary *root = v[@"root"];
    NSDictionary *tree = v[@"tree"];
    XCTAssertNotNil(root, @"%@: missing root", vid);
    XCTAssertNotNil(tree, @"%@: missing tree", vid);

    std::vector<Binding> bindings;
    YGNodeRef rootNode = [self buildNode:tree bindings:bindings path:@"root"];

    // iOS: points, NO density multiply (dp == points). Calculate against the available surface.
    YGNodeCalculateLayout(rootNode,
                          (float)[root[@"width"] doubleValue],
                          (float)[root[@"height"] doubleValue],
                          YGDirectionLTR);

    for (const Binding &b : bindings) {
      NSDictionary *expect = b.spec[@"expect"];
      XCTAssertNotNil(expect, @"%@ %@: a node has no 'expect' frame", vid, b.path);
      if (!expect) continue;
      float left = YGNodeLayoutGetLeft(b.node);
      float top = YGNodeLayoutGetTop(b.node);
      float width = YGNodeLayoutGetWidth(b.node);
      float height = YGNodeLayoutGetHeight(b.node);
      XCTAssertEqualWithAccuracy(left, (float)[expect[@"left"] doubleValue], tol,
                                 @"%@ %@: left (points)", vid, b.path);
      XCTAssertEqualWithAccuracy(top, (float)[expect[@"top"] doubleValue], tol,
                                 @"%@ %@: top (points)", vid, b.path);
      XCTAssertEqualWithAccuracy(width, (float)[expect[@"width"] doubleValue], tol,
                                 @"%@ %@: width (points)", vid, b.path);
      XCTAssertEqualWithAccuracy(height, (float)[expect[@"height"] doubleValue], tol,
                                 @"%@ %@: height (points)", vid, b.path);
      checked++;
    }
    YGNodeFreeRecursive(rootNode);  // frees the whole subtree (no Android-style "still has children")
  }
  XCTAssertGreaterThan(checked, (NSUInteger)0, @"at least one frame must have been checked");
}

// ---- the color test -----------------------------------------------------------------------------

- (void)testColorVectorsMatchCanopyColorContract {
  NSArray *vectors = [self corpus][@"colorVectors"];
  if (![vectors isKindOfClass:[NSArray class]]) return;
  const double tol = 0.01;
  for (NSDictionary *v in vectors) {
    vecspec::RGBA got = vecspec::parseColor(v[@"input"]);
    NSDictionary *e = v[@"expect"];
    XCTAssertEqual(got.r, [e[@"r"] intValue], @"%@ (%@) red", v[@"id"], v[@"input"]);
    XCTAssertEqual(got.g, [e[@"g"] intValue], @"%@ (%@) green", v[@"id"], v[@"input"]);
    XCTAssertEqual(got.b, [e[@"b"] intValue], @"%@ (%@) blue", v[@"id"], v[@"input"]);
    XCTAssertEqualWithAccuracy(got.a, (float)[e[@"a"] doubleValue], tol, @"%@ (%@) alpha", v[@"id"], v[@"input"]);
  }
}

// ---- style-effect vectors (the platform-neutral, non-Yoga effects) ------------------------------
// These pin the SHAPE of the style-effect contract on iOS: opacity is a 0..1 UIView.alpha; a uniform
// borderRadius is one CALayer.cornerRadius; a per-corner radius flips the host to its CAShapeLayer
// mask path. The on-device application is exercised by CanopyHostValidationTests.swift; here we assert
// the corpus's declared effects are internally consistent and the per-corner/uniform discrimination
// matches what CanopyHostFabric.mm::applyBorderRadius/setCorner decide.

- (void)testStyleEffectVectorsAreConsistent {
  NSArray *vectors = [self corpus][@"styleEffectVectors"];
  if (![vectors isKindOfClass:[NSArray class]]) return;
  for (NSDictionary *v in vectors) {
    NSDictionary *style = v[@"style"];
    NSDictionary *expect = v[@"expect"];
    XCTAssertNotNil(style, @"%@: missing style", v[@"id"]);
    XCTAssertNotNil(expect, @"%@: missing expect", v[@"id"]);

    if (expect[@"opacity"]) {
      // Absent opacity is fully opaque (1.0); present opacity is echoed straight through.
      float want = style[@"opacity"] ? [style[@"opacity"] floatValue] : 1.0f;
      XCTAssertEqualWithAccuracy([expect[@"opacity"] floatValue], want, 0.001,
                                 @"%@: opacity effect", v[@"id"]);
    }
    if (expect[@"perCorner"]) {
      // A per-corner radius is declared exactly when one of the borderXxxRadius keys is present —
      // the discriminator CanopyHostFabric.mm uses to switch from cornerRadius to the mask path.
      BOOL anyCorner = style[@"borderTopLeftRadius"] || style[@"borderTopRightRadius"]
                    || style[@"borderBottomRightRadius"] || style[@"borderBottomLeftRadius"];
      XCTAssertEqual([expect[@"perCorner"] boolValue], anyCorner,
                     @"%@: per-corner discrimination matches the style", v[@"id"]);
    }
  }
}

@end
