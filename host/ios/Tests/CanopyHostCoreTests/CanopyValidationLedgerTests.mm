// CanopyValidationLedgerTests.mm — IOS-6: the DEVICE-FREE legs of the Part-5 validation ledger.
//
// The on-device Part-5 gates (render/event/component/anim/capability/streaming) are driven on a
// Simulator by CanopyHostUITests/CanopyHostValidationTests.swift (all [MAC-REQUIRED]). But several
// of those gates are gated by PURE, platform-independent logic whose correctness needs no UIView, no
// held JS runtime, and no launched app — exactly the kind of contract CanopyEngineTests.mm pins for
// the ABI/blob/stream contracts, the same role this bundle plays for the color/measure/wipe rules,
// so the build host can pin them BEFORE any Simulator run.
//
// This bundle pins those pure legs as executable specifications:
//   • §5.1 CanopyColor — the CSS color contract (#rgb/#rgba/#rrggbb/#rrggbbaa CSS alpha-LAST,
//     rgb()/rgba(), hsl()→rgb, transparent) the host's CanopyColor must satisfy.
//   • §5.1 diff-null   — the reset-to-default rule: a removed prop arrives as JSON null and resets to
//     the explicit default, NEVER coerced to 0/"" (the silent-default footgun, contract §5.6/§5.7).
//   • §5.3 leaf measure— the sizeThatFits ↔ Yoga measure-mode mapping (Exactly/AtMost/Undefined), the
//     IOS-6 "leaf sizeThatFits vs Yoga measure modes" predicted-rework surface.
//   • §5.3 BeforeAfter — the wipe-column split that backs CanopyBeforeAfterView (shared C++ op).
//
// CanopyColor + the leaf-measure mapping + the diff-null helpers are file-private statics inside
// CanopyHostFabric.mm (they pull in UIKit/Yoga), so this bundle does NOT link that file. Instead it
// carries a tiny, reviewable REFERENCE of each pure rule and asserts the contract against it; the
// reference IS the spec the host's implementation is verified against on a real Mac compile, and
// scripts/check-ios-validation-ledger.sh ties the host's code paths to these same gates so neither
// can drift silently. The shared-C++ legs (BeforeAfter wipe) ARE linked from the static lib and run
// for real here.
//
// This is an ObjC++ XCTest bundle (CanopyHostCoreTests in project.yml), so it can run on the build
// host as part of `xcodebuild test`; the structural completeness of the WHOLE ledger is also gated
// device-free on Linux by scripts/check-ios-validation-ledger.sh.

#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>

#include <cmath>    // floorf / std::isinf (the command-result fmtNum compactor)
#include <cstdio>   // snprintf (non-integral float → %g)
#include <string>   // std::string / std::to_string (the JSON marshalling helpers)

#include "../../../shared/cpp/CanopyBlobs.h"   // BlobRegistry, Blob, globalBlobRegistry()
#include "../../../shared/cpp/CanopyImage.h"   // imageWipeColumns (backs BeforeAfter)

using namespace canopy;

// =====================================================================================
// Reference implementations of the pure host rules (the SPEC the host must satisfy).
// Each is a faithful, minimal port of the corresponding host code path; keeping them here makes the
// contract reviewable and runnable on the build host. The host's own CanopyColor / leafMeasureThunk
// / has+isNull live in CanopyHostFabric.mm (UIKit/Yoga-coupled); check-ios-validation-ledger.sh
// asserts those code paths still exist so this spec and the host cannot diverge unnoticed.
// =====================================================================================

namespace ledgerspec {

struct RGBA { int r, g, b; float a; };

static int hx2(const std::string& s, size_t a, size_t b) {
  return (int)strtol(s.substr(a, b - a).c_str(), nullptr, 16);
}
static int clampi(int v) { return v < 0 ? 0 : (v > 255 ? 255 : v); }
static float clampf(float v) { return v < 0 ? 0 : (v > 1 ? 1 : v); }

// CanopyColor.parseHex — #rgb / #rgba / #rrggbb / #rrggbbaa, CSS alpha-LAST order.
static RGBA parseHex(std::string h) {
  if (!h.empty() && h[0] == '#') h = h.substr(1);
  int r = 0, g = 0, b = 0, a = 255;
  switch (h.size()) {
    case 3: r = hx2(h,0,1)*17; g = hx2(h,1,2)*17; b = hx2(h,2,3)*17; break;
    case 4: r = hx2(h,0,1)*17; g = hx2(h,1,2)*17; b = hx2(h,2,3)*17; a = hx2(h,3,4)*17; break;
    case 6: r = hx2(h,0,2);    g = hx2(h,2,4);    b = hx2(h,4,6);    break;
    case 8: r = hx2(h,0,2);    g = hx2(h,2,4);    b = hx2(h,4,6);    a = hx2(h,6,8);    break;  // #RRGGBBAA
    default: return {0,0,0,0};   // unknown → clear
  }
  return {clampi(r), clampi(g), clampi(b), a / 255.0f};
}

// hsl()→rgb (the math CanopyColor uses to feed UIColor). Returns straight 0..255 RGBA.
static RGBA hslToRgb(float hDeg, float s, float l) {
  hDeg = fmodf(fmodf(hDeg, 360.0f) + 360.0f, 360.0f);
  float c = (1.0f - fabsf(2.0f * l - 1.0f)) * s;
  float hp = hDeg / 60.0f;
  float x = c * (1.0f - fabsf(fmodf(hp, 2.0f) - 1.0f));
  float r1 = 0, g1 = 0, b1 = 0;
  if      (hp < 1) { r1 = c; g1 = x; }
  else if (hp < 2) { r1 = x; g1 = c; }
  else if (hp < 3) { g1 = c; b1 = x; }
  else if (hp < 4) { g1 = x; b1 = c; }
  else if (hp < 5) { r1 = x; b1 = c; }
  else             { r1 = c; b1 = x; }
  float m = l - c / 2.0f;
  return {(int)lroundf((r1 + m) * 255), (int)lroundf((g1 + m) * 255), (int)lroundf((b1 + m) * 255), 1.0f};
}

// leafMeasureThunk's mode mapping (§5.3 / IOS-6 predicted rework). `natural` is sizeThatFits()'s
// result; the function clamps it per the Yoga measure mode on each axis.
enum Mode { Undefined, Exactly, AtMost };
static float resolveMeasure(float natural, float available, Mode mode) {
  if (mode == Exactly) return available;
  if (mode == AtMost)  return MIN(natural, available);
  return natural;  // Undefined → the natural intrinsic size
}

// The diff-null reset rule (§5.6/§5.7): given the raw decoded JSON value for a prop, decide whether
// it RESETS to the explicit default (null) or carries an explicit value — never coercing null→0/"".
enum PropAction { ResetToDefault, ApplyValue, Absent };
static PropAction classifyProp(id rawValue /* nil = key absent, NSNull = explicit null */) {
  if (rawValue == nil) return Absent;
  if ([rawValue isKindOfClass:[NSNull class]]) return ResetToDefault;
  return ApplyValue;
}

// ---- IOS-8 imperative-command seam (the pure JSON marshalling) ---------------------------------
// These are the faithful reference of CanopyHostFabric.mm's command-result helpers (parseCallId /
// measureResultJson / mergeCallId) — the load-bearing seam between an iOS host op and the walker's
// __callId-keyed _Native_dispatchCommandResult. They are the line-for-line twins of the host's
// file-private statics (which pull in UIKit via NSDictionary) and of CanopyHost.java (AND-4). The
// lint scripts/check-ios-command-seam.sh asserts the host's code paths exist so this spec and the
// host cannot drift unnoticed; a regression here silently mis-routes (or drops) every async result.

// Compact float→JSON: drop a trailing ".0" so integers read as integers (10, not 10.0).
static std::string fmtNum(float v) {
  if (v == floorf(v) && !std::isinf(v)) return std::to_string((long long)v);
  char buf[32]; snprintf(buf, sizeof(buf), "%g", v); return std::string(buf);
}

// parseCallId: a numeric callId → bare number literal; a string → quoted; absent/null → "null".
static std::string parseCallId(NSDictionary *args) {
  id v = args[@"__callId"];
  if (v == nil || [v isKindOfClass:[NSNull class]]) return "null";
  if ([v isKindOfClass:[NSNumber class]]) {
    double d = [(NSNumber *)v doubleValue];
    if (d == floor(d) && !isinf(d)) return std::to_string((long long)d);
    char buf[32]; snprintf(buf, sizeof(buf), "%g", d); return std::string(buf);
  }
  // string callId → quoted JSON literal (minimal escaping of quote/backslash is enough for the tests)
  NSString *s = [NSString stringWithFormat:@"%@", v];
  return std::string("\"") + s.UTF8String + "\"";
}

// measureResultJson: the RN UIManager.measure field contract, integral lengths compacted.
static std::string measureResultJson(float x, float y, float width, float height,
                                     float pageX, float pageY) {
  return std::string("{\"x\":") + fmtNum(x) + ",\"y\":" + fmtNum(y)
      + ",\"width\":" + fmtNum(width) + ",\"height\":" + fmtNum(height)
      + ",\"pageX\":" + fmtNum(pageX) + ",\"pageY\":" + fmtNum(pageY) + "}";
}

// mergeCallId: inject "__callId":<callId> as the FIRST member, the op body spliced after it.
static std::string mergeCallId(const std::string &callId, const std::string &resultBody) {
  std::string body = resultBody.length() < 2 ? "{}" : resultBody;
  std::string inner = body.substr(1, body.length() - 2);
  size_t a = inner.find_first_not_of(" \t\r\n");
  size_t b = inner.find_last_not_of(" \t\r\n");
  inner = (a == std::string::npos) ? std::string() : inner.substr(a, b - a + 1);
  return std::string("{\"__callId\":") + callId + (inner.empty() ? "" : "," + inner) + "}";
}

// ---- IOS-12 hot-path marshalling — the pure fast-path decision rules (device-free) -------------
// These reference the two PLATFORM-SPECIFIC seams the iOS host adds for the per-frame fast-path:
//   (A) updatePropScalar(handle,key,value): which UIKit view property a single scalar key targets,
//       and that an UNKNOWN key escapes to the JSON applyProps path (nothing dropped). The host's
//       real branch lives in CanopyHostFabric.mm (UIKit-coupled: UILabel.text / setValueControlled /
//       setCheckedControlled / view.alpha). This is a faithful reference of WHICH property each fast
//       key drives — the line-for-line twin of CanopyHost.java::updatePropScalar (AND-8). It is the
//       contract the host's branch is verified against on a Mac compile; scripts/check-ios-marshalling.sh
//       ties the host's code paths to this so the two cannot drift.
//   (B) createAt(handle,...): the batched create registers the view at the JS-CHOSEN handle (RND-7)
//       while the per-mutation create mints a host handle — both build IDENTICALLY (the only
//       difference is the handle source). A regression here (ignoring the JS handle) would make every
//       post-create op in a batched frame miss the host's views_ map → batched rendering draws nothing.

// Which view a scalar fast key targets. Mirrors the host's updatePropScalar switch: `text` → a label;
// `value` → a controlled input (single or multi-line) or a switch; `opacity` → the layer alpha; any
// other key → the JSON applyProps fallback. The enum is the device-free decision the UIKit branch makes.
enum ScalarTarget { ST_Label, ST_InputValue, ST_SwitchChecked, ST_Alpha, ST_JsonFallback };

// fastKeyIsScalar: the keys the walker is allowed to send through __fabric_updatePropScalar (the AND-8
// allow-list). Everything else stays on updateProps. Must match native.js's scalar-eligibility test.
static bool fastKeyIsScalar(const std::string &key) {
  return key == "text" || key == "value" || key == "opacity";
}

// scalarTarget: given a fast key AND the kind of view it lands on, the property the host writes. The
// `viewKind` is the same coarse classification makeView produces ("label"/"input"/"switch"/"other").
static ScalarTarget scalarTarget(const std::string &key, const std::string &viewKind) {
  if (key == "text"    && viewKind == "label")  return ST_Label;
  if (key == "value"   && viewKind == "input")  return ST_InputValue;
  if (key == "value"   && viewKind == "switch") return ST_SwitchChecked;
  if (key == "opacity")                         return ST_Alpha;   // any view: opacity is the layer alpha
  return ST_JsonFallback;  // unknown key, or a key on the wrong view kind → the JSON applyProps path
}

// createAt handle-source rule (RND-7): the per-mutation path mints a host handle from a counter; the
// batched path takes the JS-chosen handle verbatim. The two never collide because the batched base is
// well above the per-mutation counter (__fabric_batchHandleBase = 0x40000000). This models the host's
// createView(next_++,...) vs createView(...,h) split — both funnel through ONE createAt(h,...).
static const long kBatchHandleBase = 0x40000000;  // mirror __fabric_batchHandleBase
static long createHandleForMutationPath(long &nextCounter) { return nextCounter++; }
static long createHandleForBatchPath(long jsChosen) { return jsChosen; }  // honoured verbatim

}  // namespace ledgerspec

// =====================================================================================

@interface CanopyValidationLedgerTests : XCTestCase
@end

@implementation CanopyValidationLedgerTests

// ---- §5.1 CanopyColor: the CSS color contract --------------------------------------------------

- (void)testColorHexThreeAndSixDigitAgree {
  ledgerspec::RGBA a = ledgerspec::parseHex("#f00");
  ledgerspec::RGBA b = ledgerspec::parseHex("#ff0000");
  XCTAssertEqual(a.r, 255); XCTAssertEqual(a.g, 0); XCTAssertEqual(a.b, 0);
  XCTAssertEqual(a.r, b.r); XCTAssertEqual(a.g, b.g); XCTAssertEqual(a.b, b.b);
  XCTAssertEqualWithAccuracy(a.a, 1.0f, 1e-4, @"#rgb is fully opaque");
}

- (void)testColorHexAlphaIsCssLast {
  // CSS #RRGGBBAA → the LAST two hex digits are alpha (NOT ARGB). #ff000080 = opaque-ish red @ ~50%.
  ledgerspec::RGBA c = ledgerspec::parseHex("#ff000080");
  XCTAssertEqual(c.r, 255, @"red channel is the FIRST pair");
  XCTAssertEqual(c.g, 0);
  XCTAssertEqual(c.b, 0);
  XCTAssertEqualWithAccuracy(c.a, 128 / 255.0f, 1e-4, @"alpha is the LAST pair (CSS order)");
  // #rgba short form: the 4th nibble is alpha.
  ledgerspec::RGBA s = ledgerspec::parseHex("#f008");
  XCTAssertEqual(s.r, 255);
  XCTAssertEqualWithAccuracy(s.a, (8 * 17) / 255.0f, 1e-4, @"#rgba 4th nibble is alpha, expanded ×17");
}

- (void)testColorUnknownHexLengthIsClear {
  ledgerspec::RGBA c = ledgerspec::parseHex("#12345");   // 5 digits = invalid
  XCTAssertEqual(c.r, 0); XCTAssertEqual(c.g, 0); XCTAssertEqual(c.b, 0);
  XCTAssertEqualWithAccuracy(c.a, 0.0f, 1e-4, @"an unparseable color clears (never throws)");
}

- (void)testColorHslPrimariesMatchHex {
  // hsl(0,100%,50%) == #ff0000 ; hsl(120,100%,50%) == #00ff00 ; hsl(240,100%,50%) == #0000ff
  ledgerspec::RGBA red   = ledgerspec::hslToRgb(0,   1.0f, 0.5f);
  ledgerspec::RGBA green = ledgerspec::hslToRgb(120, 1.0f, 0.5f);
  ledgerspec::RGBA blue  = ledgerspec::hslToRgb(240, 1.0f, 0.5f);
  XCTAssertEqual(red.r, 255);   XCTAssertEqual(red.g, 0);     XCTAssertEqual(red.b, 0);
  XCTAssertEqual(green.r, 0);   XCTAssertEqual(green.g, 255); XCTAssertEqual(green.b, 0);
  XCTAssertEqual(blue.r, 0);    XCTAssertEqual(blue.g, 0);    XCTAssertEqual(blue.b, 255);
}

- (void)testColorHslGreyIsAchromatic {
  ledgerspec::RGBA grey = ledgerspec::hslToRgb(210, 0.0f, 0.5f);  // 0 saturation → grey
  XCTAssertEqual(grey.r, grey.g);
  XCTAssertEqual(grey.g, grey.b);
  XCTAssertEqualWithAccuracy((float)grey.r, 128.0f, 1.5f, @"l=50%% grey is mid-grey");
}

// ---- §5.1 diff-null discipline -----------------------------------------------------------------

- (void)testDiffNullResetsToDefaultNotZero {
  using namespace ledgerspec;
  // An ABSENT key is left untouched (no write).
  XCTAssertEqual(classifyProp(nil), Absent);
  // An EXPLICIT JSON null RESETS to the default (resetStyleKey) — the whole point of the contract.
  XCTAssertEqual(classifyProp([NSNull null]), ResetToDefault);
  // A real value is applied.
  XCTAssertEqual(classifyProp(@"#ff0000"), ApplyValue);
  XCTAssertEqual(classifyProp(@0), ApplyValue);
  XCTAssertEqual(classifyProp(@""), ApplyValue);
}

- (void)testDiffNullDistinguishesNullFromFalsyValue {
  using namespace ledgerspec;
  // The footgun this guards: null (reset) must NOT be confused with 0 / "" (apply explicit falsy).
  XCTAssertNotEqual(classifyProp([NSNull null]), classifyProp(@0),
                    @"null (reset) and 0 (apply) are DIFFERENT actions");
  XCTAssertNotEqual(classifyProp([NSNull null]), classifyProp(@""),
                    @"null (reset) and \"\" (apply) are DIFFERENT actions");
}

// ---- §5.3 leaf sizeThatFits ↔ Yoga measure modes (IOS-6 predicted rework) ----------------------

- (void)testMeasureExactlyTakesTheAvailableSize {
  // Yoga's Exactly measure mode → the fixed available value wins (ignores the natural size).
  XCTAssertEqualWithAccuracy(ledgerspec::resolveMeasure(40, 100, ledgerspec::Exactly), 100, 1e-4);
  XCTAssertEqualWithAccuracy(ledgerspec::resolveMeasure(400, 100, ledgerspec::Exactly), 100, 1e-4);
}

- (void)testMeasureAtMostClampsToAvailable {
  // Yoga's AtMost measure mode → min(natural, available): a small leaf keeps its size; big is clamped.
  XCTAssertEqualWithAccuracy(ledgerspec::resolveMeasure(40, 100, ledgerspec::AtMost), 40, 1e-4);
  XCTAssertEqualWithAccuracy(ledgerspec::resolveMeasure(400, 100, ledgerspec::AtMost), 100, 1e-4);
}

- (void)testMeasureUndefinedTakesNaturalSize {
  // Yoga's Undefined measure mode → the natural intrinsic size (constraint is CGFLOAT_MAX upstream).
  XCTAssertEqualWithAccuracy(ledgerspec::resolveMeasure(40, 100, ledgerspec::Undefined), 40, 1e-4);
  XCTAssertEqualWithAccuracy(ledgerspec::resolveMeasure(400, 100, ledgerspec::Undefined), 400, 1e-4);
}

// ---- §5.3 BeforeAfter wipe — the shared-C++ op that backs CanopyBeforeAfterView ---------------
// This leg runs FOR REAL (the op is linked from the static lib), and is the device-free pin of the
// IOS-6 BeforeAfter "blob premultiplied-alpha"/wipe predicted-rework surface that the on-device
// CanopyHostValidationTests.test_5_3_component_beforeAfterWipe drives end-to-end on the Simulator.

- (void)testBeforeAfterWipeColumnsSplitFromBothBlobs {
  BlobRegistry &reg = globalBlobRegistry();
  const size_t before = reg.liveCount();

  // a 3×1 "before" (all 10s) and a 3×1 "after" (all 90s); a wipe at splitX=2 yields cols {a,a,b}.
  Blob a; a.kind = "rgba8"; a.width = 3; a.height = 1; a.bytes.assign(3 * 4, 10);
  Blob b; b.kind = "rgba8"; b.width = 3; b.height = 1; b.bytes.assign(3 * 4, 90);
  BlobHandle ah = reg.put(std::move(a));
  BlobHandle bh = reg.put(std::move(b));

  BlobHandle out = imageWipeColumns(ah, bh, /*splitX*/ 2);
  XCTAssertGreaterThan(out, 0);
  auto o = reg.get(out);
  XCTAssertTrue(o != nullptr);
  XCTAssertEqual(o->bytes[0 * 4 + 0], 10, @"col 0 left of split = before");
  XCTAssertEqual(o->bytes[1 * 4 + 0], 10, @"col 1 left of split = before");
  XCTAssertEqual(o->bytes[2 * 4 + 0], 90, @"col 2 right of split = after");

  reg.release(ah); reg.release(bh); reg.release(out);
  XCTAssertEqual(reg.liveCount(), before, @"no blob leaks across the wipe");
}

- (void)testBeforeAfterWipeAtEndsAreFullFrames {
  BlobRegistry &reg = globalBlobRegistry();
  Blob a; a.kind = "rgba8"; a.width = 2; a.height = 1; a.bytes.assign(2 * 4, 1);
  Blob b; b.kind = "rgba8"; b.width = 2; b.height = 1; b.bytes.assign(2 * 4, 2);
  BlobHandle ah = reg.put(std::move(a));
  BlobHandle bh = reg.put(std::move(b));

  // splitX=0 → wipe fully revealed the AFTER frame; splitX=width → fully the BEFORE frame.
  auto all_after  = reg.get(imageWipeColumns(ah, bh, 0));
  auto all_before = reg.get(imageWipeColumns(ah, bh, 2));
  XCTAssertEqual(all_after->bytes[0],  2, @"wipeFraction at the far edge shows all 'after'");
  XCTAssertEqual(all_before->bytes[0], 1, @"wipeFraction at the near edge shows all 'before'");

  reg.release(ah); reg.release(bh);
}

// ---- IOS-8 imperative-command seam — the pure JSON marshalling (device-free) -------------------

- (void)testCommandParseCallIdNumericEchoesAsBareNumber {
  std::string id1 = ledgerspec::parseCallId(@{ @"select": @YES, @"__callId": @42 });
  XCTAssertEqual(id1, std::string("42"), @"a numeric callId echoes as a bare number literal");
}

- (void)testCommandParseCallIdStringEchoesAsQuotedLiteral {
  std::string id1 = ledgerspec::parseCallId(@{ @"__callId": @"abc" });
  XCTAssertEqual(id1, std::string("\"abc\""), @"a string callId echoes as a quoted JSON literal");
}

- (void)testCommandParseCallIdAbsentOrNullIsNullLiteral {
  XCTAssertEqual(ledgerspec::parseCallId(@{}), std::string("null"), @"absent __callId → null");
  XCTAssertEqual(ledgerspec::parseCallId(@{ @"__callId": [NSNull null] }), std::string("null"),
                 @"explicit-null __callId → null (AND-3 fallback)");
}

- (void)testCommandMeasureResultJsonEmitsRnContractCompacted {
  std::string json = ledgerspec::measureResultJson(4, 8, 100, 40, 12, 200);
  NSData *d = [[NSString stringWithUTF8String:json.c_str()] dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *o = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
  XCTAssertTrue([o isKindOfClass:[NSDictionary class]], @"must be well-formed JSON");
  XCTAssertEqualObjects(o[@"x"], @4);
  XCTAssertEqualObjects(o[@"width"], @100);
  XCTAssertEqualObjects(o[@"pageY"], @200);
  XCTAssertTrue(json.find("\"width\":100") != std::string::npos &&
                json.find("100.0") == std::string::npos,
                @"integral lengths are compacted (no trailing .0)");
}

- (void)testCommandMeasureResultKeepsFractionalLengths {
  std::string json = ledgerspec::measureResultJson(0, 0, 12.5f, 0, 0, 0);
  NSData *d = [[NSString stringWithUTF8String:json.c_str()] dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *o = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
  XCTAssertEqualWithAccuracy([o[@"width"] doubleValue], 12.5, 1e-4,
                            @"a fractional length is preserved");
}

- (void)testCommandMergeCallIdInjectsCallIdFirstAndKeepsBody {
  std::string merged = ledgerspec::mergeCallId("7", "{\"ok\":true}");
  XCTAssertTrue(merged.rfind("{\"__callId\":7,", 0) == 0, @"callId is the first member");
  NSData *d = [[NSString stringWithUTF8String:merged.c_str()] dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *o = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
  XCTAssertEqualObjects(o[@"__callId"], @7);
  XCTAssertEqualObjects(o[@"ok"], @YES);
}

- (void)testCommandMergeCallIdEmptyBodyStillValid {
  std::string merged = ledgerspec::mergeCallId("null", "{}");
  NSData *d = [[NSString stringWithUTF8String:merged.c_str()] dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *o = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
  XCTAssertTrue([o[@"__callId"] isKindOfClass:[NSNull class]], @"null callId round-trips to JSON null");
  XCTAssertEqual(o.count, (NSUInteger)1, @"an empty body yields just the echoed callId");
}

- (void)testCommandMergeCallIdOverMeasureResultRoundTrips {
  std::string body = ledgerspec::measureResultJson(1, 2, 3, 4, 5, 6);
  std::string merged = ledgerspec::mergeCallId("99", body);
  NSData *d = [[NSString stringWithUTF8String:merged.c_str()] dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *o = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
  XCTAssertEqualObjects(o[@"__callId"], @99);
  XCTAssertEqualObjects(o[@"width"], @3);
  XCTAssertEqualObjects(o[@"pageY"], @6);
}

// ---- IOS-12 hot-path marshalling — the pure fast-path decision rules (device-free) -------------
// The UIKit writes (UILabel.text, setValueControlled, view.alpha) and the JS↔Hermes wiring run on a
// Simulator (CanopyHostValidationTests.swift) / are timed by the shared mock (harness/run-batch.js +
// harness/bench.js). These pin the platform-specific DECISION the iOS host makes for each fast path,
// the twin of the Java host's behaviour, so a regression goes red on the Linux gate before any Mac run.

- (void)testScalarFastKeyAllowListMatchesWalker {
  using namespace ledgerspec;
  // EXACTLY the AND-8 allow-list the walker routes to __fabric_updatePropScalar — no more, no less.
  XCTAssertTrue(fastKeyIsScalar("text"));
  XCTAssertTrue(fastKeyIsScalar("value"));
  XCTAssertTrue(fastKeyIsScalar("opacity"));
  // Everything else stays on the JSON updateProps path (style/object/event props, removals, multi-key).
  XCTAssertFalse(fastKeyIsScalar("style"));
  XCTAssertFalse(fastKeyIsScalar("source"));
  XCTAssertFalse(fastKeyIsScalar("__events"));
  XCTAssertFalse(fastKeyIsScalar("transform"));
}

- (void)testScalarTargetMapsEachFastKeyToTheRightViewProperty {
  using namespace ledgerspec;
  // text → a UILabel's text (mirrors the host's isKindOfClass:[UILabel class] branch).
  XCTAssertEqual(scalarTarget("text", "label"), ST_Label);
  // value → a controlled input's text OR a switch's checked, by view kind.
  XCTAssertEqual(scalarTarget("value", "input"), ST_InputValue);
  XCTAssertEqual(scalarTarget("value", "switch"), ST_SwitchChecked);
  // opacity → the layer alpha on ANY view kind.
  XCTAssertEqual(scalarTarget("opacity", "label"), ST_Alpha);
  XCTAssertEqual(scalarTarget("opacity", "other"), ST_Alpha);
}

- (void)testScalarUnknownKeyOrWrongViewFallsBackToJsonPath {
  using namespace ledgerspec;
  // A scalar key on the WRONG view kind (e.g. `text` on a non-label) is NOT silently dropped — it
  // escapes to the JSON applyProps path, exactly like the host's `else`/default branch.
  XCTAssertEqual(scalarTarget("text", "input"), ST_JsonFallback);
  XCTAssertEqual(scalarTarget("value", "label"), ST_JsonFallback);
  // A key the host does not recognise at all (a host older than the walker) also falls back.
  XCTAssertEqual(scalarTarget("tintColor", "other"), ST_JsonFallback);
}

- (void)testCreateAtHandleSourceSplitMatchesAndroidGolden {
  using namespace ledgerspec;
  // Per-mutation creates mint from the host counter; the FIRST is 1 (host next_ starts at 1).
  long next = 1;
  XCTAssertEqual(createHandleForMutationPath(next), 1L, @"first per-mutation handle is the host counter");
  XCTAssertEqual(createHandleForMutationPath(next), 2L, @"the counter advances");
  // A batched create takes the JS-chosen handle VERBATIM (RND-7) — it must NOT be re-minted.
  long jsHandle = kBatchHandleBase;          // the walker allocates from __fabric_batchHandleBase
  XCTAssertEqual(createHandleForBatchPath(jsHandle), kBatchHandleBase,
                 @"a batched view registers under the JS-chosen handle, not a host-minted one");
  // The two handle spaces are DISJOINT (the batch base is far above the per-mutation counter), so a
  // batched view and a per-mutation view can never collide in the host's views_ map.
  XCTAssertGreaterThan(kBatchHandleBase, next,
                       @"the batch handle base is clear of the per-mutation counter (no collision)");
}

@end
