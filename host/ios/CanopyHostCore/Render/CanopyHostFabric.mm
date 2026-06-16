// CanopyHostFabric.mm — iOS implementation of canopy::CanopyHost (full RN-parity host).
//
// Backs the __fabric_* surface with real UIKit views laid out by Yoga (the same layout
// engine React Native uses, vendored as the `Yoga` pod / public C API). This is the
// "direct views + Yoga" host strategy (see ../README.md / plan 06-ios-bringup §2): it
// stands up real native views with flexbox layout WITHOUT depending on React Native's
// private Fabric mount internals — honouring the survival rule (architecture.md §3) by
// binding only to UIKit + Yoga's stable public surfaces.
//
// This is the line-for-line iOS analog of host/android/.../CanopyHost.java. Every behavior
// there is mirrored here; divergences are deliberate and commented:
//
//   • NO density multiply. iOS Yoga runs in points, UIKit frames are in points, and Canopy
//     style dims are dp-ish ≈ points, so dp(v)=v (unlike Android's dp(v)=v*density). Pan
//     deltas come straight from UIKit points (no /density). (contract §0.3)
//   • The host has NO jsi::Runtime* member. Events emit through an injected CanopyEmitFn
//     (`emit_`) handed to the factory at construction (contract §5.1 / §6.9). Only the boot
//     controller binds that closure to canopyEmitEvent on the held runtime. Every interactive
//     surface (gestures, text, switch, scroll, before/after, image-load, anim edges) emits
//     ONLY through emit_.
//
// LAYOUT MODEL (the C2 render-fidelity fix, contract §5.4): every CONTAINER is a
// CanopyContainerView whose layoutSubviews runs YGNodeCalculateLayout on owner==null roots
// (the real root, plus the ScrollView/Modal content roots) and positions its direct children
// from their Yoga frames; LEAF views (Text/Image/Input/Switch/Indicator/Bitmap) carry a Yoga
// measure function (sizeThatFits) so intrinsic sizing is correct. This replaces the naive
// "push frames from one root relayout" approach so rotation/keyboard/safe-area re-layout for
// free. (A first-light host-driven relayout() is retained as a fallback path.)
//
// NOTE: this compiles inside an iOS app target that links UIKit + Yoga + Hermes. Pieces that
// genuinely need a Mac/simulator to validate are marked // [MAC-VALIDATE]; they are still
// fully implemented.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <yoga/Yoga.h>
#include <cmath>
#include <functional>
#include <memory>
#include <string>
#include <unordered_map>
#include <utility>   // std::pair / std::move (the doFrame finished[] vector + the emit_ ctor move);
                     // the home header for these, NOT guaranteed transitively under libc++
#include <vector>

// The production renderer header (Author C, contract §1/§6). It declares canopy::CanopyEmitFn
// (§6.1) and canopy::CanopyHostMake (§6.2) inside namespace canopy — the binding interface the
// Boot layer includes and links against — and transitively the portable CanopyFabric.h
// (canopy::CanopyHost / canopy::Handle / canopyEmitEvent).
#include "CanopyHostFabric.h"
#include "../../../shared/cpp/CanopyBlobs.h"   // canopy::BlobHandle (CanopyBitmap / BeforeAfter)
#include "../../../shared/cpp/CanopyBeforeAfter.h"  // L-I4: the SHARED before/after wipe math (the
                                                    // single source of truth both hosts call, so the
                                                    // iOS compositor cannot drift from the Android one;
                                                    // asserted by host/shared/test-vectors/beforeafter-vectors.json).

using namespace canopy;

// ---------------------------------------------------------------------------
// Cross-file seam (contract §6.3): the blob↔UIImage bridge + the single globalBlobRegistry()
// live in Author E's CanopyBlobRegistryHost.mm. We only consume blobGetUIImage. weak_import so
// a first-light link without E's TU still loads (CanopyBitmap/BeforeAfter render nil until E lands).
// ---------------------------------------------------------------------------
namespace canopy {
// The blob↔UIImage bridge is defined once in CanopyBlobRegistryHost.mm (Author E, §6.3). We only
// consume it. weak_import so a first-light link without E's TU still loads (CanopyBitmap /
// BeforeAfter just render nil until E lands).
UIImage* blobGetUIImage(BlobHandle h) __attribute__((weak_import));
}

// ===========================================================================
// Forward decls of the Obj-C view classes implemented in this TU.
// ===========================================================================
@class CanopyContainerView;
@class CanopyScrollView;
@class CanopyTextInputView;
@class CanopySwitchView;
@class CanopyModalHostView;
@class CanopyBeforeAfterView;

// The host exposes just enough to its views via this lightweight protocol so an Obj-C view can
// resolve its Yoga node (for the leaf-measure round trip) and ask for a re-layout, without the
// view importing the C++ host type.
@protocol CanopyLayoutHost <NSObject>
- (YGNodeRef)yogaNodeForView:(UIView*)view;          // nullptr if not tracked
- (void)requestRelayout;
- (void)requestContentRelayout:(UIView*)contentView; // a separate (owner==null) content root
@end

// ===========================================================================
// CanopyColor — full CSS color parser (port of Android CanopyColor.java).
// #rgb/#rgba/#rrggbb/#rrggbbaa (CSS alpha-LAST order), rgb()/rgba(), hsl()/hsla(), named,
// transparent/none. Replaces the old #rrggbb-only stub. (contract §5.8)
// ===========================================================================
@interface CanopyColor : NSObject
+ (UIColor*)parse:(NSString*)s;
@end

@implementation CanopyColor

+ (UIColor*)parse:(NSString*)s {
  if (![s isKindOfClass:[NSString class]]) return nil;
  NSString* t = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (t.length == 0) return [UIColor clearColor];
  NSString* low = [t lowercaseString];
  if ([low isEqualToString:@"transparent"] || [low isEqualToString:@"none"]) return [UIColor clearColor];
  @try {
    if ([t hasPrefix:@"#"]) return [self parseHex:[t substringFromIndex:1]];
    if ([low hasPrefix:@"rgb"]) return [self parseRgb:t];
    if ([low hasPrefix:@"hsl"]) return [self parseHsl:t];
    UIColor* named = [self named:low];
    if (named) return named;
  } @catch (__unused NSException* e) {}
  return [UIColor clearColor];
}

+ (int)hx:(NSString*)s from:(NSUInteger)a to:(NSUInteger)b {
  unsigned int v = 0;
  [[NSScanner scannerWithString:[s substringWithRange:NSMakeRange(a, b - a)]] scanHexInt:&v];
  return (int)v;
}

+ (UIColor*)parseHex:(NSString*)h {
  int r, g, b, a = 255;
  switch (h.length) {
    case 3: r = [self hx:h from:0 to:1] * 17; g = [self hx:h from:1 to:2] * 17; b = [self hx:h from:2 to:3] * 17; break;
    case 4: r = [self hx:h from:0 to:1] * 17; g = [self hx:h from:1 to:2] * 17; b = [self hx:h from:2 to:3] * 17; a = [self hx:h from:3 to:4] * 17; break;
    case 6: r = [self hx:h from:0 to:2]; g = [self hx:h from:2 to:4]; b = [self hx:h from:4 to:6]; break;
    case 8: r = [self hx:h from:0 to:2]; g = [self hx:h from:2 to:4]; b = [self hx:h from:4 to:6]; a = [self hx:h from:6 to:8]; break; // CSS #RRGGBBAA
    default: return [UIColor clearColor];
  }
  return [UIColor colorWithRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:a / 255.0];
}

+ (NSArray<NSString*>*)inner:(NSString*)s {
  NSRange open = [s rangeOfString:@"("];
  NSRange close = [s rangeOfString:@")" options:NSBackwardsSearch];
  if (open.location == NSNotFound || close.location == NSNotFound) return @[];
  NSString* in = [s substringWithRange:NSMakeRange(open.location + 1, close.location - open.location - 1)];
  NSMutableArray<NSString*>* out = [NSMutableArray array];
  for (NSString* p in [in componentsSeparatedByCharactersInSet:
                       [NSCharacterSet characterSetWithCharactersInString:@",/ \t"]]) {
    if (p.length) [out addObject:p];
  }
  return out;
}

+ (int)clamp:(int)v { return v < 0 ? 0 : (v > 255 ? 255 : v); }

// An rgb() channel: "255" or "50%".
+ (int)chan:(NSString*)t {
  t = [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  if ([t hasSuffix:@"%"]) return [self clamp:(int)lroundf([[t substringToIndex:t.length - 1] floatValue] * 2.55f)];
  return [self clamp:(int)lroundf([t floatValue])];
}

// An alpha: "0.5" or "50%" → 0..1.
+ (float)alpha:(NSString*)t {
  t = [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  if ([t hasSuffix:@"%"]) return [[t substringToIndex:t.length - 1] floatValue] / 100.0f;
  return [t floatValue];
}

// A percentage token "50%" → 0..1 (HSL s/l).
+ (float)pct:(NSString*)t {
  t = [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  if ([t hasSuffix:@"%"]) return [[t substringToIndex:t.length - 1] floatValue] / 100.0f;
  return [t floatValue];
}

+ (UIColor*)parseRgb:(NSString*)s {
  NSArray<NSString*>* p = [self inner:s];
  if (p.count < 3) return [UIColor clearColor];
  int r = [self chan:p[0]], g = [self chan:p[1]], b = [self chan:p[2]];
  float a = p.count > 3 ? [self alpha:p[3]] : 1.0f;
  return [UIColor colorWithRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:(a < 0 ? 0 : a > 1 ? 1 : a)];
}

+ (UIColor*)parseHsl:(NSString*)s {
  NSArray<NSString*>* p = [self inner:s];
  if (p.count < 3) return [UIColor clearColor];
  float h = [[[p[0] stringByReplacingOccurrencesOfString:@"deg" withString:@""]
              stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] floatValue];
  float sat = [self pct:p[1]];
  float l = [self pct:p[2]];
  float a = p.count > 3 ? [self alpha:p[3]] : 1.0f;
  h = fmodf(fmodf(h, 360.0f) + 360.0f, 360.0f) / 360.0f; // UIColor hue is 0..1
  // UIColor wants HSB; convert HSL→HSB so we match CSS hsl() exactly.
  float c = (1.0f - fabsf(2.0f * l - 1.0f)) * sat;
  float bri = l + c / 2.0f;
  float satB = bri <= 0 ? 0 : 2.0f * (1.0f - l / bri);
  return [UIColor colorWithHue:h saturation:(satB < 0 ? 0 : satB > 1 ? 1 : satB)
                    brightness:(bri < 0 ? 0 : bri > 1 ? 1 : bri)
                         alpha:(a < 0 ? 0 : a > 1 ? 1 : a)];
}

// The CSS named-color subset Lumen + canopy/css actually emit. UIColor only ships a dozen
// system colors, so we carry the common web names here. (Unknown → nil → caller clears.)
+ (UIColor*)named:(NSString*)n {
  static NSDictionary<NSString*, NSString*>* table;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    table = @{
      @"black": @"000000", @"white": @"ffffff", @"red": @"ff0000", @"green": @"008000",
      @"blue": @"0000ff", @"yellow": @"ffff00", @"cyan": @"00ffff", @"magenta": @"ff00ff",
      @"gray": @"808080", @"grey": @"808080", @"silver": @"c0c0c0", @"maroon": @"800000",
      @"olive": @"808000", @"lime": @"00ff00", @"aqua": @"00ffff", @"teal": @"008080",
      @"navy": @"000080", @"fuchsia": @"ff00ff", @"purple": @"800080", @"orange": @"ffa500",
      @"pink": @"ffc0cb", @"brown": @"a52a2a", @"gold": @"ffd700", @"indigo": @"4b0082",
      @"violet": @"ee82ee", @"coral": @"ff7f50", @"salmon": @"fa8072", @"khaki": @"f0e68c",
      @"crimson": @"dc143c", @"darkgray": @"a9a9a9", @"darkgrey": @"a9a9a9",
      @"lightgray": @"d3d3d3", @"lightgrey": @"d3d3d3", @"slategray": @"708090",
      @"dimgray": @"696969", @"whitesmoke": @"f5f5f5", @"gainsboro": @"dcdcdc",
      @"tomato": @"ff6347", @"turquoise": @"40e0d0", @"skyblue": @"87ceeb",
      @"steelblue": @"4682b4", @"royalblue": @"4169e1", @"midnightblue": @"191970",
      @"forestgreen": @"228b22", @"seagreen": @"2e8b57", @"darkgreen": @"006400",
      @"hotpink": @"ff69b4", @"deeppink": @"ff1493", @"chocolate": @"d2691e",
      @"goldenrod": @"daa520", @"tan": @"d2b48c", @"beige": @"f5f5dc",
      @"lavender": @"e6e6fa", @"plum": @"dda0dd", @"orchid": @"da70d6",
    };
  });
  NSString* hex = table[n];
  return hex ? [self parseHex:hex] : nil;
}

@end

// ===========================================================================
// Per-view record — the iOS analog of Android's CView (contract §5.2).
// ===========================================================================
namespace {

struct CView {
  UIView* view = nil;              // the live UIKit view (UILabel for text, etc.)
  YGNodeRef yoga = nullptr;        // its Yoga node
  std::string fabricName;          // "RCTView" / "RCTText" / ...
  bool isLeaf = false;

  UIColor* textColor = nil;        // default black (set lazily)
  UIColor* bgColor = nil;          // nil
  CGFloat borderRadius = 0;        // 0
  UIColor* borderColor = nil;      // nil
  CGFloat borderWidth = 0;         // 0
  // TL,TR,BR,BL; NAN sentinel = unset. When any is set it OVERRIDES borderRadius.
  CGFloat corners[4] = {NAN, NAN, NAN, NAN};

  NSString* testID = nil;
  NSString* a11yLabel = nil;
  NSString* a11yRole = nil;
  NSString* a11yHint = nil;

  UIView* contentView = nil;       // separate content root (ScrollView/Modal); nil otherwise
  YGNodeRef contentYoga = nullptr; // its Yoga root (owner==null)

  NSString* lastSource = nil;      // last declarative image URI (de-dup / recycle-drop)
  CGFloat baseOpacity = 1.0;       // static opacity cached even while animated
  NSString* baseTransform = nil;   // static transform cached for restore-on-clear
};

static bool hasCorners(const CView& cv) {
  return !std::isnan(cv.corners[0]) || !std::isnan(cv.corners[1]) ||
         !std::isnan(cv.corners[2]) || !std::isnan(cv.corners[3]);
}

// Coerce a numeric-looking style string to a float for Yoga (Canopy emits style values
// as strings; codegen's float-prop set tells the host which to coerce). nil-safe.
static bool numericFloat(NSString* s, float* out) {
  if (![s isKindOfClass:[NSString class]]) return false;
  NSScanner* sc = [NSScanner scannerWithString:s];
  return [sc scanFloat:out] && [sc isAtEnd];
}

// Float-or-nil (Android asFloat). Returns NAN when not numeric.
static float asFloat(NSString* s) {
  float f = 0;
  return numericFloat(s, &f) ? f : NAN;
}

// Minimal JSON string literal (quotes + escapes) for an event payload (Android jsonStr).
static NSString* jsonStr(NSString* s) {
  if (![s isKindOfClass:[NSString class]]) return @"null";
  NSMutableString* b = [NSMutableString stringWithString:@"\""];
  for (NSUInteger i = 0; i < s.length; i++) {
    unichar c = [s characterAtIndex:i];
    switch (c) {
      case '"':  [b appendString:@"\\\""]; break;
      case '\\': [b appendString:@"\\\\"]; break;
      case '\n': [b appendString:@"\\n"]; break;
      case '\r': [b appendString:@"\\r"]; break;
      case '\t': [b appendString:@"\\t"]; break;
      default:
        if (c < 0x20) [b appendFormat:@"\\u%04x", c];
        else [b appendFormat:@"%C", c];
    }
  }
  [b appendString:@"\""];
  return b;
}

// JSON-string a C++ payload helper used at emit sites.
static std::string asStd(NSString* s) { return s ? std::string(s.UTF8String) : std::string(); }

}  // namespace

// ===========================================================================
// CanopyContainerView — the Yoga-driven container (analog of YogaViewGroup, §5.4).
// Its layoutSubviews resolves its own Yoga node; if it is a root (owner==null) it runs
// the whole-subtree calculateLayout (leaf measure fns run here), then positions each
// direct subview from its Yoga frame. Read-only on Yoga during layout (never mutate).
// ===========================================================================
@interface CanopyContainerView : UIView
@property(nonatomic, weak) id<CanopyLayoutHost> layoutHost;
@end

@implementation CanopyContainerView

- (void)layoutSubviews {
  [super layoutSubviews];
  if (!self.layoutHost) return;
  YGNodeRef self_ = [self.layoutHost yogaNodeForView:self];
  if (self_ && YGNodeGetOwner(self_) == nullptr) {
    // A Yoga root: compute the whole subtree from our bounds. Rotation / keyboard /
    // safe-area changes call layoutSubviews automatically, re-running this. (§5.4)
    YGNodeCalculateLayout(self_, self.bounds.size.width, self.bounds.size.height, YGDirectionLTR);
  }
  for (UIView* child in self.subviews) {
    YGNodeRef cn = [self.layoutHost yogaNodeForView:child];
    if (!cn) continue;
    child.frame = CGRectMake(roundf(YGNodeLayoutGetLeft(cn)), roundf(YGNodeLayoutGetTop(cn)),
                             roundf(YGNodeLayoutGetWidth(cn)), roundf(YGNodeLayoutGetHeight(cn)));
  }
}

@end

// ===========================================================================
// CanopyScrollView — UIScrollView + a separate Yoga content root (§5.11 / Android
// CanopyScrollView.java). Vertical (default) or horizontal; optional UIRefreshControl.
// The host mounts children into `contentRoot` (a CanopyContainerView whose Yoga node has
// owner==null). layoutSubviews lays the content root out at its natural size and sets
// contentSize. Throttled `scroll` + `momentumScrollEnd` + `refresh` via emit_.
// ===========================================================================
@interface CanopyScrollView : UIScrollView <UIScrollViewDelegate, CanopyLayoutHost>
@property(nonatomic, assign) canopy::Handle viewHandle;
@property(nonatomic, assign) CanopyEmitFn* emit;        // borrowed (host owns the closure)
@property(nonatomic, weak) id<CanopyLayoutHost> outerHost;
@property(nonatomic, strong) CanopyContainerView* contentRoot;
@property(nonatomic, assign) BOOL emitScroll;
@property(nonatomic, assign) BOOL emitRefresh;
@property(nonatomic, assign) BOOL horizontal;
@property(nonatomic, assign) BOOL refreshEnabled;
- (void)attachContent:(CanopyContainerView*)content;
- (void)setHorizontalMode:(BOOL)h;
- (void)setScrollLocked:(BOOL)locked;
- (void)setRefreshControlEnabled:(BOOL)enabled;
- (void)setRefreshing:(BOOL)r;
@end

@implementation CanopyScrollView {
  NSTimeInterval _lastEmit;
  UIRefreshControl* _refresh;
}

- (instancetype)init {
  if (self = [super init]) {
    self.delegate = self;
    self.showsVerticalScrollIndicator = YES;
    self.showsHorizontalScrollIndicator = YES;
    if (@available(iOS 11.0, *)) self.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    _lastEmit = 0;
  }
  return self;
}

- (void)attachContent:(CanopyContainerView*)content {
  self.contentRoot = content;
  content.layoutHost = self;  // the scroll view IS the content root's layout host
  [self addSubview:content];
}

// CanopyLayoutHost: the content root and its children resolve Yoga nodes via the outer host.
- (YGNodeRef)yogaNodeForView:(UIView*)view { return [self.outerHost yogaNodeForView:view]; }
- (void)requestRelayout { [self setNeedsLayout]; }
- (void)requestContentRelayout:(UIView*)contentView { [contentView setNeedsLayout]; }

- (void)setHorizontalMode:(BOOL)h { self.horizontal = h; [self setNeedsLayout]; }

- (void)setScrollLocked:(BOOL)locked { self.scrollEnabled = !locked; }

- (void)setRefreshControlEnabled:(BOOL)enabled {
  if (enabled == self.refreshEnabled) return;
  self.refreshEnabled = enabled;
  if (enabled && !self.horizontal) {
    if (!_refresh) {
      _refresh = [[UIRefreshControl alloc] init];
      [_refresh addTarget:self action:@selector(onRefresh) forControlEvents:UIControlEventValueChanged];
    }
    self.refreshControl = _refresh;  // [MAC-VALIDATE] UIScrollView.refreshControl (iOS 10+)
  } else {
    self.refreshControl = nil;
  }
}

- (void)setRefreshing:(BOOL)r {
  if (!_refresh) return;
  if (r) [_refresh beginRefreshing];
  else [_refresh endRefreshing];
}

- (void)onRefresh {
  if (self.emitRefresh && self.emit && *self.emit && self.viewHandle >= 0)
    (*self.emit)(self.viewHandle, "refresh", "{}");
}

- (void)layoutSubviews {
  [super layoutSubviews];
  CanopyContainerView* content = self.contentRoot;
  if (!content) return;
  YGNodeRef cn = [self.outerHost yogaNodeForView:content];
  if (!cn) return;
  // Measure the content with the SCROLL AXIS UNBOUNDED so the natural extent is computed,
  // the cross axis pinned to the viewport, then set contentSize from the computed root size.
  CGSize vp = self.bounds.size;
  float availW = self.horizontal ? YGUndefined : vp.width;
  float availH = self.horizontal ? vp.height : YGUndefined;
  YGNodeCalculateLayout(cn, availW, availH, YGDirectionLTR);
  CGFloat w = roundf(YGNodeLayoutGetWidth(cn));
  CGFloat h = roundf(YGNodeLayoutGetHeight(cn));
  // Pin the cross axis to at least the viewport (RN fillViewport).
  if (self.horizontal) h = MAX(h, vp.height);
  else w = MAX(w, vp.width);
  content.frame = CGRectMake(0, 0, w, h);
  self.contentSize = CGSizeMake(w, h);
  // The content root is a SEPARATE Yoga root the outer pass does not reach; lay its children.
  [content setNeedsLayout];
  [content layoutIfNeeded];
}

- (void)scrollViewDidScroll:(UIScrollView*)scrollView {
  if (!self.emitScroll || !self.emit || !*self.emit || self.viewHandle < 0) return;
  NSTimeInterval now = CACurrentMediaTime();
  if (now - _lastEmit >= 0.016) {  // ~60fps cap
    _lastEmit = now;
    CGPoint o = self.contentOffset;
    NSString* json = [NSString stringWithFormat:
        @"{\"x\":%g,\"y\":%g,\"contentWidth\":%g,\"contentHeight\":%g,\"viewportWidth\":%g,\"viewportHeight\":%g}",
        o.x, o.y, self.contentSize.width, self.contentSize.height,
        self.bounds.size.width, self.bounds.size.height];
    (*self.emit)(self.viewHandle, "scroll", asStd(json));
  }
}

- (void)scrollViewDidEndDecelerating:(UIScrollView*)scrollView { [self emitMomentumEnd]; }
- (void)scrollViewDidEndDragging:(UIScrollView*)scrollView willDecelerate:(BOOL)decelerate {
  if (!decelerate) [self emitMomentumEnd];
}

- (void)emitMomentumEnd {
  if (!self.emitScroll || !self.emit || !*self.emit || self.viewHandle < 0) return;
  CGPoint o = self.contentOffset;
  NSString* json = self.horizontal ? [NSString stringWithFormat:@"{\"x\":%g}", o.x]
                                    : [NSString stringWithFormat:@"{\"y\":%g}", o.y];
  (*self.emit)(self.viewHandle, "momentumScrollEnd", asStd(json));
}

@end

// ===========================================================================
// CanopyTextInputView — controlled UITextField (analog of CanopyTextInput.java, §3.3).
// Emits changeText/submitEditing/focus/blur via emit_, with an echo-guard so a programmatic
// value set never re-fires changeText into update.
// ===========================================================================
@interface CanopyTextInputView : UITextField <UITextFieldDelegate>
@property(nonatomic, assign) canopy::Handle viewHandle;
@property(nonatomic, assign) CanopyEmitFn* emit;
@property(nonatomic, assign) BOOL emitChange;
@property(nonatomic, assign) BOOL emitSubmit;
@property(nonatomic, assign) BOOL emitFocus;
@property(nonatomic, assign) BOOL emitBlur;
- (void)setEmitChange:(BOOL)c submit:(BOOL)s focus:(BOOL)f blur:(BOOL)b;
- (void)setValueControlled:(NSString*)value;
@end

@implementation CanopyTextInputView {
  BOOL _suppress;
}

- (instancetype)init {
  if (self = [super init]) {
    self.viewHandle = -1;
    self.borderStyle = UITextBorderStyleNone;  // RN inputs carry no platform chrome by default
    self.delegate = self;
    [self addTarget:self action:@selector(onEditingChanged) forControlEvents:UIControlEventEditingChanged];
  }
  return self;
}

- (void)setEmitChange:(BOOL)c submit:(BOOL)s focus:(BOOL)f blur:(BOOL)b {
  self.emitChange = c; self.emitSubmit = s; self.emitFocus = f; self.emitBlur = b;
}

- (void)onEditingChanged {
  if (_suppress || !self.emitChange || !self.emit || !*self.emit || self.viewHandle < 0) return;
  NSString* payload = [NSString stringWithFormat:@"{\"text\":%@}", jsonStr(self.text ?: @"")];
  (*self.emit)(self.viewHandle, "changeText", asStd(payload));
}

// Controlled value: set only when different, keep the cursor at the end, suppress the echo.
- (void)setValueControlled:(NSString*)value {
  NSString* v = value ?: @"";
  if ([v isEqualToString:(self.text ?: @"")]) return;
  _suppress = YES;
  self.text = v;
  UITextPosition* end = self.endOfDocument;
  self.selectedTextRange = [self textRangeFromPosition:end toPosition:end];
  _suppress = NO;
}

- (BOOL)textFieldShouldReturn:(UITextField*)textField {
  if (self.emitSubmit && self.emit && *self.emit && self.viewHandle >= 0) {
    NSString* payload = [NSString stringWithFormat:@"{\"text\":%@}", jsonStr(self.text ?: @"")];
    (*self.emit)(self.viewHandle, "submitEditing", asStd(payload));
  }
  return YES;  // let the IME also act (close keyboard)
}

- (void)textFieldDidBeginEditing:(UITextField*)textField {
  if (self.emitFocus && self.emit && *self.emit && self.viewHandle >= 0)
    (*self.emit)(self.viewHandle, "focus", "{}");
}

- (void)textFieldDidEndEditing:(UITextField*)textField {
  if (self.emitBlur && self.emit && *self.emit && self.viewHandle >= 0)
    (*self.emit)(self.viewHandle, "blur", "{}");
}

@end

// ===========================================================================
// CanopyMultilineTextInputView — controlled UITextView for <TextInput multiline>. A UITextField
// (CanopyTextInputView) physically cannot render multiple lines, so a multiline input is backed
// by a UITextView with a placeholder-label overlay (UITextView has no native placeholder). Emits
// changeText/focus/blur exactly like the single-line input; there is no return-key submit (a
// newline is inserted instead), matching RN's multiline TextInput. The walker emits the same
// RCTSinglelineTextInputView tag + a `multiline` prop, so the host picks this class at createView
// time from the initial props (makeView), the iOS analog of Android's single EditText with a
// multiline inputType flag.
// ===========================================================================
@interface CanopyMultilineTextInputView : UITextView <UITextViewDelegate>
@property(nonatomic, assign) canopy::Handle viewHandle;
@property(nonatomic, assign) CanopyEmitFn* emit;
@property(nonatomic, assign) BOOL emitChange;
@property(nonatomic, assign) BOOL emitSubmit;   // accepted for setEvents API parity; unused (no return-submit)
@property(nonatomic, assign) BOOL emitFocus;
@property(nonatomic, assign) BOOL emitBlur;
@property(nonatomic, strong) UILabel* placeholderLabel;
- (void)setEmitChange:(BOOL)c submit:(BOOL)s focus:(BOOL)f blur:(BOOL)b;
- (void)setValueControlled:(NSString*)value;
@end

@implementation CanopyMultilineTextInputView {
  BOOL _suppress;
}

- (instancetype)init {
  if (self = [super initWithFrame:CGRectZero textContainer:nil]) {
    self.viewHandle = -1;
    self.delegate = self;
    self.backgroundColor = [UIColor clearColor];
    self.textContainerInset = UIEdgeInsetsZero;     // no platform chrome/padding (RN inputs are bare)
    self.textContainer.lineFragmentPadding = 0;
    _placeholderLabel = [[UILabel alloc] init];
    _placeholderLabel.numberOfLines = 0;
    _placeholderLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
    _placeholderLabel.userInteractionEnabled = NO;
    [self addSubview:_placeholderLabel];
  }
  return self;
}

- (void)layoutSubviews {
  [super layoutSubviews];
  _placeholderLabel.font = self.font;  // keep the placeholder in the input's font
  CGSize fit = [_placeholderLabel sizeThatFits:CGSizeMake(self.bounds.size.width, CGFLOAT_MAX)];
  _placeholderLabel.frame = CGRectMake(0, 0, self.bounds.size.width, MIN(fit.height, self.bounds.size.height));
}

- (void)setEmitChange:(BOOL)c submit:(BOOL)s focus:(BOOL)f blur:(BOOL)b {
  self.emitChange = c; self.emitSubmit = s; self.emitFocus = f; self.emitBlur = b;
}

// Controlled value: set only when different, cursor to end, suppress the change echo.
- (void)setValueControlled:(NSString*)value {
  NSString* v = value ?: @"";
  if ([v isEqualToString:(self.text ?: @"")]) return;
  _suppress = YES;
  self.text = v;
  UITextPosition* end = self.endOfDocument;
  self.selectedTextRange = [self textRangeFromPosition:end toPosition:end];
  _suppress = NO;
  _placeholderLabel.hidden = (self.text.length > 0);
}

- (void)textViewDidChange:(UITextView*)textView {
  _placeholderLabel.hidden = (self.text.length > 0);
  if (_suppress || !self.emitChange || !self.emit || !*self.emit || self.viewHandle < 0) return;
  NSString* payload = [NSString stringWithFormat:@"{\"text\":%@}", jsonStr(self.text ?: @"")];
  (*self.emit)(self.viewHandle, "changeText", asStd(payload));
}

- (void)textViewDidBeginEditing:(UITextView*)textView {
  if (self.emitFocus && self.emit && *self.emit && self.viewHandle >= 0)
    (*self.emit)(self.viewHandle, "focus", "{}");
}

- (void)textViewDidEndEditing:(UITextView*)textView {
  if (self.emitBlur && self.emit && *self.emit && self.viewHandle >= 0)
    (*self.emit)(self.viewHandle, "blur", "{}");
}

@end

// ===========================================================================
// CanopySwitchView — controlled UISwitch (analog of CanopySwitch.java).
// ===========================================================================
@interface CanopySwitchView : UISwitch
@property(nonatomic, assign) canopy::Handle viewHandle;
@property(nonatomic, assign) CanopyEmitFn* emit;
@property(nonatomic, assign) BOOL emitValue;
- (void)setCheckedControlled:(BOOL)v;
@end

@implementation CanopySwitchView {
  BOOL _suppress;
}

- (instancetype)init {
  if (self = [super init]) {
    self.viewHandle = 0;
    [self addTarget:self action:@selector(onValueChanged) forControlEvents:UIControlEventValueChanged];
  }
  return self;
}

- (void)onValueChanged {
  if (_suppress || !self.emitValue || !self.emit || !*self.emit || self.viewHandle == 0) return;
  NSString* payload = [NSString stringWithFormat:@"{\"value\":%@}", self.isOn ? @"true" : @"false"];
  (*self.emit)(self.viewHandle, "valueChange", asStd(payload));
}

// Controlled set: skip if unchanged, and never re-fire the change listener.
- (void)setCheckedControlled:(BOOL)v {
  if (self.isOn == v) return;
  _suppress = YES;
  [self setOn:v animated:NO];
  _suppress = NO;
}

@end

// ===========================================================================
// CanopyModalHostView — presented overlay (analog of CanopyModalHost.java, §5.11).
// 0×0 inline node; its children mount into a separate content root (a CanopyContainerView,
// owner==null) presented in an overlay UIViewController over the full screen. Toggled via
// `visible`. A backdrop tap on a transparent modal emits requestClose.
// ===========================================================================
@interface CanopyModalHostView : UIView <CanopyLayoutHost>
@property(nonatomic, assign) canopy::Handle viewHandle;
@property(nonatomic, assign) CanopyEmitFn* emit;
@property(nonatomic, weak) id<CanopyLayoutHost> outerHost;
@property(nonatomic, strong) CanopyContainerView* contentRoot;
@property(nonatomic, assign) BOOL transparent;
@property(nonatomic, copy) NSString* animationType;
- (void)attachContent:(CanopyContainerView*)content;
- (void)setVisibleState:(BOOL)v;
@end

@implementation CanopyModalHostView {
  UIViewController* _presented;
  BOOL _visible;
}

- (void)attachContent:(CanopyContainerView*)content {
  self.contentRoot = content;
  content.layoutHost = self;
}

- (YGNodeRef)yogaNodeForView:(UIView*)view { return [self.outerHost yogaNodeForView:view]; }
- (void)requestRelayout { [self.contentRoot setNeedsLayout]; }
- (void)requestContentRelayout:(UIView*)contentView { [contentView setNeedsLayout]; }

// 0×0 in the inline tree — the real content lives in the presented overlay.
- (CGSize)sizeThatFits:(CGSize)size { return CGSizeZero; }

- (UIViewController*)topPresenter {
  // [MAC-VALIDATE] keyWindow traversal differs slightly across scene/non-scene apps.
  UIWindow* win = nil;
  if (@available(iOS 13.0, *)) {
    for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
      if ([scene isKindOfClass:[UIWindowScene class]]) {
        for (UIWindow* w in ((UIWindowScene*)scene).windows) {
          if (w.isKeyWindow) { win = w; break; }
        }
      }
      if (win) break;
    }
  }
  if (!win) win = UIApplication.sharedApplication.delegate.window;
  UIViewController* vc = win.rootViewController;
  while (vc.presentedViewController) vc = vc.presentedViewController;
  return vc;
}

- (void)setVisibleState:(BOOL)v {
  if (v && !_visible) {
    UIViewController* host = [[UIViewController alloc] init];
    host.modalPresentationStyle = self.transparent ? UIModalPresentationOverFullScreen
                                                    : UIModalPresentationFullScreen;
    if ([self.animationType isEqualToString:@"none"]) host.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    else if ([self.animationType isEqualToString:@"slide"]) host.modalTransitionStyle = UIModalTransitionStyleCoverVertical;
    else host.modalTransitionStyle = UIModalTransitionStyleCrossDissolve; // "fade"/default
    host.view.backgroundColor = self.transparent ? [UIColor colorWithWhite:0 alpha:0.5] : [UIColor whiteColor];
    if (self.contentRoot) {
      self.contentRoot.frame = host.view.bounds;
      self.contentRoot.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
      [host.view addSubview:self.contentRoot];
      [self.contentRoot setNeedsLayout];
    }
    if (self.transparent) {
      UITapGestureRecognizer* tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onBackdropTap:)];
      tap.cancelsTouchesInView = NO;
      [host.view addGestureRecognizer:tap];
    }
    _presented = host;
    BOOL animated = ![self.animationType isEqualToString:@"none"];
    [[self topPresenter] presentViewController:host animated:animated completion:nil];
  } else if (!v && _visible) {
    [_presented dismissViewControllerAnimated:![self.animationType isEqualToString:@"none"] completion:nil];
    _presented = nil;
  }
  _visible = v;
}

- (void)onBackdropTap:(UITapGestureRecognizer*)g {
  // Only a tap on the backdrop itself (not the content) requests close.
  CGPoint p = [g locationInView:_presented.view];
  if (self.contentRoot && CGRectContainsPoint(self.contentRoot.frame, p)) {
    // tap landed inside content — but for a full-bleed sheet content covers all; keep RN
    // semantics: a transparent modal whose content does not fill closes on outside tap.
    return;
  }
  if (self.emit && *self.emit && self.viewHandle != 0)
    (*self.emit)(self.viewHandle, "requestClose", "{}");
}

- (void)willMoveToWindow:(UIWindow*)newWindow {
  [super willMoveToWindow:newWindow];
  if (newWindow == nil && _visible) {  // host view torn down → dismiss to avoid a leaked window
    [_presented dismissViewControllerAnimated:NO completion:nil];
    _presented = nil;
    _visible = NO;
  }
}

@end

// ===========================================================================
// CanopyBeforeAfterView — the C2 wipe compositor (analog of BeforeAfterView.java, §4 / §5.11).
// Two UIImageView layers (before underneath, after on top); the after layer is clipped by a
// CALayer mask to [0..wipe*width]. A pan drag moves the seam locally (zero JS/frame); a
// double-tap snaps to the opposite end. Only wipeStart / wipeCommit cross into JS via emit_.
// ===========================================================================
@interface CanopyBeforeAfterView : UIView
@property(nonatomic, assign) canopy::Handle viewHandle;
@property(nonatomic, assign) CanopyEmitFn* emit;
- (void)setBeforeHandle:(BlobHandle)h;
- (void)setAfterHandle:(BlobHandle)h;
- (void)setWipeFraction:(CGFloat)f;
@end

@implementation CanopyBeforeAfterView {
  UIImageView* _before;
  UIImageView* _after;
  CALayer* _mask;
  BlobHandle _beforeBlob;
  BlobHandle _afterBlob;
  CGFloat _controlled;   // last value Canopy pushed
  CGFloat _wipe;         // what we actually draw
  BOOL _dragging;
  BOOL _snapping;
  CADisplayLink* _snapLink;
  CFTimeInterval _snapStart;
  CGFloat _snapFrom;
  CGFloat _snapTo;
}

- (instancetype)init {
  if (self = [super init]) {
    self.viewHandle = -1;
    _controlled = 0.5;
    _wipe = 0.5;
    self.clipsToBounds = YES;
    _before = [[UIImageView alloc] init];
    _before.contentMode = UIViewContentModeScaleAspectFill;   // cover (center-crop)
    _before.clipsToBounds = YES;
    _after = [[UIImageView alloc] init];
    _after.contentMode = UIViewContentModeScaleAspectFill;
    _after.clipsToBounds = YES;
    [self addSubview:_before];
    [self addSubview:_after];
    _mask = [CALayer layer];
    _mask.backgroundColor = [UIColor whiteColor].CGColor;     // opaque mask = visible region
    _after.layer.mask = _mask;

    UIPanGestureRecognizer* pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    [self addGestureRecognizer:pan];
    UITapGestureRecognizer* dbl = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onDoubleTap:)];
    dbl.numberOfTapsRequired = 2;
    [self addGestureRecognizer:dbl];
  }
  return self;
}

- (void)setBeforeHandle:(BlobHandle)h {
  if (h == _beforeBlob) return;
  _beforeBlob = h;
  _before.image = (h > 0 && canopy::blobGetUIImage) ? canopy::blobGetUIImage(h) : nil;
}

- (void)setAfterHandle:(BlobHandle)h {
  if (h == _afterBlob) return;
  _afterBlob = h;
  _after.image = (h > 0 && canopy::blobGetUIImage) ? canopy::blobGetUIImage(h) : nil;
}

// Controlled wipe position. Ignored while dragging/snapping so the drag stays glitch-free.
- (void)setWipeFraction:(CGFloat)f {
  _controlled = canopy::beforeafter::clampFraction(f);  // SHARED clamp (== Native.BeforeAfter.clamp01)
  if (!_dragging && !_snapping) {
    _wipe = _controlled;
    [self updateMask];
  }
}

- (void)layoutSubviews {
  [super layoutSubviews];
  _before.frame = self.bounds;
  _after.frame = self.bounds;
  [self updateMask];
}

- (void)updateMask {
  // No implicit animation on the seam move (CATransaction disables actions) → 60fps, no JS.
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  CGFloat w = self.bounds.size.width;
  // SHARED split column: round(wipe*width) — byte-identical to the Android clipRect boundary, so the
  // two hosts never differ by a pixel at the seam (canopy::beforeafter::splitColumn).
  CGFloat splitX = (CGFloat)canopy::beforeafter::splitColumn(_wipe, w);
  _mask.frame = CGRectMake(0, 0, splitX, self.bounds.size.height);
  [CATransaction commit];
}

- (void)onPan:(UIPanGestureRecognizer*)g {
  CGFloat w = self.bounds.size.width;
  if (w <= 0) return;
  switch (g.state) {
    case UIGestureRecognizerStateBegan:
      _dragging = YES;
      [self emit:@"wipeStart" payload:@"{}"];
      // fallthrough into the move
    case UIGestureRecognizerStateChanged: {
      CGFloat x = [g locationInView:self].x;
      // SHARED drag mapping: clamp01(x / width) — the finger→fraction rule both hosts share.
      _wipe = canopy::beforeafter::dragFraction(x, w);
      [self updateMask];
      break;
    }
    case UIGestureRecognizerStateEnded:
    case UIGestureRecognizerStateCancelled:
      if (_dragging) {
        _dragging = NO;
        _controlled = _wipe;
        [self emitWipeCommit:_wipe];
      }
      break;
    default: break;
  }
}

- (void)onDoubleTap:(UITapGestureRecognizer*)g {
  CGFloat from = _wipe;
  // SHARED snap target: (wipe >= 0.5) ? 0 : 1 — the same end both hosts snap toward.
  CGFloat to = (CGFloat)canopy::beforeafter::snapTarget(_wipe);
  [self animateFrom:from to:to];
}

- (void)animateFrom:(CGFloat)from to:(CGFloat)to {
  _snapping = YES;
  // [MAC-VALIDATE] CADisplayLink tween (260ms decelerate) mirroring the Android ValueAnimator.
  CADisplayLink* link = [CADisplayLink displayLinkWithTarget:self selector:@selector(onSnapTick:)];
  _snapStart = CACurrentMediaTime();
  _snapFrom = from;
  _snapTo = to;
  [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
  _snapLink = link;
}

- (void)onSnapTick:(CADisplayLink*)link {
  double elapsed = CACurrentMediaTime() - _snapStart;
  // SHARED snap tween: snapValue eases 1-(1-t)^2 over the shared 260ms duration — identical to the
  // Android ValueAnimator(DecelerateInterpolator). One math, two hosts.
  _wipe = (CGFloat)canopy::beforeafter::snapValue(_snapFrom, _snapTo, elapsed);
  [self updateMask];
  if (elapsed >= canopy::beforeafter::snapDurationSeconds()) {
    [link invalidate];
    _snapLink = nil;
    _snapping = NO;
    _controlled = _wipe;
    [self emitWipeCommit:_wipe];
  }
}

// SHARED wipeCommit payload: one formatter ({"fraction":<g>}) so a committed wipe emits the SAME wire
// bytes on iOS and Android (closing the printf-%g vs Java-toString drift). canopy::beforeafter::commitPayloadJson.
- (void)emitWipeCommit:(CGFloat)fraction {
  if (self.emit && *self.emit && self.viewHandle >= 0)
    (*self.emit)(self.viewHandle, std::string("wipeCommit"),
                 canopy::beforeafter::commitPayloadJson(fraction));
}

- (void)emit:(NSString*)name payload:(NSString*)payload {
  if (self.emit && *self.emit && self.viewHandle >= 0)
    (*self.emit)(self.viewHandle, asStd(name), asStd(payload));
}

@end

// ===========================================================================
// CanopyAnimDriver — host-side, CADisplayLink-driven animation engine (analog of
// CanopyAnimDriver.java, contract §5.7 opacity/transform ownership). One per-frame loop
// advances N property animations on any view-by-handle, writing ONLY compositor properties
// (translation/scale/rotation via the layer transform, plus alpha) — never dirtying Yoga.
// Emits coarse animationStart/animationEnd edges via emit_. Idempotent start() (identical
// spec is a no-op). NO density multiply on iOS.
// ===========================================================================
namespace {

enum AnimProp { P_TX = 0, P_TY = 1, P_SCALE = 2, P_SX = 3, P_SY = 4, P_ROT = 5, P_OPACITY = 6, PROP_COUNT = 7 };
enum AnimEasing { E_LINEAR = 0, E_EASE_IN = 1, E_EASE_OUT = 2, E_EASE_IN_OUT = 3 };

// Per-animated-view transform component cache. UIView has no independent translation/scale/
// rotation setters (unlike Android's View.set*), so the driver recomposes the full
// CGAffineTransform from these on every write — RN's native-driver pattern — letting multiple
// animated sub-props (e.g. scale + rotate) coexist without lossy matrix decomposition.
struct TformComps { CGFloat tx = 0, ty = 0, sx = 1, sy = 1, rot = 0; bool seeded = false; };

static int animPropOrdinal(NSString* name) {
  if ([name isEqualToString:@"translateX"]) return P_TX;
  if ([name isEqualToString:@"translateY"]) return P_TY;
  if ([name isEqualToString:@"scale"]) return P_SCALE;
  if ([name isEqualToString:@"scaleX"]) return P_SX;
  if ([name isEqualToString:@"scaleY"]) return P_SY;
  if ([name isEqualToString:@"rotate"]) return P_ROT;
  if ([name isEqualToString:@"opacity"]) return P_OPACITY;
  return -1;
}
static NSString* animPropName(int p) {
  switch (p) {
    case P_TX: return @"translateX"; case P_TY: return @"translateY";
    case P_SCALE: return @"scale"; case P_SX: return @"scaleX"; case P_SY: return @"scaleY";
    case P_ROT: return @"rotate"; default: return @"opacity";
  }
}
static int animEasingOrdinal(NSString* kind) {
  if ([kind isEqualToString:@"easeIn"]) return E_EASE_IN;
  if ([kind isEqualToString:@"easeOut"]) return E_EASE_OUT;
  if ([kind isEqualToString:@"easeInOut"]) return E_EASE_IN_OUT;
  return E_LINEAR;
}

}  // namespace

@interface CanopyAnimDriver : NSObject
@property(nonatomic, assign) CanopyEmitFn* emit;
// Public API (UI/main thread only), mirroring CanopyAnimDriver.java. Declared so the typed
// receiver in CanopyHostIOS sees them.
- (void)start:(canopy::Handle)handle view:(UIView*)v prop:(int)prop
         from:(float)from to:(float)to duration:(double)durMs delay:(double)delayMs
       easing:(int)easing spring:(bool)isSpring stiffness:(float)st damping:(float)dp mass:(float)m;
- (void)cancelAll:(canopy::Handle)handle;
- (bool)isOwned:(canopy::Handle)handle styleKey:(NSString*)key;
- (void)cancelMissing:(canopy::Handle)handle present:(const std::vector<bool>&)present;
@end

@implementation CanopyAnimDriver {
  struct Anim {
    canopy::Handle handle; int prop;
    __weak UIView* view;
    float from, to, current;
    bool fromIsNaN, seededFrom;
    CFTimeInterval startTime, delaySec, durationSec;
    int easing;
    bool isSpring;
    float stiffness, damping, mass, vel;
    bool started, done;
    NSString* sig;
  };
  std::unordered_map<long, Anim> _anims;            // (handle<<8|prop) -> Anim
  std::unordered_map<canopy::Handle, std::vector<bool>> _owned;  // handle -> [PROP_COUNT]
  CADisplayLink* _link;
  CFTimeInterval _lastFrame;
}

static long animKey(canopy::Handle h, int prop) { return ((long)h << 8) | (prop & 0xFF); }

- (instancetype)init {
  if (self = [super init]) { _lastFrame = 0; }
  return self;
}

- (NSString*)sigFrom:(float)from to:(float)to dur:(double)dur delay:(double)delay
              easing:(int)easing spring:(bool)spring st:(float)st damping:(float)dp mass:(float)m {
  return [NSString stringWithFormat:@"%@/%g/%g/%g/%d/%@",
          std::isnan(from) ? @"n" : [NSString stringWithFormat:@"%g", from],
          to, dur, delay, easing,
          spring ? [NSString stringWithFormat:@"s%g,%g,%g", st, dp, m] : @"t"];
}

- (void)start:(canopy::Handle)handle view:(UIView*)v prop:(int)prop
         from:(float)from to:(float)to duration:(double)durMs delay:(double)delayMs
       easing:(int)easing spring:(bool)isSpring stiffness:(float)st damping:(float)dp mass:(float)m {
  long k = animKey(handle, prop);
  NSString* sig = [self sigFrom:from to:to dur:durMs delay:delayMs easing:easing spring:isSpring st:st damping:dp mass:m];
  auto it = _anims.find(k);
  if (it != _anims.end() && [sig isEqualToString:it->second.sig]) return;  // identical spec → no-op

  Anim a = (it != _anims.end()) ? it->second : Anim{};
  a.handle = handle; a.prop = prop; a.view = v; a.sig = sig;
  a.fromIsNaN = std::isnan(from); a.from = from; a.to = to;
  a.durationSec = MAX(0.001, durMs / 1000.0);
  a.delaySec = MAX(0.0, delayMs / 1000.0);
  a.easing = easing; a.isSpring = isSpring;
  a.stiffness = st; a.damping = dp; a.mass = m; a.vel = 0;
  a.startTime = 0; a.started = false; a.seededFrom = false; a.done = false;
  _anims[k] = a;
  [self setOwned:handle prop:prop on:true];
  [self schedule];
}

- (void)cancelAll:(canopy::Handle)handle {
  for (auto it = _anims.begin(); it != _anims.end();) {
    if ((canopy::Handle)(it->first >> 8) == handle) it = _anims.erase(it); else ++it;
  }
  _owned.erase(handle);
}

- (bool)isOwned:(canopy::Handle)handle styleKey:(NSString*)key {
  auto it = _owned.find(handle);
  if (it == _owned.end()) return false;
  const auto& o = it->second;
  if ([key isEqualToString:@"opacity"]) return o[P_OPACITY];
  if ([key isEqualToString:@"transform"])
    return o[P_TX] || o[P_TY] || o[P_SCALE] || o[P_SX] || o[P_SY] || o[P_ROT];
  return false;
}

- (void)cancelMissing:(canopy::Handle)handle present:(const std::vector<bool>&)present {
  for (int p = 0; p < PROP_COUNT; p++) {
    if (!present[p]) {
      _anims.erase(animKey(handle, p));
      auto it = _owned.find(handle);
      if (it != _owned.end()) it->second[p] = false;
    }
  }
}

- (void)setOwned:(canopy::Handle)handle prop:(int)prop on:(bool)on {
  auto it = _owned.find(handle);
  if (it == _owned.end()) {
    if (!on) return;
    _owned[handle] = std::vector<bool>(PROP_COUNT, false);
    it = _owned.find(handle);
  }
  it->second[prop] = on;
}

- (void)schedule {
  if (_link) return;
  _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(doFrame:)];
  [_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)doFrame:(CADisplayLink*)link {
  CFTimeInterval now = link.timestamp;
  CFTimeInterval dtT = (_lastFrame == 0) ? (1.0 / 60.0) : (now - _lastFrame);
  _lastFrame = now;
  float dt = MIN((float)dtT, 1.0f / 30.0f);  // clamp for spring stability

  std::vector<std::pair<canopy::Handle, int>> finished;
  bool anyLive = false;
  for (auto& kv : _anims) {
    Anim& a = kv.second;
    if (a.done) continue;
    UIView* v = a.view;
    if (!v) continue;  // reaped on removeChild

    if (a.startTime == 0) a.startTime = now + a.delaySec;
    if (now < a.startTime) { anyLive = true; continue; }  // still in delay

    if (a.fromIsNaN && !a.seededFrom) { a.from = [self readLive:v prop:a.prop]; a.current = a.from; a.seededFrom = true; }
    else if (!a.seededFrom) { a.current = a.from; a.seededFrom = true; }
    if (!a.started) { a.started = true; [self emitEdge:a.handle name:"animationStart" prop:a.prop]; }

    bool done;
    if (a.isSpring) {
      float pos = a.current, vel = a.vel;
      float accel = (-a.stiffness * (pos - a.to) - a.damping * vel) / a.mass;
      vel += accel * dt; pos += vel * dt;
      a.vel = vel; a.current = pos;
      done = fabsf(pos - a.to) < 1e-3f && fabsf(vel) < 5e-3f;
      if (done) a.current = a.to;
    } else {
      float t = (float)((now - a.startTime) / a.durationSec);
      t = t < 0 ? 0 : (t > 1 ? 1 : t);
      a.current = a.from + (a.to - a.from) * [self ease:a.easing t:t];
      done = t >= 1.0f;
      if (done) a.current = a.to;
    }
    [self applyValue:v prop:a.prop value:a.current];

    if (done) { a.done = true; finished.push_back({a.handle, a.prop}); }
    else anyLive = true;
  }

  for (auto& f : finished) {
    auto it = _owned.find(f.first);
    if (it != _owned.end()) it->second[f.second] = false;  // static style reclaims the prop
    [self emitEdge:f.first name:"animationEnd" prop:f.second];
  }
  if (!anyLive) { [_link invalidate]; _link = nil; _lastFrame = 0; }
}

- (TformComps*)compsFor:(UIView*)v {
  // Stash the component cache on the view via an associated object (one per animated view).
  static const void* kCompsKey = &kCompsKey;
  NSValue* boxed = objc_getAssociatedObject(v, kCompsKey);
  TformComps* c;
  if (boxed) { c = (TformComps*)boxed.pointerValue; }
  else {
    c = new TformComps();
    objc_setAssociatedObject(v, kCompsKey, [NSValue valueWithPointer:c], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  if (!c->seeded) {
    // Seed from the live transform so an animation starting mid-transform composes correctly.
    CGAffineTransform t = v.transform;
    c->tx = t.tx; c->ty = t.ty;
    c->sx = sqrtf(t.a * t.a + t.c * t.c);
    c->sy = sqrtf(t.b * t.b + t.d * t.d);
    c->rot = atan2f(t.b, t.a) * 180.0f / (CGFloat)M_PI;
    c->seeded = true;
  }
  return c;
}

- (void)applyValue:(UIView*)v prop:(int)prop value:(float)value {
  if (prop == P_OPACITY) { v.alpha = value < 0 ? 0 : (value > 1 ? 1 : value); return; }
  TformComps* c = [self compsFor:v];
  switch (prop) {
    case P_TX: c->tx = value; break;   // points (no density multiply)
    case P_TY: c->ty = value; break;
    case P_SCALE: c->sx = value; c->sy = value; break;
    case P_SX: c->sx = value; break;
    case P_SY: c->sy = value; break;
    case P_ROT: c->rot = value; break;
  }
  CGAffineTransform t = CGAffineTransformMakeTranslation(c->tx, c->ty);
  t = CGAffineTransformRotate(t, c->rot * (CGFloat)M_PI / 180.0);
  t = CGAffineTransformScale(t, c->sx, c->sy);
  v.transform = t;
}

- (float)readLive:(UIView*)v prop:(int)prop {
  if (prop == P_OPACITY) return v.alpha;
  TformComps* c = [self compsFor:v];
  switch (prop) {
    case P_TX: return c->tx;
    case P_TY: return c->ty;
    case P_SCALE: case P_SX: return c->sx;
    case P_SY: return c->sy;
    case P_ROT: return c->rot;
  }
  return 0;
}

- (float)ease:(int)e t:(float)t {
  switch (e) {
    case E_EASE_IN: return t * t;
    case E_EASE_OUT: return 1 - (1 - t) * (1 - t);
    case E_EASE_IN_OUT: return t < 0.5f ? 2 * t * t : 1 - 2 * (1 - t) * (1 - t);
    default: return t;
  }
}

- (void)emitEdge:(canopy::Handle)h name:(const char*)name prop:(int)prop {
  if (self.emit && *self.emit) {
    std::string payload = std::string("{\"prop\":\"") + animPropName(prop).UTF8String + "\"}";
    (*self.emit)(h, name, payload);
  }
}

@end

// ===========================================================================
// CanopyGestures — the gesture installer (analog of CanopyGestures.java, §3.2 / §6.7).
// Installs/tears down tap/double/press/pan recognizers on a view→handle, emitting through
// the host's CanopyEmitFn. Press = pressIn(LongPress min=0)/pressOut/longPress + a plain tap
// for "press". Pan emits panStart/pan/panEnd with {dx,dy,vx,vy} in points (no /density).
// ===========================================================================
@interface CanopyGestureTarget : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic, assign) canopy::Handle handle;
@property(nonatomic, assign) CanopyEmitFn* emit;
@property(nonatomic, assign) BOOL wantPan, wantTap, wantDouble, wantPress, wantPressInOut, wantLongPress, wantPinch;
@end

@implementation CanopyGestureTarget {
  CGPoint _panStart;
  BOOL _panDragging;
}

- (void)onPress:(UITapGestureRecognizer*)g {
  if (self.emit && *self.emit) (*self.emit)(self.handle, "press", "{}");
}

- (void)onTap:(UITapGestureRecognizer*)g {
  if (self.wantTap && self.emit && *self.emit) (*self.emit)(self.handle, "tap", "{}");
}

- (void)onDoubleTap:(UITapGestureRecognizer*)g {
  if (self.wantDouble && self.emit && *self.emit) (*self.emit)(self.handle, "doubleTap", "{}");
}

// A 0-duration long press is RN's pressIn/pressOut trick; a real duration is longPress.
- (void)onPressInOut:(UILongPressGestureRecognizer*)g {
  if (!self.emit || !*self.emit) return;
  if (g.state == UIGestureRecognizerStateBegan) (*self.emit)(self.handle, "pressIn", "{}");
  else if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled)
    (*self.emit)(self.handle, "pressOut", "{}");
}

- (void)onLongPress:(UILongPressGestureRecognizer*)g {
  if (g.state == UIGestureRecognizerStateBegan && self.emit && *self.emit)
    (*self.emit)(self.handle, "longPress", "{}");
}

- (void)onPan:(UIPanGestureRecognizer*)g {
  if (!self.emit || !*self.emit) return;
  UIView* v = g.view;
  CGPoint tr = [g translationInView:v];
  switch (g.state) {
    case UIGestureRecognizerStateBegan:
      _panDragging = YES;
      [self emit:"panStart" dx:tr.x dy:tr.y vx:0 vy:0];
      break;
    case UIGestureRecognizerStateChanged:
      [self emit:"pan" dx:tr.x dy:tr.y vx:0 vy:0];
      break;
    case UIGestureRecognizerStateEnded:
    case UIGestureRecognizerStateCancelled: {
      if (_panDragging) {
        CGPoint vel = [g velocityInView:v];  // points/s, no /density
        [self emit:"panEnd" dx:tr.x dy:tr.y vx:vel.x vy:vel.y];
        _panDragging = NO;
      }
      break;
    }
    default: break;
  }
}

- (void)emit:(const char*)name dx:(CGFloat)dx dy:(CGFloat)dy vx:(CGFloat)vx vy:(CGFloat)vy {
  NSString* payload = [NSString stringWithFormat:@"{\"dx\":%g,\"dy\":%g,\"vx\":%g,\"vy\":%g}", dx, dy, vx, vy];
  (*self.emit)(self.handle, name, asStd(payload));
}

// Pinch → pinchStart/pinch/pinchEnd with {scale,focusX,focusY}, matching CanopyGestures.java's
// emitScale. UIPinchGestureRecognizer.scale is ALREADY cumulative from the gesture start (resets
// to 1.0 on began), which is exactly the RN/Android `pinchScale` semantics — no accumulation
// needed here. Focus point is in POINTS (the iOS host's deliberate no-density-divide convention,
// same as the pan velocity above).
- (void)onPinch:(UIPinchGestureRecognizer*)g {
  if (!self.emit || !*self.emit) return;
  const char* name = nullptr;
  switch (g.state) {
    case UIGestureRecognizerStateBegan:     name = "pinchStart"; break;
    case UIGestureRecognizerStateChanged:   name = "pinch";      break;
    case UIGestureRecognizerStateEnded:
    case UIGestureRecognizerStateCancelled: name = "pinchEnd";   break;
    default: return;
  }
  CGPoint f = [g locationInView:g.view];
  NSString* payload =
      [NSString stringWithFormat:@"{\"scale\":%g,\"focusX\":%g,\"focusY\":%g}", g.scale, f.x, f.y];
  (*self.emit)(self.handle, name, asStd(payload));
}

// Let a tap/press coexist with a parent scroll's pan, and double-fails-single.
- (BOOL)gestureRecognizer:(UIGestureRecognizer*)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer*)other {
  return YES;
}

@end

@interface CanopyGestures : NSObject
+ (void)installOn:(UIView*)view handle:(canopy::Handle)h emit:(CanopyEmitFn*)emit
          wantPan:(BOOL)pan wantTap:(BOOL)tap wantDouble:(BOOL)dbl wantPress:(BOOL)press
   wantPressInOut:(BOOL)pio wantLongPress:(BOOL)lp wantPinch:(BOOL)pinch;
+ (void)teardown:(UIView*)view;
@end

// Associated-object key so we can find/replace the installed target on a reused view.
static const void* kCanopyGestureTargetKey = &kCanopyGestureTargetKey;

@implementation CanopyGestures

+ (void)teardown:(UIView*)view {
  // Remove only the recognizers we installed (their delegate is our prev target). A reused view
  // that dropped its gestures must not keep a live recognizer firing to the old handle.
  CanopyGestureTarget* prev = objc_getAssociatedObject(view, kCanopyGestureTargetKey);
  if (!prev) return;
  for (UIGestureRecognizer* g in [view.gestureRecognizers copy]) {
    if (g.delegate == prev) [view removeGestureRecognizer:g];
  }
  objc_setAssociatedObject(view, kCanopyGestureTargetKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

+ (void)installOn:(UIView*)view handle:(canopy::Handle)h emit:(CanopyEmitFn*)emit
          wantPan:(BOOL)pan wantTap:(BOOL)tap wantDouble:(BOOL)dbl wantPress:(BOOL)press
   wantPressInOut:(BOOL)pio wantLongPress:(BOOL)lp wantPinch:(BOOL)pinch {
  [self teardown:view];
  if (!(pan || tap || dbl || press || pio || lp || pinch)) return;
  view.userInteractionEnabled = YES;
  CanopyGestureTarget* t = [[CanopyGestureTarget alloc] init];
  t.handle = h; t.emit = emit;
  t.wantPan = pan; t.wantTap = tap; t.wantDouble = dbl; t.wantPress = press;
  t.wantPressInOut = pio; t.wantLongPress = lp; t.wantPinch = pinch;
  objc_setAssociatedObject(view, kCanopyGestureTargetKey, t, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

  if (press) {
    UITapGestureRecognizer* g = [[UITapGestureRecognizer alloc] initWithTarget:t action:@selector(onPress:)];
    g.delegate = t;
    [view addGestureRecognizer:g];
  }
  if (tap) {
    UITapGestureRecognizer* g = [[UITapGestureRecognizer alloc] initWithTarget:t action:@selector(onTap:)];
    g.delegate = t;
    [view addGestureRecognizer:g];
  }
  UITapGestureRecognizer* dblG = nil;
  if (dbl) {
    dblG = [[UITapGestureRecognizer alloc] initWithTarget:t action:@selector(onDoubleTap:)];
    dblG.numberOfTapsRequired = 2;
    dblG.delegate = t;
    [view addGestureRecognizer:dblG];
    // A single tap (press/tap) should wait for the double to fail.
    for (UIGestureRecognizer* g in view.gestureRecognizers) {
      if ([g isKindOfClass:[UITapGestureRecognizer class]] &&
          ((UITapGestureRecognizer*)g).numberOfTapsRequired == 1) {
        [g requireGestureRecognizerToFail:dblG];
      }
    }
  }
  if (pio) {
    UILongPressGestureRecognizer* g = [[UILongPressGestureRecognizer alloc] initWithTarget:t action:@selector(onPressInOut:)];
    g.minimumPressDuration = 0;  // RN pressIn/pressOut
    g.delegate = t;
    [view addGestureRecognizer:g];
  }
  if (lp) {
    UILongPressGestureRecognizer* g = [[UILongPressGestureRecognizer alloc] initWithTarget:t action:@selector(onLongPress:)];
    g.minimumPressDuration = 0.5;
    g.delegate = t;
    [view addGestureRecognizer:g];
  }
  if (pan) {
    UIPanGestureRecognizer* g = [[UIPanGestureRecognizer alloc] initWithTarget:t action:@selector(onPan:)];
    g.delegate = t;
    [view addGestureRecognizer:g];
  }
  if (pinch) {
    UIPinchGestureRecognizer* g = [[UIPinchGestureRecognizer alloc] initWithTarget:t action:@selector(onPinch:)];
    g.delegate = t;  // simultaneous with pan/tap via shouldRecognizeSimultaneously (above)
    [view addGestureRecognizer:g];
  }
}

@end

// ===========================================================================
// The host itself.
// ===========================================================================
@interface CanopyHostBridge : NSObject <CanopyLayoutHost>
@end

class CanopyHostIOS : public CanopyHost {
 public:
  CanopyHostIOS(UIView* surface, CanopyEmitFn emit) : surface_(surface), emit_(std::move(emit)) {
    bridge_ = [[CanopyHostBridge alloc] init];
    animDriver_ = [[CanopyAnimDriver alloc] init];
    animDriver_.emit = &emit_;
  }

  // ---- __fabric_* surface ---------------------------------------------------

  canopy::Handle createView(const std::string& name, const std::string& propsJson) override {
    return createAt(next_++, name, propsJson);
  }

  // RND-7 batch variant: create a view at a JS-CHOSEN handle. The batched __fabric_applyBatch path
  // (CanopyFabric.cpp::applyBinaryBatch / applyJsonBatch) allocates handles on the JS side — the
  // walker cannot block on a host return when collapsing a whole frame into ONE host call — and then
  // refers to the new view by THAT handle in every following op of the same batch (kUpdate/kScalar/
  // kInsert/kSetEvents). So the create MUST register the view under `h`, not a host-minted next_++,
  // or every post-create op in the frame would miss the views_ map and silently no-op (the iOS host
  // would render nothing under batching). `h` arrives from the high base the shared installer
  // advertises (__fabric_batchHandleBase = 0x40000000), kept clear of the small per-mutation next_
  // counter, so the two handle spaces never collide and we DO NOT touch next_. Returns `h`, echoed so
  // the shared C++ marshalling has a return shaped like the 2-arg createView. This is the line-for-
  // line iOS twin of CanopyHost.java::createViewWithHandle (which also forwards to a shared createAt).
  //
  // [MAC-VALIDATE] Written + golden-mirrored against the Android host (createViewWithHandle/createAt)
  // and pinned device-free by harness/run-batch.js (the batched mock replays kCreate at the JS handle)
  // and scripts/check-ios-marshalling.sh; NOT compiled here (no macOS/xcrun in this sandbox). It is a
  // strictly ADDITIVE override of a DEFAULTED CanopyHost method (CanopyFabric.h's 3-arg default ignored
  // the handle), so CANOPY_ABI_VERSION is deliberately NOT bumped.
  canopy::Handle createView(const std::string& name, const std::string& propsJson, canopy::Handle h) override {
    return createAt(h, name, propsJson);
  }

  // The shared create body, reached by BOTH the per-mutation 2-arg createView (host-minted next_++)
  // and the batched 3-arg createView (JS-chosen handle). Building the view, its Yoga node, the
  // ScrollView/Modal content roots, the leaf measure fn, and the view↔handle maps is IDENTICAL in
  // both paths — only the handle source differs. Mirrors CanopyHost.java::createAt. (Kept inline with
  // the __fabric_* surface, not in the private section, so the two createView overrides read together.)
  canopy::Handle createAt(canopy::Handle h, const std::string& name, const std::string& propsJson) {
    CView cv;
    cv.fabricName = name;
    cv.isLeaf = isLeaf(name);
    cv.view = makeView(name, h, propsJson);
    cv.yoga = YGNodeNew();
    YGNodeSetContext(cv.yoga, (void*)(intptr_t)h);

    // ScrollView / Modal: build the SEPARATE Yoga content root (owner==null). Children mount
    // into IT (§5.11). Its container is a CanopyContainerView whose layoutHost is the
    // scroll/modal view (so it lays its own children out as a fresh root).
    if ([cv.view isKindOfClass:[CanopyScrollView class]]) {
      CanopyContainerView* content = [[CanopyContainerView alloc] init];
      cv.contentYoga = YGNodeNew();
      YGNodeSetContext(cv.contentYoga, (void*)(intptr_t)kContentSentinel);
      contentNodes_[content] = cv.contentYoga;
      cv.contentView = content;
      CanopyScrollView* sv = (CanopyScrollView*)cv.view;
      sv.outerHost = bridge_;
      [sv attachContent:content];
    } else if ([cv.view isKindOfClass:[CanopyModalHostView class]]) {
      CanopyContainerView* content = [[CanopyContainerView alloc] init];
      cv.contentYoga = YGNodeNew();
      YGNodeSetContext(cv.contentYoga, (void*)(intptr_t)kContentSentinel);
      contentNodes_[content] = cv.contentYoga;
      cv.contentView = content;
      CanopyModalHostView* mh = (CanopyModalHostView*)cv.view;
      mh.outerHost = bridge_;
      [mh attachContent:content];
    }

    if (cv.isLeaf) {
      YGNodeSetMeasureFunc(cv.yoga, &CanopyHostIOS::leafMeasureThunk);
    }
    // Map the view back to its handle so layout/measure can resolve the CView. A content-root
    // container is resolved separately via contentNodes_ (checked first in yogaNodeForView).
    viewToHandle_[cv.view] = h;

    views_[h] = cv;
    self_for_thunk_ = this;
    applyProps(h, propsJson);
    return h;
  }

  void updateProps(canopy::Handle h, const std::string& propsJson) override {
    applyProps(h, propsJson);
    requestRelayout();
  }

  void insertChild(canopy::Handle parent, canopy::Handle child, int index) override {
    auto pit = views_.find(parent), cit = views_.find(child);
    if (pit == views_.end() || cit == views_.end()) return;
    CView& p = pit->second;
    CView& c = cit->second;

    if (c.view.superview) [c.view removeFromSuperview];
    if (YGNodeGetOwner(c.yoga)) YGNodeRemoveChild(YGNodeGetOwner(c.yoga), c.yoga);

    // Content-host indirection: a ScrollView/Modal routes children into its content root.
    YGNodeRef pYoga = p.contentYoga ? p.contentYoga : p.yoga;
    UIView* pView = p.contentView ? p.contentView : p.view;
    int count = (int)YGNodeGetChildCount(pYoga);
    int i = (index < 0 || index > count) ? count : index;
    YGNodeInsertChild(pYoga, c.yoga, i);
    [pView insertSubview:c.view atIndex:i];

    if (p.contentView) [p.contentView setNeedsLayout];  // a separate root the main pass misses
    requestRelayout();
  }

  void removeChild(canopy::Handle parent, canopy::Handle child, int) override {
    auto pit = views_.find(parent), cit = views_.find(child);
    if (pit == views_.end() || cit == views_.end()) return;
    CView& p = pit->second;
    CView& c = cit->second;
    if (YGNodeGetOwner(c.yoga)) YGNodeRemoveChild(YGNodeGetOwner(c.yoga), c.yoga);
    [c.view removeFromSuperview];
    [animDriver_ cancelAll:child];  // no frame callback hits a dead view
    if (p.contentView) [p.contentView setNeedsLayout];
    requestRelayout();
  }

  void setRoot(canopy::Handle h) override {
    root_ = h;
    auto it = views_.find(h);
    if (it == views_.end()) return;
    UIView* rv = it->second.view;
    rv.frame = surface_.bounds;
    rv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    if ([rv isKindOfClass:[CanopyContainerView class]]) ((CanopyContainerView*)rv).layoutHost = bridge_;
    [surface_ addSubview:rv];
    requestRelayout();
  }

  void setEvents(canopy::Handle h, const std::string& namesJson) override {
    auto it = views_.find(h);
    if (it == views_.end()) return;
    CView& cv = it->second;
    NSString* names = [NSString stringWithUTF8String:namesJson.c_str()];

    // ScrollView: scroll/refresh subscriptions; then fall through to gesture wiring.
    if ([cv.view isKindOfClass:[CanopyScrollView class]]) {
      CanopyScrollView* sv = (CanopyScrollView*)cv.view;
      sv.emitScroll = [names containsString:@"\"scroll\""];
      sv.emitRefresh = [names containsString:@"\"refresh\""];
    }
    // TextInput: configure its delegate flags, then return (not pressable).
    if ([cv.view isKindOfClass:[CanopyTextInputView class]]) {
      [(CanopyTextInputView*)cv.view setEmitChange:[names containsString:@"\"changeText\""]
                                            submit:[names containsString:@"\"submitEditing\""]
                                             focus:[names containsString:@"\"focus\""]
                                              blur:[names containsString:@"\"blur\""]];
      return;
    }
    if ([cv.view isKindOfClass:[CanopyMultilineTextInputView class]]) {
      [(CanopyMultilineTextInputView*)cv.view setEmitChange:[names containsString:@"\"changeText\""]
                                                     submit:[names containsString:@"\"submitEditing\""]
                                                      focus:[names containsString:@"\"focus\""]
                                                       blur:[names containsString:@"\"blur\""]];
      return;
    }
    // Switch: valueChange; then return.
    if ([cv.view isKindOfClass:[CanopySwitchView class]]) {
      ((CanopySwitchView*)cv.view).emitValue = [names containsString:@"\"valueChange\""];
      return;
    }

    // "press" must be an exact quoted token, NOT a substring of longPress/pressIn/pressOut.
    BOOL wantPress = [names containsString:@"\"press\""];
    BOOL wantPressInOut = [names containsString:@"\"pressIn\""] || [names containsString:@"\"pressOut\""];
    BOOL wantLongPress = [names containsString:@"\"longPress\""];
    BOOL wantPan = [names containsString:@"\"pan\""] || [names containsString:@"\"panStart\""] || [names containsString:@"\"panEnd\""];
    BOOL wantTap = [names containsString:@"\"tap\""];
    BOOL wantDouble = [names containsString:@"\"doubleTap\""];
    BOOL wantPinch = [names containsString:@"\"pinch\""];

    // Idempotent: a reused view that lost an event must lose its recognizer.
    [CanopyGestures installOn:cv.view handle:h emit:&emit_
                      wantPan:wantPan wantTap:wantTap wantDouble:wantDouble wantPress:wantPress
               wantPressInOut:wantPressInOut wantLongPress:wantLongPress wantPinch:wantPinch];
  }

  // ---- imperative command seam (IOS-8 / reconciled with AND-3's ONE __fabric_command seam) ----
  //
  // The walker calls __fabric_command(handle, name, argsJson) for ops that aren't expressible as
  // declarative props — focus/blur a text input, measure a view's frame, scroll to an offset. This
  // is the EXACT iOS twin of CanopyHost.java::command (AND-4): the op runs HERE on the main thread
  // (like every __fabric_* call) and its result returns ASYNC via emit_(handle, "__commandResult",
  // resultJson) — the SAME event path press/gesture/text use — so JS decodes it through
  // __canopy_dispatchEvent like any other native event. Every result echoes the JS-supplied
  // __callId so the walker routes concurrent ops on one handle each to their own one-shot.
  //
  // Ops whose answer is only valid post-layout (focus's IME, measure's window coords) DEFER to the
  // next runloop turn (dispatch_async to the main queue) so the frame is settled when they run —
  // the iOS analog of Android's View.post(). A freshly mounted UITextField is not yet in a window
  // when the command arrives, and becomeFirstResponder on an unattached view is a no-op (the
  // canonical RN focus-timing bug); deferring also lets a `value`-set that rode the same frame land
  // first, so the caret/IME target the final text.
  //
  //   focus          → becomeFirstResponder + show the keyboard               → {ok:true|false}
  //   blur           → resignFirstResponder + hide the keyboard               → {ok:true}
  //   measure        → Yoga frame (offset/size, points) + window coords       → {x,y,width,height,pageX,pageY}
  //   scrollTo       → setContentOffset(x,y) (points)                         → {ok:true}
  //   scrollToIndex  → resolve child N's Yoga frame, scroll to it             → {ok:true} | {ok:false}
  //
  // NO density multiply (iOS Yoga/UIKit are in points; contract §0.3), unlike Android's ÷density.
  //
  // [MAC-VALIDATE] Authored + golden-mirrored against the Android Java host (AND-4) but NOT compiled
  // here (no macOS/xcrun in this sandbox). The pure JSON marshalling (parseCallId/measureResultJson/
  // mergeCallId) IS unit-tested device-free; the UIKit behaviours (becomeFirstResponder, keyboard,
  // setContentOffset) need a Simulator (CanopyHostValidationTests.swift).
  void command(canopy::Handle h, const std::string& name, const std::string& argsJson) override {
    NSString* op = [NSString stringWithUTF8String:name.c_str()] ?: @"";
    NSDictionary* args = parseArgs(argsJson);
    std::string callId = parseCallId(args);  // a JSON value literal (number/string/null), echoed verbatim

    auto it = views_.find(h);
    if (it == views_.end()) {
      emitCommandResult(h, callId, "{\"ok\":false,\"error\":\"unknown handle\"}");
      return;
    }
    UIView* view = it->second.view;

    if ([op isEqualToString:@"focus"])              commandFocus(h, view, callId, true);
    else if ([op isEqualToString:@"blur"])          commandFocus(h, view, callId, false);
    else if ([op isEqualToString:@"measure"])       commandMeasure(h, callId);
    else if ([op isEqualToString:@"scrollTo"])      commandScrollTo(h, view, callId, args);
    else if ([op isEqualToString:@"scrollToIndex"]) commandScrollToIndex(h, callId, args);
    else {
      // Unknown op: acknowledge with the AND-3 echo shape so a forward-compat walker still sees a
      // result (never a silent drop), carrying the echoed callId.
      NSData* ad = [NSJSONSerialization dataWithJSONObject:args options:0 error:nil];
      std::string argsStr = ad ? std::string((const char*)ad.bytes, ad.length) : "{}";
      emitCommandResult(h, callId, std::string("{\"name\":") + asStd(jsonStr(op)) + ",\"args\":" + argsStr + "}");
    }
  }

  // focus/blur: becomeFirstResponder/resignFirstResponder + toggle the keyboard. Deferred to the
  // next main-runloop turn so it runs AFTER the current mount/layout settles (a freshly mounted
  // UITextField is not yet attached to a window, and becomeFirstResponder on it is a no-op — the RN
  // focus-timing bug). The result hops back via emit_ on the main thread (already where we are).
  void commandFocus(canopy::Handle h, UIView* view, const std::string& callId, bool focus) {
    dispatch_async(dispatch_get_main_queue(), ^{
      bool ok;
      if (focus) ok = (bool)[view becomeFirstResponder];
      else { [view resignFirstResponder]; ok = true; }
      emitCommandResult(h, callId, std::string("{\"ok\":") + (ok ? "true" : "false") + "}");
    });
  }

  // measure: report the view's frame. x/y are the offset within the parent (from the Yoga frame),
  // width/height the laid-out size, pageX/pageY the absolute position in window coordinates
  // (convertRect:toView:nil) — the RN UIManager.measure contract. All lengths are in points (NO
  // density divide; iOS Yoga/UIKit are already in points). Deferred so the frame is settled (a
  // measure issued in the same frame as the mount would read a 0×0 pre-layout frame).
  void commandMeasure(canopy::Handle h, const std::string& callId) {
    dispatch_async(dispatch_get_main_queue(), ^{
      auto mit = views_.find(h);
      if (mit == views_.end()) { emitCommandResult(h, callId, "{\"ok\":false,\"error\":\"unknown handle\"}"); return; }
      UIView* v = mit->second.view;
      YGNodeRef y = mit->second.yoga;
      float x = y ? YGNodeLayoutGetLeft(y) : 0;
      float yy = y ? YGNodeLayoutGetTop(y) : 0;
      float w = (float)v.bounds.size.width;
      float ht = (float)v.bounds.size.height;
      // Absolute window position: convert the view's bounds origin into window (nil) coordinates.
      CGRect inWindow = [v convertRect:v.bounds toView:nil];
      float pageX = (float)inWindow.origin.x;
      float pageY = (float)inWindow.origin.y;
      emitCommandResult(h, callId, measureResultJson(x, yy, w, ht, pageX, pageY));
    });
  }

  // scrollTo: drive the ScrollView to an absolute offset (points). On iOS the CanopyScrollView IS the
  // UIScrollView (no nested scroller, unlike Android's composite), so we set its contentOffset
  // directly. A non-scroll target is a no-op success (RN's permissive scrollTo on a plain view).
  // animated:true tweens; false jumps.
  void commandScrollTo(canopy::Handle h, UIView* view, const std::string& callId, NSDictionary* args) {
    float x = optArgFloat(args, @"x", 0);
    float y = optArgFloat(args, @"y", 0);
    BOOL animated = optArgBool(args, @"animated", YES);
    dispatch_async(dispatch_get_main_queue(), ^{
      if ([view isKindOfClass:[UIScrollView class]]) {
        [(UIScrollView*)view setContentOffset:CGPointMake(x, y) animated:animated];
      }
      emitCommandResult(h, callId, "{\"ok\":true}");
    });
  }

  // scrollToIndex: put child N of the ScrollView's content on screen. We resolve child N's settled
  // Yoga frame in the inner content root (the scroll-axis offset) and scroll the scroll view to it.
  // Out-of-range N (or a non-scroll target) returns ok:false so the app can react. Deferred so the
  // content's Yoga frames are computed.
  void commandScrollToIndex(canopy::Handle h, const std::string& callId, NSDictionary* args) {
    int index = (int)optArgFloat(args, @"index", 0);
    BOOL animated = optArgBool(args, @"animated", YES);
    dispatch_async(dispatch_get_main_queue(), ^{
      auto sit = views_.find(h);
      if (sit == views_.end()) { emitCommandResult(h, callId, "{\"ok\":false}"); return; }
      UIView* v = sit->second.view;
      YGNodeRef contentYoga = sit->second.contentYoga;
      if (![v isKindOfClass:[UIScrollView class]] || contentYoga == nullptr ||
          index < 0 || index >= (int)YGNodeGetChildCount(contentYoga)) {
        emitCommandResult(h, callId, "{\"ok\":false}");
        return;
      }
      YGNodeRef child = YGNodeGetChild(contentYoga, index);
      // Yoga frames are already in points (no density on iOS), so they target the scroll view directly.
      CGFloat cx = roundf(YGNodeLayoutGetLeft(child));
      CGFloat cy = roundf(YGNodeLayoutGetTop(child));
      [(UIScrollView*)v setContentOffset:CGPointMake(cx, cy) animated:animated];
      emitCommandResult(h, callId, "{\"ok\":true}");
    });
  }

  // ---- command marshalling helpers (pure where possible; unit-tested device-free) ----------
  //
  // The pure JSON helpers (parseCallId / measureResultJson / mergeCallId) are file-private statics
  // here AND mirrored as a reviewable reference spec in CanopyValidationLedgerTests.mm; the lint
  // scripts/check-ios-command-seam.sh ties the two so neither can drift. They are the line-for-line
  // iOS twins of CanopyHost.java's parseCallId/measureResultJson/mergeCallId (AND-4).

  // Parse the command args JSON to an NSDictionary (empty → {}); never throws.
  static NSDictionary* parseArgs(const std::string& argsJson) {
    if (argsJson.empty()) return @{};
    NSData* d = [[NSString stringWithUTF8String:argsJson.c_str()] dataUsingEncoding:NSUTF8StringEncoding];
    id obj = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    return [obj isKindOfClass:[NSDictionary class]] ? obj : @{};
  }

  static float optArgFloat(NSDictionary* args, NSString* k, float def) {
    id v = args[k];
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber*)v floatValue];
    if ([v isKindOfClass:[NSString class]]) { float f = asFloat(v); return std::isnan(f) ? def : f; }
    return def;
  }
  static BOOL optArgBool(NSDictionary* args, NSString* k, BOOL def) {
    id v = args[k];
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber*)v boolValue];
    if ([v isKindOfClass:[NSString class]]) return [(NSString*)v isEqualToString:@"true"];
    return def;
  }

  // Pull __callId from the command args as a JSON value LITERAL (number/string), echoed verbatim into
  // the result so the walker routes by it. Absent/null → "null" (the walker then falls back to its
  // per-handle one-shot, AND-3 behaviour). Twin of CanopyHost.java::parseCallId.
  static std::string parseCallId(NSDictionary* args) {
    id v = args[@"__callId"];
    if (v == nil || [v isKindOfClass:[NSNull class]]) return "null";
    if ([v isKindOfClass:[NSNumber class]]) {
      // A numeric callId (the walker's default): emit as a bare number literal, integral when whole.
      double d = [(NSNumber*)v doubleValue];
      if (d == floor(d) && !isinf(d)) return std::to_string((long long)d);
      return asStd([NSString stringWithFormat:@"%g", d]);
    }
    // A string callId → quoted JSON literal.
    return asStd(jsonStr([NSString stringWithFormat:@"%@", v]));
  }

  // Build the measure result payload (point lengths) the RN UIManager.measure contract returns.
  // Twin of CanopyHost.java::measureResultJson. Integral lengths compact (no trailing ".0").
  static std::string measureResultJson(float x, float y, float width, float height,
                                       float pageX, float pageY) {
    return std::string("{\"x\":") + fmtNum(x) + ",\"y\":" + fmtNum(y)
        + ",\"width\":" + fmtNum(width) + ",\"height\":" + fmtNum(height)
        + ",\"pageX\":" + fmtNum(pageX) + ",\"pageY\":" + fmtNum(pageY) + "}";
  }

  // Inject "__callId":<callId> as the FIRST member of a result object literal ("{...}") so the JS
  // dispatcher can route the async result to the matching per-callId one-shot. callId is already a
  // JSON value literal (number/quoted-string/"null"); resultBody is spliced verbatim. Twin of
  // CanopyHost.java::mergeCallId.
  static std::string mergeCallId(const std::string& callId, const std::string& resultBody) {
    std::string body = resultBody.length() < 2 ? "{}" : resultBody;
    std::string inner = body.substr(1, body.length() - 2);  // drop the outer braces
    // trim surrounding whitespace
    size_t a = inner.find_first_not_of(" \t\r\n");
    size_t b = inner.find_last_not_of(" \t\r\n");
    inner = (a == std::string::npos) ? std::string() : inner.substr(a, b - a + 1);
    return std::string("{\"__callId\":") + callId + (inner.empty() ? "" : "," + inner) + "}";
  }

  // Compact float→JSON: drop a trailing ".0" so integers read as integers (10, not 10.0).
  static std::string fmtNum(float v) {
    if (v == floorf(v) && !std::isinf(v)) return std::to_string((long long)v);
    return asStd([NSString stringWithFormat:@"%g", v]);
  }

  // Splice the echoed __callId into a result object and emit it on the __commandResult event path —
  // the SAME emit_ closure press/gesture/text use, so JS decodes it via __canopy_dispatchEvent.
  void emitCommandResult(canopy::Handle h, const std::string& callId, const std::string& resultBody) {
    if (emit_) emit_(h, "__commandResult", mergeCallId(callId, resultBody));
  }

  // __fabric_updatePropScalar(handle, key, value) — the AND-8 single-scalar fast path. The walker
  // routes the dominant per-frame mutations (a UILabel's text, an input/switch value, a view's
  // opacity) here so they skip the JSON.stringify/parse + NSJSONSerialization decode that updateProps
  // pays. `value` is always an NSString (a numeric opacity is stringified at the JS boundary),
  // matching how applyProps already coerces everything via optStr/asFloat — so this is byte-for-byte
  // equivalent to the JSON path, minus the marshalling. NON-scalar/null/multi-key mutations never
  // reach here (the walker keeps them on updateProps), so this only ever SETS one value.
  //
  // [MAC-VALIDATE] This override is written + golden-mirrored against the Android Java host but has
  // NOT been compiled here (no macOS/xcrun in this sandbox). It is a strictly ADDITIVE override of a
  // defaulted CanopyHost method, so even un-overridden it would behave correctly (the C++ default in
  // CanopyFabric.h reconstructs {key:value} and reuses updateProps); this just realizes the win.
  void updatePropScalar(canopy::Handle h, const std::string& key, const std::string& value) override {
    auto it = views_.find(h);
    if (it == views_.end()) return;
    CView& cv = it->second;
    NSString* v = [NSString stringWithUTF8String:value.c_str()];
    if (key == "text") {
      if ([cv.view isKindOfClass:[UILabel class]]) {
        ((UILabel*)cv.view).text = v ?: @"";
        markDirty(cv);
      }
    } else if (key == "value") {
      if ([cv.view isKindOfClass:[CanopyTextInputView class]]) {
        [(CanopyTextInputView*)cv.view setValueControlled:(v ?: @"")];
        markDirty(cv);
      } else if ([cv.view isKindOfClass:[CanopyMultilineTextInputView class]]) {
        [(CanopyMultilineTextInputView*)cv.view setValueControlled:(v ?: @"")];
        markDirty(cv);
      } else if ([cv.view isKindOfClass:[CanopySwitchView class]]) {
        [(CanopySwitchView*)cv.view setCheckedControlled:[v isEqualToString:@"true"]];
      }
    } else if (key == "opacity") {
      CGFloat f = v ? (CGFloat)[v doubleValue] : 1.0;
      cv.baseOpacity = f;
      if (![animDriver_ isOwned:h styleKey:@"opacity"]) cv.view.alpha = f;
    } else {
      // Unknown scalar key (host newer than walker) — fall back to the JSON path, nothing dropped.
      NSString* k = [NSString stringWithUTF8String:key.c_str()];
      NSDictionary* obj = @{ k: (v ?: @"") };
      NSData* d = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
      if (d) applyProps(h, std::string((const char*)d.bytes, d.length));
    }
    requestRelayout();
  }

  void requestFrame(std::function<void()> cb) override {
    // Back by a single shared CADisplayLink: enqueue, fire once on next vsync, pause. (§5.12)
    frameCallbacks_.push_back(std::move(cb));
    if (!frameLink_) {
      // [MAC-VALIDATE] vsync cadence. We drive via a CADisplayLink wrapper object.
      frameLink_ = [CADisplayLink displayLinkWithTarget:bridge_ selector:@selector(onFrameTick:)];
      [frameLink_ addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    }
  }

  // Called from the bridge's CADisplayLink.
  void drainFrameCallbacks() {
    if (frameLink_) { [frameLink_ invalidate]; frameLink_ = nil; }
    std::vector<std::function<void()>> cbs;
    cbs.swap(frameCallbacks_);
    for (auto& cb : cbs) cb();
  }

  // ---- CanopyLayoutHost (via the bridge) ------------------------------------

  YGNodeRef yogaNodeForView(UIView* view) {
    auto cnit = contentNodes_.find(view);
    if (cnit != contentNodes_.end()) return cnit->second;  // a content root container
    auto it = viewToHandle_.find(view);
    if (it == viewToHandle_.end()) return nullptr;
    auto vit = views_.find(it->second);
    return vit == views_.end() ? nullptr : vit->second.yoga;
  }

  void requestRelayoutPublic() { requestRelayout(); }

  // The Obj-C layout/frame shim. Public so CanopyHostMake can wire its back-pointer.
  CanopyHostBridge* bridge() { return bridge_; }

 private:
  static constexpr intptr_t kContentSentinel = -7;  // marks content-root Yoga node context

  // ---- view construction ----------------------------------------------------

  static bool isLeaf(const std::string& name) {
    return name == "RCTText" || name == "RCTRawText" || name == "RCTImageView" ||
           name == "RCTSinglelineTextInputView" || name == "ActivityIndicator" ||
           name == "RCTSwitch" || name == "CanopyBitmap";
    // BeforeAfter is deliberately NOT a leaf (always explicitly sized). (§5.3)
  }

  UIView* makeView(const std::string& name, canopy::Handle h, const std::string& propsJson) {
    if (name == "RCTText" || name == "RCTRawText") {
      UILabel* l = [[UILabel alloc] init];
      l.numberOfLines = 0;
      return l;
    }
    if (name == "RCTImageView") { UIImageView* iv = [[UIImageView alloc] init]; iv.clipsToBounds = YES; return iv; }
    if (name == "CanopyBitmap")  { UIImageView* iv = [[UIImageView alloc] init]; iv.clipsToBounds = YES; return iv; }
    if (name == "RCTSinglelineTextInputView") {
      // multiline → UITextView-backed view (UITextField cannot render multiple lines). Decided
      // from the initial props, matching RN's separate single/multiline input components and
      // Android's single EditText switched by a multiline inputType flag.
      NSData* pd = [[NSString stringWithUTF8String:propsJson.c_str()] dataUsingEncoding:NSUTF8StringEncoding];
      NSDictionary* p0 = pd ? [NSJSONSerialization JSONObjectWithData:pd options:0 error:nil] : nil;
      if ([p0 isKindOfClass:[NSDictionary class]] && boolEq(p0, @"multiline", @"true")) {
        CanopyMultilineTextInputView* tv = [[CanopyMultilineTextInputView alloc] init];
        tv.viewHandle = h; tv.emit = &emit_;
        return tv;
      }
      CanopyTextInputView* ti = [[CanopyTextInputView alloc] init];
      ti.viewHandle = h; ti.emit = &emit_;
      return ti;
    }
    if (name == "RCTScrollView") {
      CanopyScrollView* sv = [[CanopyScrollView alloc] init];
      sv.viewHandle = h; sv.emit = &emit_;
      return sv;
    }
    if (name == "CanopyModalHost") {
      CanopyModalHostView* mh = [[CanopyModalHostView alloc] init];
      mh.viewHandle = h; mh.emit = &emit_;
      return mh;
    }
    if (name == "ActivityIndicator") {
      UIActivityIndicatorView* ai = [[UIActivityIndicatorView alloc] init];
      [ai startAnimating];
      ai.hidesWhenStopped = NO;
      return ai;
    }
    if (name == "RCTSwitch") {
      CanopySwitchView* sw = [[CanopySwitchView alloc] init];
      sw.viewHandle = h; sw.emit = &emit_;
      return sw;
    }
    if (name == "BeforeAfter") {
      CanopyBeforeAfterView* ba = [[CanopyBeforeAfterView alloc] init];
      ba.viewHandle = h; ba.emit = &emit_;
      return ba;
    }
    // default: RCTView / RCTRootView → a Yoga-driven container.
    CanopyContainerView* c = [[CanopyContainerView alloc] init];
    c.layoutHost = bridge_;
    return c;
  }

  // ---- leaf measure (§5.5) --------------------------------------------------

  static CanopyHostIOS* self_for_thunk_;  // single host per app; set in createView

  static YGSize leafMeasureThunk(YGNodeRef node, float width, YGMeasureMode wMode,
                                 float height, YGMeasureMode hMode) {
    CanopyHostIOS* self = self_for_thunk_;
    if (!self) return (YGSize){0, 0};
    canopy::Handle h = (canopy::Handle)(intptr_t)YGNodeGetContext(node);
    auto it = self->views_.find(h);
    if (it == self->views_.end()) return (YGSize){0, 0};
    UIView* v = it->second.view;
    CGSize constraint = CGSizeMake(
        wMode == YGMeasureModeUndefined ? CGFLOAT_MAX : width,
        hMode == YGMeasureModeUndefined ? CGFLOAT_MAX : height);
    CGSize measured = [v sizeThatFits:constraint];
    float mw = (float)ceilf(measured.width);
    float mh = (float)ceilf(measured.height);
    if (wMode == YGMeasureModeExactly) mw = width;
    else if (wMode == YGMeasureModeAtMost) mw = MIN(mw, width);
    if (hMode == YGMeasureModeExactly) mh = height;
    else if (hMode == YGMeasureModeAtMost) mh = MIN(mh, height);
    return (YGSize){mw, mh};
  }

  void markDirty(CView& cv) { if (cv.isLeaf && YGNodeHasMeasureFunc(cv.yoga)) YGNodeMarkDirty(cv.yoga); }

  // ---- props ----------------------------------------------------------------

  // JSON helpers operating on the parsed NSDictionary, mirroring Android's optX/isNull.
  static BOOL has(NSDictionary* p, NSString* k) { return p[k] != nil; }
  static BOOL isNull(NSDictionary* p, NSString* k) { return [p[k] isKindOfClass:[NSNull class]]; }
  static NSString* optStr(NSDictionary* p, NSString* k) {
    id v = p[k];
    if ([v isKindOfClass:[NSString class]]) return v;
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber*)v stringValue];
    return nil;
  }
  static int optInt(NSDictionary* p, NSString* k) {
    id v = p[k];
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber*)v intValue];
    if ([v isKindOfClass:[NSString class]]) return [(NSString*)v intValue];
    return 0;
  }
  static BOOL boolEq(NSDictionary* p, NSString* k, NSString* want) {
    return [optStr(p, k) isEqualToString:want];
  }

  void applyProps(canopy::Handle h, const std::string& propsJson) {
    @try {
      NSData* data = [[NSString stringWithUTF8String:propsJson.c_str()] dataUsingEncoding:NSUTF8StringEncoding];
      NSDictionary* props = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
      if (![props isKindOfClass:[NSDictionary class]]) return;
      auto it = views_.find(h);
      if (it == views_.end()) return;
      CView& cv = it->second;

      // Text (UILabel, not the input).
      if (has(props, @"text") && [cv.view isKindOfClass:[UILabel class]]) {
        ((UILabel*)cv.view).text = isNull(props, @"text") ? @"" : (optStr(props, @"text") ?: @"");
        markDirty(cv);
      }
      // TextInput.
      if ([cv.view isKindOfClass:[CanopyTextInputView class]]) {
        CanopyTextInputView* ti = (CanopyTextInputView*)cv.view;
        if (has(props, @"value")) { [ti setValueControlled:isNull(props, @"value") ? @"" : (optStr(props, @"value") ?: @"")]; markDirty(cv); }
        if (has(props, @"placeholder")) ti.placeholder = isNull(props, @"placeholder") ? nil : optStr(props, @"placeholder");
        if (has(props, @"placeholderTextColor") && !isNull(props, @"placeholderTextColor")) {
          UIColor* c = [CanopyColor parse:optStr(props, @"placeholderTextColor")];
          if (c && ti.placeholder) ti.attributedPlaceholder = [[NSAttributedString alloc] initWithString:ti.placeholder
                                                                attributes:@{NSForegroundColorAttributeName: c}];
        }
        if (has(props, @"editable")) ti.enabled = !boolEq(props, @"editable", @"false");
        BOOL multiline = boolEq(props, @"multiline", @"true");
        BOOL secure = boolEq(props, @"secureTextEntry", @"true");
        NSString* kb = optStr(props, @"keyboardType") ?: @"default";
        if (has(props, @"keyboardType") || has(props, @"secureTextEntry") || has(props, @"multiline")) {
          ti.secureTextEntry = secure;
          if ([kb isEqualToString:@"numeric"] || [kb isEqualToString:@"number-pad"]) ti.keyboardType = UIKeyboardTypeNumberPad;
          else if ([kb isEqualToString:@"decimal-pad"]) ti.keyboardType = UIKeyboardTypeDecimalPad;
          else if ([kb isEqualToString:@"phone-pad"]) ti.keyboardType = UIKeyboardTypePhonePad;
          else if ([kb isEqualToString:@"email-address"]) ti.keyboardType = UIKeyboardTypeEmailAddress;
          else ti.keyboardType = UIKeyboardTypeDefault;
          markDirty(cv);
        }
      }
      // Multiline TextInput (UITextView-backed).
      if ([cv.view isKindOfClass:[CanopyMultilineTextInputView class]]) {
        CanopyMultilineTextInputView* tv = (CanopyMultilineTextInputView*)cv.view;
        if (has(props, @"value")) { [tv setValueControlled:isNull(props, @"value") ? @"" : (optStr(props, @"value") ?: @"")]; markDirty(cv); }
        if (has(props, @"placeholder")) {
          tv.placeholderLabel.text = isNull(props, @"placeholder") ? @"" : (optStr(props, @"placeholder") ?: @"");
          tv.placeholderLabel.hidden = (tv.text.length > 0);
          [tv setNeedsLayout];
        }
        if (has(props, @"placeholderTextColor") && !isNull(props, @"placeholderTextColor")) {
          UIColor* c = [CanopyColor parse:optStr(props, @"placeholderTextColor")];
          if (c) tv.placeholderLabel.textColor = c;
        }
        if (has(props, @"editable")) tv.editable = !boolEq(props, @"editable", @"false");
        if (has(props, @"keyboardType") || has(props, @"secureTextEntry")) {
          NSString* kb = optStr(props, @"keyboardType") ?: @"default";
          tv.secureTextEntry = boolEq(props, @"secureTextEntry", @"true");
          if ([kb isEqualToString:@"numeric"] || [kb isEqualToString:@"number-pad"]) tv.keyboardType = UIKeyboardTypeNumberPad;
          else if ([kb isEqualToString:@"decimal-pad"]) tv.keyboardType = UIKeyboardTypeDecimalPad;
          else if ([kb isEqualToString:@"phone-pad"]) tv.keyboardType = UIKeyboardTypePhonePad;
          else if ([kb isEqualToString:@"email-address"]) tv.keyboardType = UIKeyboardTypeEmailAddress;
          else tv.keyboardType = UIKeyboardTypeDefault;
        }
      }
      // ActivityIndicator.
      if ([cv.view isKindOfClass:[UIActivityIndicatorView class]]) {
        UIActivityIndicatorView* ai = (UIActivityIndicatorView*)cv.view;
        if (has(props, @"color") && !isNull(props, @"color")) ai.color = [CanopyColor parse:optStr(props, @"color")];
        if (has(props, @"animating")) {
          if (boolEq(props, @"animating", @"false")) { [ai stopAnimating]; ai.hidden = YES; }
          else { [ai startAnimating]; ai.hidden = NO; }
        }
      }
      // Switch.
      if ([cv.view isKindOfClass:[CanopySwitchView class]]) {
        CanopySwitchView* sw = (CanopySwitchView*)cv.view;
        if (has(props, @"value")) [sw setCheckedControlled:boolEq(props, @"value", @"true")];
        if (has(props, @"disabled")) sw.enabled = !boolEq(props, @"disabled", @"true");
      }
      // ScrollView.
      if ([cv.view isKindOfClass:[CanopyScrollView class]]) {
        CanopyScrollView* sv = (CanopyScrollView*)cv.view;
        if (has(props, @"horizontal")) {
          BOOL horiz = boolEq(props, @"horizontal", @"true");
          [sv setHorizontalMode:horiz];
          if (cv.contentYoga) YGNodeStyleSetFlexDirection(cv.contentYoga, horiz ? YGFlexDirectionRow : YGFlexDirectionColumn);
        }
        if (has(props, @"scrollEnabled")) [sv setScrollLocked:boolEq(props, @"scrollEnabled", @"false")];
        if (has(props, @"refreshControl")) [sv setRefreshControlEnabled:boolEq(props, @"refreshControl", @"true")];
        if (has(props, @"refreshing")) [sv setRefreshing:boolEq(props, @"refreshing", @"true")];
      }
      // canopy/image: blob handle.
      if (has(props, @"bitmapHandle") && [cv.view isKindOfClass:[UIImageView class]]) {
        int bh = isNull(props, @"bitmapHandle") ? 0 : optInt(props, @"bitmapHandle");
        UIImage* img = (bh != 0 && canopy::blobGetUIImage) ? canopy::blobGetUIImage(bh) : nil;
        ((UIImageView*)cv.view).image = img;
        cv.lastSource = nil;  // a blob supersedes a declarative source
        markDirty(cv);
      }
      // Image resizeMode → contentMode.
      if (has(props, @"resizeMode") && [cv.view isKindOfClass:[UIImageView class]]) {
        ((UIImageView*)cv.view).contentMode = scaleMode(isNull(props, @"resizeMode") ? @"cover" : (optStr(props, @"resizeMode") ?: @"cover"));
      }
      // Image declarative source (only if no bitmapHandle).
      if (has(props, @"source") && [cv.view isKindOfClass:[UIImageView class]] && !has(props, @"bitmapHandle")) {
        NSString* src = isNull(props, @"source") ? nil : optStr(props, @"source");
        applyImageSource(h, cv, src);
      }
      // BeforeAfter.
      if ([cv.view isKindOfClass:[CanopyBeforeAfterView class]]) {
        CanopyBeforeAfterView* ba = (CanopyBeforeAfterView*)cv.view;
        if (has(props, @"beforeHandle")) [ba setBeforeHandle:isNull(props, @"beforeHandle") ? 0 : optInt(props, @"beforeHandle")];
        if (has(props, @"afterHandle"))  [ba setAfterHandle:isNull(props, @"afterHandle") ? 0 : optInt(props, @"afterHandle")];
        if (has(props, @"wipeFraction")) {
          float f = 0.5f;
          if (!isNull(props, @"wipeFraction")) { NSString* s = optStr(props, @"wipeFraction"); float v = asFloat(s); f = std::isnan(v) ? 0.5f : v; }
          [ba setWipeFraction:f];
        }
      }
      // Modal — visible LAST so transparency/animation are set first.
      if ([cv.view isKindOfClass:[CanopyModalHostView class]]) {
        CanopyModalHostView* mh = (CanopyModalHostView*)cv.view;
        if (has(props, @"transparent")) mh.transparent = boolEq(props, @"transparent", @"true");
        if (has(props, @"animationType")) mh.animationType = optStr(props, @"animationType");
        if (has(props, @"visible")) [mh setVisibleState:boolEq(props, @"visible", @"true")];
      }
      // style.
      if ([props[@"style"] isKindOfClass:[NSDictionary class]]) applyStyle(h, cv, props[@"style"]);
      // animations — AFTER style so a NaN `from` reads the resting value.
      if (has(props, @"animations")) applyAnimations(h, cv, props);

      // accessibility + test identity (T0).
      if (has(props, @"testID") || has(props, @"accessibilityLabel")) {
        if (has(props, @"testID")) cv.testID = isNull(props, @"testID") ? nil : optStr(props, @"testID");
        if (has(props, @"accessibilityLabel")) cv.a11yLabel = isNull(props, @"accessibilityLabel") ? nil : optStr(props, @"accessibilityLabel");
        cv.view.accessibilityIdentifier = cv.testID;  // XCUITest selector
        cv.view.accessibilityLabel = cv.a11yLabel ?: cv.testID;
        cv.view.isAccessibilityElement = (cv.a11yLabel != nil || cv.testID != nil);
      }
      if (has(props, @"accessibilityRole")) {
        cv.a11yRole = isNull(props, @"accessibilityRole") ? nil : optStr(props, @"accessibilityRole");
        applyA11yRole(cv);
      }
      if (has(props, @"accessibilityHint")) {
        cv.a11yHint = isNull(props, @"accessibilityHint") ? nil : optStr(props, @"accessibilityHint");
        cv.view.accessibilityHint = cv.a11yHint;
      }
      if (has(props, @"accessible")) {
        cv.view.isAccessibilityElement = !isNull(props, @"accessible") && boolEq(props, @"accessible", @"true");
      }
      // __events: re-run setEvents on a diff (the walker re-sends the full name list).
      if (has(props, @"__events")) {
        id ev = props[@"__events"];
        NSData* evData = [NSJSONSerialization dataWithJSONObject:ev options:0 error:nil];
        std::string evJson = evData ? std::string((const char*)evData.bytes, evData.length) : "[]";
        setEvents(h, evJson);
      }
    } @catch (__unused NSException* e) {}
  }

  void applyA11yRole(CView& cv) {
    // Map RN role → UIAccessibilityTraits. We REPLACE traits (don't OR) so a recycled view drops
    // a stale role (an iOS improvement over the Android OR-only path).
    UIAccessibilityTraits t = UIAccessibilityTraitNone;
    NSString* r = cv.a11yRole;
    if ([r isEqualToString:@"button"] || [r isEqualToString:@"link"]) t = UIAccessibilityTraitButton;
    else if ([r isEqualToString:@"image"]) t = UIAccessibilityTraitImage;
    else if ([r isEqualToString:@"header"]) t = UIAccessibilityTraitHeader;
    if (r) cv.view.isAccessibilityElement = YES;
    cv.view.accessibilityTraits = t;
  }

  void applyImageSource(canopy::Handle h, CView& cv, NSString* src) {
    UIImageView* iv = (UIImageView*)cv.view;
    if (src == nil || src.length == 0) {
      cv.lastSource = nil;
      iv.image = nil;
      markDirty(cv);
      return;
    }
    if ([src isEqualToString:cv.lastSource]) return;  // unchanged → no re-fetch
    cv.lastSource = src;
    __block NSString* expected = src;
    loadImage(src, ^(UIImage* img, NSString* error) {
      // recycle-check: drop if the view moved to a different source meanwhile.
      auto it2 = views_.find(h);
      if (it2 == views_.end() || ![expected isEqualToString:it2->second.lastSource]) return;
      if (img) {
        iv.image = img;
        markDirty(it2->second);
        requestRelayout();
        if (emit_) emit_(h, "load", "{}");
      } else if (emit_) {
        emit_(h, "error", asStd([NSString stringWithFormat:@"{\"error\":%@}", jsonStr(error)]));
      }
      if (emit_) emit_(h, "loadEnd", "{}");
    });
  }

  // Load a URL/file/asset image, always completing on the MAIN queue.
  // [MAC-VALIDATE] network/file IO behaviour on device.
  void loadImage(NSString* src, void (^cb)(UIImage*, NSString*)) {
    void (^complete)(UIImage*, NSString*) = ^(UIImage* img, NSString* err) {
      dispatch_async(dispatch_get_main_queue(), ^{ cb(img, err); });
    };
    if ([src hasPrefix:@"http://"] || [src hasPrefix:@"https://"]) {
      NSURL* url = [NSURL URLWithString:src];
      NSURLSessionDataTask* task = [[NSURLSession sharedSession] dataTaskWithURL:url
          completionHandler:^(NSData* d, NSURLResponse* r, NSError* e) {
            UIImage* img = d ? [UIImage imageWithData:d] : nil;
            complete(img, img ? nil : (e.localizedDescription ?: @"load failed"));
          }];
      [task resume];
    } else if ([src hasPrefix:@"file://"] || [src hasPrefix:@"/"]) {
      NSString* path = [src hasPrefix:@"file://"] ? [[NSURL URLWithString:src] path] : src;
      dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        UIImage* img = [UIImage imageWithContentsOfFile:path];
        complete(img, img ? nil : @"file not found");
      });
    } else {
      // a bundled asset name
      UIImage* img = [UIImage imageNamed:src];
      complete(img, img ? nil : @"asset not found");
    }
  }

  // ---- style ----------------------------------------------------------------

  void applyStyle(canopy::Handle h, CView& cv, NSDictionary* style) {
    YGNodeRef y = cv.yoga;
    for (NSString* key in style) {
      id raw = style[key];
      if ([raw isKindOfClass:[NSNull class]]) { resetStyleKey(h, cv, y, key); continue; }
      NSString* s = [raw isKindOfClass:[NSString class]] ? raw :
                    ([raw isKindOfClass:[NSNumber class]] ? [(NSNumber*)raw stringValue] : [raw description]);
      float f = asFloat(s);
      bool hasF = !std::isnan(f);

      if ([key isEqualToString:@"width"]) setDimWidth(y, s, f);
      else if ([key isEqualToString:@"height"]) setDimHeight(y, s, f);
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
      else if ([key isEqualToString:@"backgroundColor"]) { cv.bgColor = [CanopyColor parse:s]; applyBackground(cv); }
      else if ([key isEqualToString:@"borderRadius"]) applyBorderRadius(cv, s, f);
      else if ([key isEqualToString:@"borderTopLeftRadius"]) setCorner(cv, 0, f);
      else if ([key isEqualToString:@"borderTopRightRadius"]) setCorner(cv, 1, f);
      else if ([key isEqualToString:@"borderBottomRightRadius"]) setCorner(cv, 2, f);
      else if ([key isEqualToString:@"borderBottomLeftRadius"]) setCorner(cv, 3, f);
      else if ([key isEqualToString:@"borderWidth"]) { if (hasF) { cv.borderWidth = f; YGNodeStyleSetBorder(y, YGEdgeAll, f); applyBackground(cv); } }
      else if ([key isEqualToString:@"borderColor"]) { cv.borderColor = [CanopyColor parse:s]; applyBackground(cv); }
      else if ([key isEqualToString:@"border"]) applyBorderShorthand(cv, y, s);
      else if ([key isEqualToString:@"opacity"]) { if (hasF) { cv.baseOpacity = f; if (![animDriver_ isOwned:h styleKey:@"opacity"]) cv.view.alpha = f; } }
      else if ([key isEqualToString:@"aspectRatio"]) { if (hasF) YGNodeStyleSetAspectRatio(y, f); }
      else if ([key isEqualToString:@"display"]) YGNodeStyleSetDisplay(y, [s isEqualToString:@"none"] ? YGDisplayNone : YGDisplayFlex);
      else if ([key isEqualToString:@"overflow"]) applyOverflow(cv, s);
      else if ([key isEqualToString:@"elevation"]) { if (hasF) applyShadow(cv, f); }
      else if ([key isEqualToString:@"boxShadow"] || [key isEqualToString:@"shadowRadius"]) applyShadow(cv, shadowElevation(s));
      else if ([key isEqualToString:@"transform"]) { cv.baseTransform = s; if (![animDriver_ isOwned:h styleKey:@"transform"]) applyTransform(cv.view, s); }
      else if ([key isEqualToString:@"color"]) {
        if ([cv.view isKindOfClass:[UILabel class]]) { cv.textColor = [CanopyColor parse:s]; ((UILabel*)cv.view).textColor = cv.textColor; markDirty(cv); }
      }
      else if ([key isEqualToString:@"fontSize"]) {
        if (hasF && [cv.view isKindOfClass:[UILabel class]]) { setFontSize((UILabel*)cv.view, f); markDirty(cv); }
      }
      else if ([key isEqualToString:@"fontWeight"]) {
        if ([cv.view isKindOfClass:[UILabel class]]) { setFontWeight((UILabel*)cv.view, s); markDirty(cv); }
      }
      else if ([key isEqualToString:@"textAlign"]) {
        if ([cv.view isKindOfClass:[UILabel class]])
          ((UILabel*)cv.view).textAlignment =
              [s isEqualToString:@"center"] ? NSTextAlignmentCenter
            : [s isEqualToString:@"right"] ? NSTextAlignmentRight
            : NSTextAlignmentLeft;
      }
    }
  }

  // Dim setter handling "NN%" / "auto" / points.
  void setDimWidth(YGNodeRef y, NSString* s, float f) {
    if ([s hasSuffix:@"%"]) { float p = [[s substringToIndex:s.length - 1] floatValue]; YGNodeStyleSetWidthPercent(y, p); }
    else if ([s isEqualToString:@"auto"]) YGNodeStyleSetWidthAuto(y);
    else if (!std::isnan(f)) YGNodeStyleSetWidth(y, f);
  }
  void setDimHeight(YGNodeRef y, NSString* s, float f) {
    if ([s hasSuffix:@"%"]) { float p = [[s substringToIndex:s.length - 1] floatValue]; YGNodeStyleSetHeightPercent(y, p); }
    else if ([s isEqualToString:@"auto"]) YGNodeStyleSetHeightAuto(y);
    else if (!std::isnan(f)) YGNodeStyleSetHeight(y, f);
  }

  void resetStyleKey(canopy::Handle h, CView& cv, YGNodeRef y, NSString* key) {
    if ([key isEqualToString:@"width"]) YGNodeStyleSetWidthAuto(y);
    else if ([key isEqualToString:@"height"]) YGNodeStyleSetHeightAuto(y);
    else if ([key isEqualToString:@"minWidth"]) YGNodeStyleSetMinWidth(y, YGUndefined);
    else if ([key isEqualToString:@"minHeight"]) YGNodeStyleSetMinHeight(y, YGUndefined);
    else if ([key isEqualToString:@"maxWidth"]) YGNodeStyleSetMaxWidth(y, YGUndefined);
    else if ([key isEqualToString:@"maxHeight"]) YGNodeStyleSetMaxHeight(y, YGUndefined);
    else if ([key isEqualToString:@"flex"]) { YGNodeStyleSetFlex(y, YGUndefined); YGNodeStyleSetFlexGrow(y, 0); YGNodeStyleSetFlexShrink(y, 0); YGNodeStyleSetFlexBasisAuto(y); }
    else if ([key isEqualToString:@"flexGrow"]) YGNodeStyleSetFlexGrow(y, 0);
    else if ([key isEqualToString:@"flexShrink"]) YGNodeStyleSetFlexShrink(y, 0);
    else if ([key isEqualToString:@"flexBasis"]) YGNodeStyleSetFlexBasisAuto(y);
    else if ([key isEqualToString:@"gap"]) YGNodeStyleSetGap(y, YGGutterAll, 0);
    else if ([key hasPrefix:@"padding"]) YGNodeStyleSetPadding(y, edgeFor(key), 0);
    else if ([key hasPrefix:@"margin"]) YGNodeStyleSetMargin(y, edgeFor(key), 0);
    else if ([key isEqualToString:@"top"]) YGNodeStyleSetPosition(y, YGEdgeTop, YGUndefined);
    else if ([key isEqualToString:@"bottom"]) YGNodeStyleSetPosition(y, YGEdgeBottom, YGUndefined);
    else if ([key isEqualToString:@"left"]) YGNodeStyleSetPosition(y, YGEdgeLeft, YGUndefined);
    else if ([key isEqualToString:@"right"]) YGNodeStyleSetPosition(y, YGEdgeRight, YGUndefined);
    else if ([key isEqualToString:@"position"]) YGNodeStyleSetPositionType(y, YGPositionTypeRelative);
    else if ([key isEqualToString:@"flexDirection"]) YGNodeStyleSetFlexDirection(y, YGFlexDirectionColumn);
    else if ([key isEqualToString:@"justifyContent"]) YGNodeStyleSetJustifyContent(y, YGJustifyFlexStart);
    else if ([key isEqualToString:@"alignItems"]) YGNodeStyleSetAlignItems(y, YGAlignStretch);
    else if ([key isEqualToString:@"alignSelf"]) YGNodeStyleSetAlignSelf(y, YGAlignAuto);
    else if ([key isEqualToString:@"backgroundColor"]) { cv.bgColor = nil; applyBackground(cv); }
    else if ([key isEqualToString:@"borderRadius"]) { cv.borderRadius = 0; clearCorners(cv); applyBackground(cv); }
    else if ([key hasPrefix:@"border"] && [key hasSuffix:@"Radius"]) { clearCorners(cv); applyBackground(cv); }
    else if ([key isEqualToString:@"borderWidth"]) { cv.borderWidth = 0; YGNodeStyleSetBorder(y, YGEdgeAll, YGUndefined); applyBackground(cv); }
    else if ([key isEqualToString:@"borderColor"]) { cv.borderColor = nil; applyBackground(cv); }
    else if ([key isEqualToString:@"border"]) { cv.borderWidth = 0; cv.borderColor = nil; YGNodeStyleSetBorder(y, YGEdgeAll, YGUndefined); applyBackground(cv); }
    else if ([key isEqualToString:@"opacity"]) { cv.baseOpacity = 1; if (![animDriver_ isOwned:h styleKey:@"opacity"]) cv.view.alpha = 1; }
    else if ([key isEqualToString:@"aspectRatio"]) YGNodeStyleSetAspectRatio(y, YGUndefined);
    else if ([key isEqualToString:@"display"]) YGNodeStyleSetDisplay(y, YGDisplayFlex);
    else if ([key isEqualToString:@"overflow"]) applyOverflow(cv, @"visible");
    else if ([key isEqualToString:@"elevation"] || [key isEqualToString:@"boxShadow"] || [key isEqualToString:@"shadowRadius"]) applyShadow(cv, 0);
    else if ([key isEqualToString:@"transform"]) { cv.baseTransform = nil; if (![animDriver_ isOwned:h styleKey:@"transform"]) applyTransform(cv.view, nil); }
    else if ([key isEqualToString:@"color"]) { if ([cv.view isKindOfClass:[UILabel class]]) { cv.textColor = [UIColor blackColor]; ((UILabel*)cv.view).textColor = cv.textColor; markDirty(cv); } }
    else if ([key isEqualToString:@"fontSize"]) { if ([cv.view isKindOfClass:[UILabel class]]) { setFontSize((UILabel*)cv.view, 14); markDirty(cv); } }
    else if ([key isEqualToString:@"fontWeight"]) { if ([cv.view isKindOfClass:[UILabel class]]) { setFontWeight((UILabel*)cv.view, @"normal"); markDirty(cv); } }
    else if ([key isEqualToString:@"textAlign"]) { if ([cv.view isKindOfClass:[UILabel class]]) ((UILabel*)cv.view).textAlignment = NSTextAlignmentLeft; }
    else if ([key isEqualToString:@"flexWrap"]) YGNodeStyleSetFlexWrap(y, YGWrapNoWrap);
  }

  static YGEdge edgeFor(NSString* key) {
    if ([key hasSuffix:@"Top"]) return YGEdgeTop;
    if ([key hasSuffix:@"Bottom"]) return YGEdgeBottom;
    if ([key hasSuffix:@"Left"]) return YGEdgeLeft;
    if ([key hasSuffix:@"Right"]) return YGEdgeRight;
    if ([key hasSuffix:@"Horizontal"]) return YGEdgeHorizontal;
    if ([key hasSuffix:@"Vertical"]) return YGEdgeVertical;
    return YGEdgeAll;
  }

  static void clearCorners(CView& cv) { for (int i = 0; i < 4; i++) cv.corners[i] = NAN; }

  // CALayer-driven rounded/bordered background (analog of GradientDrawable). Per-corner radii via
  // maskedCorners when uniform; an explicit CAShapeLayer mask when per-corner differ.
  void applyBackground(CView& cv) {
    UIView* v = cv.view;
    CALayer* layer = v.layer;
    bool hasRound = cv.borderRadius > 0 || hasCorners(cv);
    bool hasBorder = cv.borderWidth > 0 && cv.borderColor != nil;
    if (cv.bgColor == nil && !hasRound && !hasBorder) {
      v.backgroundColor = nil;
      layer.cornerRadius = 0;
      layer.borderWidth = 0;
      layer.mask = nil;
      return;
    }
    if (cv.bgColor) v.backgroundColor = cv.bgColor;
    if (hasBorder) { layer.borderWidth = cv.borderWidth; layer.borderColor = cv.borderColor.CGColor; }
    else { layer.borderWidth = 0; }
    if (hasCorners(cv)) {
      // Different corners: build a rounded-rect mask path on layout. We approximate by using the
      // max corner as cornerRadius + maskedCorners when corners are 0-or-equal; else a shape mask.
      CGFloat tl = std::isnan(cv.corners[0]) ? 0 : cv.corners[0];
      CGFloat tr = std::isnan(cv.corners[1]) ? 0 : cv.corners[1];
      CGFloat br = std::isnan(cv.corners[2]) ? 0 : cv.corners[2];
      CGFloat bl = std::isnan(cv.corners[3]) ? 0 : cv.corners[3];
      if (tl == tr && tr == br && br == bl) {
        layer.cornerRadius = tl; layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner | kCALayerMaxXMaxYCorner | kCALayerMinXMaxYCorner;
        layer.mask = nil;
      } else {
        // [MAC-VALIDATE] per-corner mask path is recomputed on layout via the container; here we
        // set a uniform fallback to the largest corner so the view is at least rounded.
        layer.cornerRadius = MAX(MAX(tl, tr), MAX(br, bl));
        layer.maskedCorners = (tl > 0 ? kCALayerMinXMinYCorner : 0) | (tr > 0 ? kCALayerMaxXMinYCorner : 0) |
                              (br > 0 ? kCALayerMaxXMaxYCorner : 0) | (bl > 0 ? kCALayerMinXMaxYCorner : 0);
      }
    } else {
      layer.cornerRadius = cv.borderRadius;
      layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner | kCALayerMaxXMaxYCorner | kCALayerMinXMaxYCorner;
    }
    if (hasRound) layer.masksToBounds = YES;
  }

  // borderRadius: uniform ("16") OR the 4-corner shorthand ("16 0 0 0" = TL TR BR BL).
  void applyBorderRadius(CView& cv, NSString* s, float f) {
    if (s && [s containsString:@" "]) {
      NSArray<NSString*>* p = [[s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]
                               componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
      NSMutableArray<NSString*>* parts = [NSMutableArray array];
      for (NSString* t in p) if (t.length) [parts addObject:t];
      if (parts.count == 4) {
        for (int i = 0; i < 4; i++) { float v = asFloat(parts[i]); cv.corners[i] = std::isnan(v) ? 0 : v; }
        applyBackground(cv);
        return;
      }
    }
    if (!std::isnan(f)) { cv.borderRadius = f; clearCorners(cv); applyBackground(cv); }
  }

  void setCorner(CView& cv, int idx, float f) {
    if (std::isnan(f)) return;
    if (!hasCorners(cv)) { for (int i = 0; i < 4; i++) cv.corners[i] = cv.borderRadius; }  // seed from uniform
    cv.corners[idx] = f;
    applyBackground(cv);
  }

  // `border: <width> [style] <color>` → width (number) + color (last color-ish token).
  void applyBorderShorthand(CView& cv, YGNodeRef y, NSString* s) {
    if (!s) return;
    for (NSString* tok in [s componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]) {
      if (tok.length == 0) continue;
      float w = asFloat(tok);
      if (!std::isnan(w)) { cv.borderWidth = w; YGNodeStyleSetBorder(y, YGEdgeAll, w); }
      else if ([tok hasPrefix:@"#"] || [tok hasPrefix:@"rgb"] || [tok hasPrefix:@"hsl"]) cv.borderColor = [CanopyColor parse:tok];
      else if (![tok isEqualToString:@"solid"] && ![tok isEqualToString:@"none"]) cv.borderColor = [CanopyColor parse:tok];
    }
    applyBackground(cv);
  }

  // overflow:hidden/scroll → clip to bounds.
  void applyOverflow(CView& cv, NSString* s) {
    BOOL hidden = [s isEqualToString:@"hidden"] || [s isEqualToString:@"scroll"];
    cv.view.clipsToBounds = hidden;
  }

  // CSS box-shadow / shadowRadius → the largest length token (points), applied as a layer shadow.
  float shadowElevation(NSString* s) {
    if (!s) return 0;
    float max = 0;
    for (NSString* tok in [s componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" ,()"]]) {
      NSString* t = [tok hasSuffix:@"px"] ? [tok substringToIndex:tok.length - 2] : tok;
      float v = asFloat(t);
      if (!std::isnan(v) && v > max) max = v;
    }
    return max;
  }

  void applyShadow(CView& cv, float radius) {
    CALayer* layer = cv.view.layer;
    if (radius <= 0) { layer.shadowOpacity = 0; return; }
    layer.shadowColor = [UIColor blackColor].CGColor;
    layer.shadowOpacity = 0.3f;
    layer.shadowRadius = radius;
    layer.shadowOffset = CGSizeMake(0, radius / 2.0f);
    layer.masksToBounds = NO;  // a shadow needs to draw outside bounds
  }

  // CSS transform list → CGAffineTransform (translate/scale/rotate). null/empty → identity.
  static void applyTransform(UIView* v, NSString* s) {
    if (s == nil || s.length == 0) { v.transform = CGAffineTransformIdentity; return; }
    CGFloat tx = 0, ty = 0, sx = 1, sy = 1, rot = 0;
    NSRegularExpression* re = [NSRegularExpression regularExpressionWithPattern:@"([a-zA-Z0-9]+)\\(([^)]*)\\)" options:0 error:nil];
    for (NSTextCheckingResult* m in [re matchesInString:s options:0 range:NSMakeRange(0, s.length)]) {
      NSString* fn = [s substringWithRange:[m rangeAtIndex:1]];
      NSArray<NSString*>* args = [[s substringWithRange:[m rangeAtIndex:2]] componentsSeparatedByString:@","];
      float a0 = unitFloat(args.count > 0 ? args[0] : nil);
      float a1 = unitFloat(args.count > 1 ? args[1] : nil);
      if ([fn isEqualToString:@"translate"]) { if (!std::isnan(a0)) tx = a0; if (!std::isnan(a1)) ty = a1; }
      else if ([fn isEqualToString:@"translateX"]) { if (!std::isnan(a0)) tx = a0; }
      else if ([fn isEqualToString:@"translateY"]) { if (!std::isnan(a0)) ty = a0; }
      else if ([fn isEqualToString:@"scale"]) { if (!std::isnan(a0)) { sx = a0; sy = std::isnan(a1) ? a0 : a1; } }
      else if ([fn isEqualToString:@"scaleX"]) { if (!std::isnan(a0)) sx = a0; }
      else if ([fn isEqualToString:@"scaleY"]) { if (!std::isnan(a0)) sy = a0; }
      else if ([fn isEqualToString:@"rotate"] || [fn isEqualToString:@"rotateZ"]) { if (!std::isnan(a0)) rot = a0; }
    }
    CGAffineTransform t = CGAffineTransformMakeTranslation(tx, ty);  // no density multiply (points)
    t = CGAffineTransformRotate(t, rot * (CGFloat)M_PI / 180.0);
    t = CGAffineTransformScale(t, sx, sy);
    v.transform = t;
  }

  static float unitFloat(NSString* t) {
    if (![t isKindOfClass:[NSString class]]) return NAN;
    t = [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([t hasSuffix:@"px"]) t = [t substringToIndex:t.length - 2];
    else if ([t hasSuffix:@"deg"]) t = [t substringToIndex:t.length - 3];
    return asFloat(t);
  }

  // Preserve font size when changing weight, and weight when changing size (mirror RN).
  static void setFontSize(UILabel* l, float size) {
    UIFontDescriptorSymbolicTraits traits = l.font.fontDescriptor.symbolicTraits;
    BOOL bold = (traits & UIFontDescriptorTraitBold) != 0;
    l.font = bold ? [UIFont boldSystemFontOfSize:size] : [UIFont systemFontOfSize:size];
  }
  static void setFontWeight(UILabel* l, NSString* s) {
    float w = asFloat(s);
    BOOL bold = [s isEqualToString:@"bold"] || (!std::isnan(w) && w >= 600);
    CGFloat size = l.font.pointSize > 0 ? l.font.pointSize : 14;
    l.font = bold ? [UIFont boldSystemFontOfSize:size] : [UIFont systemFontOfSize:size];
  }

  // ---- animations -----------------------------------------------------------

  void applyAnimations(canopy::Handle h, CView& cv, NSDictionary* props) {
    id rawSpec = props[@"animations"];
    NSArray* arr = nil;
    if ([rawSpec isKindOfClass:[NSString class]]) {
      NSData* d = [(NSString*)rawSpec dataUsingEncoding:NSUTF8StringEncoding];
      id parsed = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
      if ([parsed isKindOfClass:[NSArray class]]) arr = parsed;
    } else if ([rawSpec isKindOfClass:[NSArray class]]) {
      arr = rawSpec;
    }
    if (arr == nil || arr.count == 0) {
      [animDriver_ cancelAll:h];
      cv.view.alpha = cv.baseOpacity;
      applyTransform(cv.view, cv.baseTransform);
      return;
    }
    std::vector<bool> present(PROP_COUNT, false);
    for (id obj in arr) {
      if (![obj isKindOfClass:[NSDictionary class]]) continue;
      NSDictionary* spec = obj;
      int ord = animPropOrdinal(spec[@"prop"]);
      if (ord < 0) continue;
      present[ord] = true;
      float to = [spec[@"to"] isKindOfClass:[NSNumber class]] ? [spec[@"to"] floatValue] : 0;
      float from = (spec[@"from"] != nil && ![spec[@"from"] isKindOfClass:[NSNull class]]) ? [spec[@"from"] floatValue] : NAN;
      double duration = spec[@"duration"] ? [spec[@"duration"] doubleValue] : 300;
      double delay = spec[@"delay"] ? [spec[@"delay"] doubleValue] : 0;
      NSDictionary* ez = [spec[@"easing"] isKindOfClass:[NSDictionary class]] ? spec[@"easing"] : nil;
      NSString* kind = ez[@"kind"] ?: @"easeInOut";
      bool isSpring = [kind isEqualToString:@"spring"];
      float stiffness = ez[@"stiffness"] ? [ez[@"stiffness"] floatValue] : 180;
      float damping = ez[@"damping"] ? [ez[@"damping"] floatValue] : 12;
      float mass = ez[@"mass"] ? [ez[@"mass"] floatValue] : 1;
      int easing = animEasingOrdinal(kind);
      [animDriver_ start:h view:cv.view prop:ord from:from to:to duration:duration delay:delay
                  easing:easing spring:isSpring stiffness:stiffness damping:damping mass:mass];
    }
    [animDriver_ cancelMissing:h present:present];
  }

  // ---- layout helpers -------------------------------------------------------

  void requestRelayout() {
    if (root_ < 0) return;
    auto it = views_.find(root_);
    if (it != views_.end()) [it->second.view setNeedsLayout];
  }

  static YGJustify justify(NSString* s) {
    if ([s isEqualToString:@"center"]) return YGJustifyCenter;
    if ([s isEqualToString:@"flex-end"]) return YGJustifyFlexEnd;
    if ([s isEqualToString:@"space-between"]) return YGJustifySpaceBetween;
    if ([s isEqualToString:@"space-around"]) return YGJustifySpaceAround;
    if ([s isEqualToString:@"space-evenly"]) return YGJustifySpaceEvenly;
    return YGJustifyFlexStart;
  }
  static YGAlign align(NSString* s) {
    if ([s isEqualToString:@"center"]) return YGAlignCenter;
    if ([s isEqualToString:@"flex-end"]) return YGAlignFlexEnd;
    if ([s isEqualToString:@"stretch"]) return YGAlignStretch;
    return YGAlignFlexStart;
  }

  // RN resizeMode → contentMode (cover/contain/stretch/center; default cover).
  static UIViewContentMode scaleMode(NSString* mode) {
    if ([mode isEqualToString:@"contain"]) return UIViewContentModeScaleAspectFit;
    if ([mode isEqualToString:@"stretch"]) return UIViewContentModeScaleToFill;
    if ([mode isEqualToString:@"center"]) return UIViewContentModeCenter;
    return UIViewContentModeScaleAspectFill;  // cover / repeat / default
  }

  // ---- members --------------------------------------------------------------
  UIView* surface_;
  CanopyEmitFn emit_;
  CanopyHostBridge* bridge_;
  CanopyAnimDriver* animDriver_;
  std::unordered_map<canopy::Handle, CView> views_;
  std::unordered_map<UIView*, canopy::Handle> viewToHandle_;      // view → handle (for layout/measure)
  std::unordered_map<UIView*, YGNodeRef> contentNodes_;   // content-root container → its Yoga node
  std::vector<std::function<void()>> frameCallbacks_;
  CADisplayLink* frameLink_ = nil;
  canopy::Handle next_ = 1;
  canopy::Handle root_ = -1;
};

CanopyHostIOS* CanopyHostIOS::self_for_thunk_ = nullptr;

// ===========================================================================
// CanopyHostBridge — the Obj-C shim implementing CanopyLayoutHost + the frame tick, forwarding
// to the C++ host. (A weak pointer back into the host; the host outlives the bridge.)
// ===========================================================================
@implementation CanopyHostBridge {
@public
  CanopyHostIOS* _host;  // set right after construction (raw; host owns the bridge)
}

- (YGNodeRef)yogaNodeForView:(UIView*)view { return _host ? _host->yogaNodeForView(view) : nullptr; }
- (void)requestRelayout { if (_host) _host->requestRelayoutPublic(); }
- (void)requestContentRelayout:(UIView*)contentView { [contentView setNeedsLayout]; }
- (void)onFrameTick:(CADisplayLink*)link { if (_host) _host->drainFrameCallbacks(); }

@end

// ===========================================================================
// Factory the boot controller calls (contract §5.1 / §6.2).
//
// The host strongly owns the bridge (an ivar of the C++ object, retained by ARC). The bridge
// holds a RAW back-pointer to the host (set here, after the shared_ptr exists) — no retain
// cycle: when the last shared_ptr to the host drops, the host dtor releases the bridge.
// ===========================================================================
std::shared_ptr<canopy::CanopyHost> canopy::CanopyHostMake(UIView* surface, canopy::CanopyEmitFn emit) {
  auto host = std::make_shared<CanopyHostIOS>(surface, std::move(emit));
  CanopyHostBridge* bridge = host->bridge();
  bridge->_host = host.get();
  return host;
}
