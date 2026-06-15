# 02 — Layout & Styling to RN/Yoga Parity

**Area:** layout-styling · **Targets:** Android (real) + iOS (template, blocked on project bring-up)
**Goal:** bring the native style surface from its current ~30-key flexbox-only subset to React-Native/Yoga parity: `transform`, `box-shadow`/`elevation`, full borders, `overflow:hidden` clipping, gradients, `aspectRatio`, `zIndex`, image `resizeMode`, the full text-style set, `pointerEvents`, and the complete margin/padding/inset family — all flowing through the existing `Native.Css` bridge with no new styling vocabulary.

This plan is the build reference. It cites real code (`file:line`) for the current state, gives the exact target value formats each property produces, names every file to create/edit with signatures, and specifies the `resetStyleKey` reuse machinery for each new key. Where a key needs a `Native.Css` special-case (because the host can't parse the raw CSS value), it is called out.

---

## 1. Current State (file:line evidence)

### 1.1 The data path (unchanged, reused)
- `Css.Property "css-key" "css-value"` declarations →
- `Native.Css.translate` at `native/package/src/Native/Css.can:79` → `VirtualDom.style (camel key) (nativeValue value)` →
- organized facts bucket `a__1_STYLE` →
- `native.js` `_Native_factsToProps:160` flattens `a__1_STYLE` into `props.style` (key→value pass-through, **no per-key knowledge**) →
- `__fabric_createView/updateProps` → host `CanopyHost.applyStyle`.

The walker is **style-agnostic**: it copies every style key verbatim (`native.js:164-168`). So *every* gap is either in (a) `Native.Css` value mapping (`Css.can`) or (b) the host's `applyStyle` switch. Adding a key never touches `native.js` or the compiler.

Diff/removal machinery already exists and must be honored by every new key:
- removed style key → `_Native_diffSub` emits `key: null` (`native.js:500-510`);
- host `applyStyle` treats `style.isNull(key)` as "reset" → `resetStyleKey` (`CanopyHost.java:232`, `:324`).

### 1.2 Android `applyStyle` — exactly what is handled today
`CanopyHost.java:226-306`. The switch handles **only** these keys:

| Category | Keys handled | Line |
|---|---|---|
| Size | `width`, `height`, `minWidth`, `minHeight`, `maxWidth`, `maxHeight` | 236-241 |
| Flex | `flex`, `flexGrow`, `flexShrink`, `flexBasis`, `flexWrap`, `gap` | 242-247 |
| Padding | `padding[Top/Bottom/Left/Right/Horizontal/Vertical]` | 248-254 |
| Margin | `margin[Top/Bottom/Left/Right/Horizontal/Vertical]` | 255-261 |
| Inset | `top`, `bottom`, `left`, `right`, `position` | 262-268 |
| Layout | `flexDirection`, `justifyContent`, `alignItems`, `alignSelf` | 269-277 |
| Visual | `backgroundColor`, `borderRadius`, `opacity` | 278-280 |
| Text | `color`, `fontSize`, `fontWeight`, `textAlign` | 281-302 |

**`default: break` at `:303` silently drops everything else.** Confirmed-dropped keys an app can already write via `canopy/css`: `transform`, `box-shadow`, `border`/`borderWidth`/`borderColor`/`borderStyle`, `borderTop*`-corner radii, `overflow`, `background-image` (gradient/url), `aspectRatio`, `zIndex`, `object-fit`/resizeMode, `lineHeight`, `letterSpacing`, `textDecoration`, `textTransform`, `pointerEvents`.

The visual model is a single `GradientDrawable` rebuilt in `applyBackground` (`:391-402`) from exactly two fields on `CView`: `bgColor` (Integer) and `borderRadius` (float). There is **no** border, shadow, gradient, or clip state on `CView` (`:53-61`).

### 1.3 Color parsing — a real bridge bug waiting
Host uses `Color.parseColor(s)` (`CanopyHost.java:510-512`). `android.graphics.Color.parseColor` accepts only `#RGB/#ARGB/#RRGGBB/#AARRGGBB` and ~140 named colors. It **throws on `rgb()`, `rgba()`, `hsl()`, `hsla()`** — exactly what `Css.rgb/rgba/hsl/hsla` emit (`Value.can:1272-1292`). `parseColor` swallows the exception → `Color.TRANSPARENT` → silent invisible UI. The 8-digit-hex reorder is already done in the bridge (`Native.Css.mapToken:142`), but `rgb()/hsl()` are passed through untouched and die at the host.

### 1.4 `Native.Css` value mapping — what it does and its blind spots
`Native/Css.can`:
- `flex` shorthand expansion (`:90`), kebab→camel (`:107`), `px` strip + 8-hex reorder per token (`:135-150`).
- **Blind spots:** multi-token values that aren't lengths (e.g. `transform: "translate(10px, 4px) scale(1.2)"` — `mapToken` strips `px` per-word but leaves the `translate(...)` function string the host can't parse); `box-shadow` comma lists; `rgb()/hsl()` colors (passed through, die at host); `border` shorthand (`"1px solid #fff"`); gradient strings (`"linear-gradient(...)"`). The bridge has **no per-property structural transform** — it's a flat token mapper.

### 1.5 iOS host — template, mostly inert
`native/host/ios/CanopyHost/CanopyHostFabric.mm`. `applyStyle:143-162` handles only `width,height,flex,padding,margin,flexDirection,backgroundColor,color,fontSize,borderRadius`. `parseColor:43-53` is `#rrggbb`-only (no alpha, no rgb/named). No transform, border, shadow, clip, gradient. No Xcode project (`README` note `:15-17`: "cannot be built on this Linux box"). iOS is **blocked on project bring-up** (separate plan); this plan specifies the code so it's ready when the project lands.

### 1.6 What works in `canopy/css` today on native
Because the walker is pass-through, **any** `Css.*` whose serialized key/value the host happens to understand already works: all flexbox, sizing, spacing, inset, `backgroundColor` (hex only), `borderRadius` (uniform), `opacity`, `color`/`fontSize`/`fontWeight`/`textAlign`. Everything in §1.2's "dropped" list is authored-but-ignored.

---

## 2. Target Design (RN parity, per property)

Conventions used below:
- **dp**: host multiplies by `density` (`CanopyHost.dp:470`). All lengths stay density-independent (RN convention).
- **bridge note**: whether `Native.Css` needs a new special-case beyond the flat mapper.
- **reset**: the `resetStyleKey` default that a recycled view must fall back to.

### 2.1 Color (foundation — do FIRST, everything depends on it)
**Target:** one host color parser that accepts `#hex` (3/4/6/8), `rgb()`, `rgba()`, `hsl()`, `hsla()`, named, `transparent`, `currentColor`(→ inherit text color or transparent for bg).
**Decision:** parse in the **host**, not the bridge — keep `Native.Css` a structural mapper, give every color-taking property (`backgroundColor`, `color`, `borderColor`, shadow color, gradient stops) one code path. Bridge keeps the 8-hex reorder (`mapToken:142`) but must also reorder `rgba()` alpha into the host's expected order if the host parser is `#AARRGGBB`-centric; cleaner is to make the **host parser canonical** and drop the bridge reorder (see §3.2 decision).

### 2.2 transform (translate / scale / rotate / skew / matrix + transformOrigin)
**Value reaching host** (from `Css.transform`, `Value.can:2211-2273`): a space-joined function list, e.g. `"translate(10px, 4px) scale(1.2, 1.2) rotate(15deg)"`. After `nativeValue` per-token px-strip it becomes `"translate(10, 4) scale(1.2, 1.2) rotate(15deg)"` — **px stripped inside the parens, function names intact**. `transformOrigin` → `"transform-origin"` → camel `transformOrigin`, value like `"50% 50%"` / `"left top"`.
**Android target:** parse the function list in the host and apply to the `View` via the cheap setters (no full Matrix needed for the common case):
- `translate(x,y)` → `view.setTranslationX(dp(x)); setTranslationY(dp(y))`
- `scale(x,y)` / `scale(s)` → `setScaleX/setScaleY`
- `rotate(adeg)` → `setRotation(deg)`; `rotateX/rotateY` → `setRotationX/Y`
- `skewX/skewY` → no direct View setter → fall to a `Matrix` + `setAnimationMatrix` path (rare; acceptable to support via Matrix only when a skew token is present).
- `transformOrigin` → `setPivotX/setPivotY` (resolve `%` against the view's measured w/h post-layout; default pivot is view center, which matches CSS `50% 50%`).
- `matrix(a,b,c,d,e,f)` → build `android.graphics.Matrix` (note CSS matrix is column-major a,b,c,d,e,f) and `view.setAnimationMatrix(m)` (API 29+) or wrap in a small custom-draw concat for older.
**iOS target:** compose `CGAffineTransform` (translate/scale/rotate concat; skew via `CGAffineTransformMake`) → `view.transform`. `transformOrigin` → `view.layer.anchorPoint` (normalized 0..1) **plus** a position fix-up (changing anchorPoint moves the frame; adjust `layer.position`).
**bridge note:** **add a special-case.** `transform` must NOT go through the naive per-token px-strip alone — that's *almost* right (it leaves `scale(1.2,` with a trailing comma token boundary issue: `String.words "scale(1.2, 1.2)"` = `["scale(1.2,", "1.2)"]`, neither ends in `px`, so it's fine; but `translate(10px,` → token `"translate(10px,"` does NOT `endsWith "px"` because of the trailing comma/paren, so px is NOT stripped). **This is a confirmed bug:** the current `mapToken` only strips `px` from bare tokens, never inside `f(...)`. Fix: a dedicated `transformValue` mapper in `Native.Css` that strips `px` *inside* function args. See §3.2.
**reset:** clear all View transform props: `setTranslationX(0); setTranslationY(0); setScaleX(1); setScaleY(1); setRotation(0); setRotationX(0); setRotationY(0); setAnimationMatrix(null); reset pivot to center`. iOS: `view.transform = CGAffineTransformIdentity`.

### 2.3 box-shadow / elevation
**Value reaching host** (`Css.boxShadow`, `Value.can:2329-2343`): comma-joined `"[inset ]ox oy blur spread color"`, e.g. `"0 2px 8px 0 rgba(0,0,0,0.3)"`. After px-strip: `"0 2 8 0 rgba(0,0,0,0.3)"` — but the `rgba()` has internal spaces, so `String.words` splits it. **box-shadow needs a structural bridge mapper** (§3.2) that keeps the color token intact and px-strips only the four length slots.
**Android target:** Android has no real CSS box-shadow. Two-tier:
1. **elevation path (default):** map blur→`view.setElevation(dp(blur))` + a matching background outline so the system shadow draws. Requires a non-null background and `setClipToOutline`/`OutlineProvider`. This gives a real, GPU-cheap shadow but only neutral (can't honor arbitrary shadow color/offset precisely).
2. **precise path (when offset/color set):** a custom `ShadowDrawable` (layer-drawable) that draws a blurred rect via `Paint.setShadowLayer(blur, dx, dy, color)` on a `LAYER_TYPE_SOFTWARE` view. Slower; use only when the shadow has a non-default color/offset. Pick path by inspecting parsed shadow.
   - New `CView` field `shadowSpec` (parsed struct). `applyBackground` becomes `applyBackgroundAndBorderAndShadow` (rename to `applyDecoration`) that composes bg + border + shadow into the view's background/outline/elevation in one place.
**iOS target:** native CSS-shadow parity via `CALayer`: `layer.shadowColor/shadowOffset/shadowRadius/shadowOpacity` + `layer.shadowPath` (perf). Multiple shadows → only the last wins on a single layer (CSS allows N); document the limitation or stack sublayers.
**bridge note:** add `shadowValue` special-case (px-strip the 4 lengths, leave color).
**reset:** `view.setElevation(0); background outline cleared; shadowSpec=null`. iOS: zero the layer shadow props.

### 2.4 borders (width / color / style + per-side + per-corner radius)
**Values reaching host:**
- `borderWidth` (`Css.can:627`) → number; `borderColor` → color string; `borderStyle` → `solid|dashed|dotted|none`.
- `border` shorthand (`:579`) → `"1px solid #fff"` → after px-strip `"1 solid #fff"` (color token intact only if hex; `rgb()` breaks on spaces → **needs structural mapper** or expand shorthand in bridge).
- `borderTop/Right/Bottom/Left` (`:585-604`) → same shorthand shape per side.
- `borderRadius` uniform (already handled) + `borderRadius4` (`:615`) → `"tl tr br bl"` (4 lengths).
**Decision:** **expand border shorthands in the `Native.Css` bridge** into longhand keys the host applies individually — `border: "1px solid #fff"` → `borderWidth`, `borderStyle`, `borderColor`; `border-top: ...` → `borderTopWidth/Style/Color`. This keeps the host switch on simple longhand keys and dodges the `rgb()`-with-spaces token problem (the color becomes its own value). This mirrors how the bridge already expands `flex` (`Css.can:90`).
**Android target:** there is no per-side border on a plain `View`. Use a `GradientDrawable` for the **uniform** case (`setStroke(widthPx, color)` + `setColor(bg)` + `setCornerRadii(...)` for 4-corner). For **per-side** widths/colors (RN supports them), fall to a custom `BorderDrawable` (draws 4 edges + clips corners via a `Path`). Per-corner radius: `GradientDrawable.setCornerRadii(float[8])` (tl,tl,tr,tr,br,br,bl,bl). `borderStyle:dashed/dotted` → `GradientDrawable.setStroke(width, color, dashWidth, dashGap)`.
**iOS target:** uniform border = `layer.borderWidth/borderColor` + `layer.cornerRadius`. Per-side / per-corner / dashed → `CAShapeLayer` mask + sublayers (RN's own approach). Per-corner radius via `UIBezierPath byRoundingCorners`.
**bridge note:** add border shorthand expansion (`borderShorthand`, `borderSideShorthand`) + `borderRadius4` → keep as one key but host parses the 4-value string.
**reset:** clear stroke + per-side fields + corner radii → rebuild decoration with bg only. iOS: zero `layer.border*`, restore `cornerRadius` to the `borderRadius` value (or 0).

### 2.5 overflow: hidden (clipping)
**Value:** `Css.overflow` (`Css.can:394`) → `visible|hidden|scroll|auto`.
**Android target:** `hidden` → on a `ViewGroup`, `setClipChildren(true)` + `setClipToOutline(true)` with an `OutlineProvider` matching the (possibly rounded) bounds. Crucial interaction: **borderRadius + overflow:hidden** must clip children to the rounded rect — set the outline radius from `cv.borderRadius`. `visible` → `setClipChildren(false)`. This is also what makes rounded-corner image containers work.
**iOS target:** `view.clipsToBounds = (overflow == hidden)`; with `cornerRadius` set it clips to the rounded rect automatically.
**bridge note:** none (keyword pass-through).
**reset:** `setClipChildren(true)`(Android ViewGroup default is true) / `setClipToOutline(false)`; pick the ViewGroup default. iOS `clipsToBounds=false`.

### 2.6 gradients (linear / radial as background)
**Value:** `Css.backgroundGradient` (`Css.can:967-970`) → `background-image` key with `"linear-gradient(180deg, #0E0E10, #1A1A1F 50%)"` / `"radial-gradient(...)"` (`Value.can:2416-2435`). Internal commas + spaces → **structural bridge mapper required** (or send the raw string and parse host-side).
**Decision:** parse the gradient string **in the host** (it's complex; keep the bridge dumb). Bridge passes `backgroundImage` value through verbatim (no px in gradients except stop positions; leave them). Host detects `backgroundImage` starting with `linear-gradient(` / `radial-gradient(`.
**Android target:** `linear-gradient` → `GradientDrawable` with `setColors(int[])` + `setOrientation` (map angle→ nearest `Orientation` enum; for arbitrary angles use a custom `PaintDrawable`/`ShapeDrawable` with a `LinearGradient` shader factory). `radial-gradient` → `GradientDrawable.setGradientType(RADIAL)` + `setGradientRadius`. Stop positions → `GradientDrawable` only supports 3-stop offsets via `setColors` overload (API 29+) or a `LinearGradient` shader with explicit `positions[]`. Compose into the same `applyDecoration` as bg/border/shadow.
**iOS target:** `CAGradientLayer` (linear: `startPoint/endPoint` from angle; radial: `type = .radial`). Insert as sublayer index 0, resize in layout.
**bridge note:** **add** `background-image` → `backgroundImage` (already camel) but ensure gradient string isn't mangled by px-strip (stop positions like `50%` are fine; lengths like `10px` inside would be stripped — acceptable, or special-case to skip mapping when value starts with `*-gradient(`).
**reset:** clear gradient → rebuild decoration with solid bg.

### 2.7 aspectRatio
**Value:** `Css.aspectRatio` (`Css.can:1486`) → number (e.g. `1.5`) or `"16 / 9"`. Yoga supports it natively.
**Android/iOS target:** just wire it — `YogaNode.setAspectRatio(float)` / `YGNodeStyleSetAspectRatio`. Parse `"a / b"` → `a/b`.
**bridge note:** none for the numeric form; for `"16 / 9"` add a tiny mapper (or document numeric-only). Likely send as plain float string.
**reset:** `setAspectRatio(YogaConstants.UNDEFINED)`.

### 2.8 zIndex
**Value:** `Css.zIndex` (`Css.can:372`) → integer.
**Android target:** two effects needed — paint order *and* shadow stacking. `view.setTranslationZ(dp(z))` raises it for elevation/shadow stacking; for **sibling paint order**, Android draws in child-add order, so a higher `zIndex` child must be reordered. Implement via the parent `ViewGroup` overriding `getChildDrawingOrder` (set `setChildrenDrawingOrderEnabled(true)`) and sorting by each child's `zIndex` — this avoids actually moving views in the Yoga tree (which would break layout indices). Store `zIndex` on `CView`; `YogaViewGroup` reads it.
**iOS target:** `view.layer.zPosition = z` (UIKit honors it for compositing) — simpler than Android.
**bridge note:** none.
**reset:** `zIndex=0`, invalidate drawing order. iOS `zPosition=0`.

### 2.9 image resizeMode / object-fit
**Value:** `Css.objectFit` (`Css.can:1470`) → `cover|contain|fill|none|scale-down`. (RN uses `resizeMode`; `canopy/css` uses `object-fit` — bridge maps the key.) This pairs with the image-loading plan (URL source), but the scale-type mapping is a styling concern.
**Android target:** `ImageView.setScaleType`: `cover`→`CENTER_CROP`, `contain`→`FIT_CENTER`, `fill`→`FIT_XY`, `none`→`CENTER`, `scale-down`→`FIT_CENTER` (with adjustViewBounds). Applies to both `RCTImageView` and `CanopyBitmap`.
**iOS target:** `UIImageView.contentMode`: `cover`→`.scaleAspectFill` (+`clipsToBounds`), `contain`→`.scaleAspectFit`, `fill`→`.scaleToFill`, `none`→`.center`.
**bridge note:** map key `object-fit`→`objectFit` (camel already does it) and optionally alias to `resizeMode` so RN-shaped APIs feel native. Keyword pass-through.
**reset:** `CENTER_CROP` (RN default `cover`)/ matching iOS default.

### 2.10 text styling (lineHeight / letterSpacing / textDecoration / textTransform)
**Values:** `Css.lineHeight` (`:730`, number or px), `letterSpacing` (`:736`, px → em on Android), `textDecoration` (`:756`, `underline|line-through|none`), `textTransform` (`:762`, `uppercase|lowercase|capitalize|none`).
**Android target (TextView):**
- `lineHeight` → `TextView.setLineHeight(px)` (API 28+) or `setLineSpacing(extra, mult)`; dirty Yoga leaf (changes intrinsic height).
- `letterSpacing` → `setLetterSpacing(em)` — **Android wants em, not px**: convert `px / fontSizePx`. Needs fontSize known → store fontSize on CView. Dirty leaf.
- `textDecoration` → `setPaintFlags(... UNDERLINE_TEXT_FLAG | STRIKE_THRU_TEXT_FLAG)`.
- `textTransform` → transform the string before `setText` (store raw text + transform; reapply when either changes). `capitalize` = first letter of each word.
**iOS target:** `NSAttributedString` attributes (`.kern` for letterSpacing in pt, `.underlineStyle`, paragraph style `lineHeightMultiple`/`maximumLineHeight`); `textTransform` → uppercase/lowercase/capitalized string. UILabel can't do per-run easily; build attributed string in applyStyle.
**bridge note:** `letterSpacing`/`lineHeight` lengths px-stripped already; the px→em conversion is host-side. Keyword keys pass through.
**reset:** restore TextView defaults (clear underline/strike flags, `setLetterSpacing(0)`, default line spacing, raw untransformed text). Mirror the existing text-reset block (`CanopyHost.java:362-373`).

### 2.11 pointerEvents
**Value:** `Css.pointerEvents` (`Css.can:1075`) → `auto|none|box-none|box-only`.
**Android target:** `none` → the view (and children) ignore touches: override `onInterceptTouchEvent`/set a touch-blocking flag, or `setEnabled`-style gate. `box-none` → view itself not touchable but children are; `box-only` → view touchable, children not. Implement a `pointerEvents` field on CView read by a custom `onInterceptTouchEvent` in `YogaViewGroup` + an override in `dispatchTouchEvent`.
**iOS target:** `view.isUserInteractionEnabled` for `none`/`box-only`; `box-none` needs `hitTest` override returning nil for self but allowing subviews.
**bridge note:** none.
**reset:** `auto`.

### 2.12 full margin/padding/inset set — gaps
Already mostly covered (`CanopyHost.java:248-265`). Gaps vs RN/Yoga:
- **percentage** margins/paddings: `setDim` handles `%` for width/height (`:311`) but **padding/margin/inset ignore `%`** (they only take `f`). Yoga supports `setPaddingPercent/setMarginPercent/setPositionPercent`. Add `%` handling to those edges.
- **`auto` margins** (centering): Yoga `setMarginAuto(edge)`. Add `"auto"` handling for margins.
- **`inset`/`insetVertical`/`insetHorizontal`** shorthands (`Css.can:180`, `inset`/`inset2`/`inset4`) → expand in bridge to top/right/bottom/left, or handle the keys host-side. RN supports `inset`. Add.
- **`rowGap`/`columnGap`** (separate from `gap`) → `YogaGutter.ROW`/`COLUMN`. Add.
- **`start`/`end`** (logical edges) → `YogaEdge.START/END`. Add for RTL parity (lower priority).
**bridge note:** `inset` shorthand expansion (like flex/border).
**reset:** percent/auto edges reset to 0/`UNDEFINED` per existing pattern (`:341-350`).

---

## 3. File-by-File Implementation

### 3.1 Android host — `CanopyHost.java` (the bulk)
This is the primary file. Restructure the decoration state and the switch.

**(a) `CView` new fields** (`CanopyHost.java:53-61`):
```java
// borders
Float borderWidth = null; int borderColor = Color.BLACK; String borderStyle = "solid";
float[] borderWidths;      // per-side [t,r,b,l] when set (else null → uniform)
int[] borderColors;        // per-side
float[] cornerRadii;       // [tl,tr,br,bl] when borderRadius4 used (else null → uniform)
// shadow
ShadowSpec shadow = null;  // parsed {dx,dy,blur,spread,color,inset}
// gradient
GradientSpec gradient = null;
// layout/paint
boolean overflowHidden = false;
int zIndex = 0;
int pointerEvents = POINTER_AUTO;
// text
float fontSizeSp = 14f;    // tracked so letterSpacing px→em works
String rawText = "";        // pre-transform, so textTransform is reversible
String textTransform = "none";
```

**(b) New helper structs** (private static classes or a `views/Decoration.java`):
- `ShadowSpec { float dx, dy, blur, spread; int color; boolean inset; }`
- `GradientSpec { boolean radial; float angleDeg; int[] colors; float[] stops; }`
- `ColorParser` (new file `views/CanopyColor.java`) — see §3.3.

**(c) Replace `applyBackground` with `applyDecoration(CView)`** (`:391-402`): one method that composes bg color + gradient + border + corner radii + shadow into the view's background `Drawable` (a `LayerDrawable` when needed) and sets `elevation`/outline/clip. This is the single rebuild point all visual setters call (mirrors the current bgColor+borderRadius rebuild).

**(d) Extend the `applyStyle` switch** (`:235-304`) — new `case`s (each calls the appropriate setter + `applyDecoration`/`dirty` as needed):
```
case "transform":       parseAndApplyTransform(cv, s); break;        // §2.2
case "transformOrigin": cv.pivot = parsePivot(s); applyPivot(cv); break;
case "boxShadow":       cv.shadow = parseShadow(s); applyDecoration(cv); break;
case "borderWidth":     cv.borderWidth = dp(f); applyDecoration(cv); break;
case "borderColor":     cv.borderColor = CanopyColor.parse(s); applyDecoration(cv); break;
case "borderStyle":     cv.borderStyle = s; applyDecoration(cv); break;
case "borderTopWidth": case "borderRightWidth": ... per-side widths; break;
case "borderTopColor": ... per-side colors; break;
case "borderTopLeftRadius": ... per-corner; break;       // if sent as longhand
case "overflow":        cv.overflowHidden = "hidden".equals(s); applyClip(cv); break;
case "backgroundImage": cv.gradient = parseGradient(s); applyDecoration(cv); break;
case "aspectRatio":     if (f != null) y.setAspectRatio(f); else y.setAspectRatio(parseRatio(s)); break;
case "zIndex":          cv.zIndex = (int)(float)f; reorderInParent(cv); break;
case "objectFit": case "resizeMode": applyScaleType(cv, s); break;
case "lineHeight":      applyLineHeight(cv, f); dirtyLeaf(cv); break;
case "letterSpacing":   applyLetterSpacing(cv, f); dirtyLeaf(cv); break;
case "textDecoration":  applyTextDecoration(cv, s); break;
case "textTransform":   cv.textTransform = s; reapplyText(cv); dirtyLeaf(cv); break;
case "pointerEvents":   cv.pointerEvents = parsePointer(s); break;
// percent/auto edges:
case "padding": ... extend setDim-style to call setPaddingPercent on "%"; ...
case "rowGap":  if (f!=null) y.setGap(YogaGutter.ROW, dp(f)); break;
case "columnGap": if (f!=null) y.setGap(YogaGutter.COLUMN, dp(f)); break;
```
Refactor padding/margin/inset to a shared `setEdge(setter, percentSetter, autoSetter, s, f)` so `%`/`auto` are handled uniformly.

**(e) Extend `resetStyleKey`** (`:324-378`) — add a reset for every new key (the reuse machinery):
```
case "transform": resetTransform(cv); break;
case "transformOrigin": resetPivot(cv); break;
case "boxShadow": cv.shadow=null; cv.view.setElevation(0); applyDecoration(cv); break;
case "borderWidth": cv.borderWidth=null; applyDecoration(cv); break;
case "borderColor": cv.borderColor=Color.BLACK; applyDecoration(cv); break;
case "borderStyle": cv.borderStyle="solid"; applyDecoration(cv); break;
case "borderTopWidth": ... null the per-side slot; applyDecoration(cv); break;
case "overflow": cv.overflowHidden=false; applyClip(cv); break;
case "backgroundImage": cv.gradient=null; applyDecoration(cv); break;
case "aspectRatio": y.setAspectRatio(YogaConstants.UNDEFINED); break;
case "zIndex": cv.zIndex=0; reorderInParent(cv); break;
case "objectFit": case "resizeMode": applyScaleType(cv, "cover"); break;
case "lineHeight": resetLineHeight(cv); dirtyLeaf(cv); break;
case "letterSpacing": setLetterSpacing(cv,0); dirtyLeaf(cv); break;
case "textDecoration": clearTextDecoration(cv); break;
case "textTransform": cv.textTransform="none"; reapplyText(cv); dirtyLeaf(cv); break;
case "pointerEvents": cv.pointerEvents=POINTER_AUTO; break;
case "rowGap": y.setGap(YogaGutter.ROW,0); break;
case "columnGap": y.setGap(YogaGutter.COLUMN,0); break;
```
**This is load-bearing:** without resets, a recycled view keeps a prior screen's shadow/border/transform (the exact bug the `null`-reset machinery exists to prevent — see `CanopyHost.java:322-323` comment and `native.js:504-508`).

**(f) `YogaViewGroup` changes** (`:416-459`) for zIndex + overflow + pointerEvents:
- constructor: `setChildrenDrawingOrderEnabled(true)`.
- override `getChildDrawingOrder(count, i)` to return indices sorted by child `CView.zIndex` (stable, default order when all 0).
- override `onInterceptTouchEvent`/`dispatchTouchEvent` to honor `pointerEvents`.
- `applyClip` sets `setClipChildren` + `setOutlineProvider` + `setClipToOutline`.

**(g) `dirtyLeaf(cv)` helper** — calls `cv.yoga.dirty()` when `cv.isLeaf`, used by every text-metric-changing setter (matches existing `:286,:293`).

### 3.2 The `Native.Css` bridge — `Native/Css.can`
Add **structural special-cases** in `translate` (`Css.can:79`) before the generic path. The mapper stays a pure function; new branches:

```can
translate : String -> String -> List (Attribute msg)
translate key value =
    if key == "flex" then flexShorthand value
    else if key == "transform" then [ VirtualDom.style "transform" (transformValue value) ]
    else if key == "box-shadow" then [ VirtualDom.style "boxShadow" (shadowValue value) ]
    else if key == "border" then borderShorthand "" value
    else if key == "border-top" then borderShorthand "Top" value
    else if key == "border-right" then borderShorthand "Right" value
    else if key == "border-bottom" then borderShorthand "Bottom" value
    else if key == "border-left" then borderShorthand "Left" value
    else if key == "inset" then insetShorthand value
    else if String.startsWith "linear-gradient" value || String.startsWith "radial-gradient" value
        then [ VirtualDom.style (camel key) value ]   -- pass gradient through unmangled
    else [ VirtualDom.style (camel key) (nativeValue value) ]
```

New functions (all pure, unit-testable via `testStyleValue` at `native.js:918`):
- `transformValue : String -> String` — px-strip **inside** `f(...)` args. Splits on function boundaries, strips trailing `px` from each numeric arg. Fixes the §2.2 confirmed bug (`translate(10px,` token never stripped today).
- `shadowValue : String -> String` — split top-level commas (multi-shadow), within each px-strip the first 4 length slots, leave the color token (which may contain `rgb(...)` with spaces — keep intact).
- `borderShorthand : String -> String -> List (Attribute msg)` — `"1px solid #fff"` → `[ style ("border"++side++"Width") "1", style ("border"++side++"Style") "solid", style ("border"++side++"Color") "#fff" ]`. Color is the **last** whitespace-joined remainder, so `rgb(255, 0, 0)`-with-spaces stays whole if it's the tail (use a parser that takes width=first token, style=second, color=rest).
- `insetShorthand` — 1/2/4 values → top/right/bottom/left longhands.

**Color decision:** keep the 8-hex reorder in `mapToken` (`:142`) **only if** the host parser expects `#AARRGGBB`. Recommendation: make the **host** `CanopyColor` the canonical parser accepting CSS-order `#RRGGBBAA` + `rgb/rgba/hsl/hsla` + named, and **remove** the bridge reorder so the value stays web-identical end-to-end. (Document this swap; update the `nativeValue` doc-comment at `:127-134`.)

### 3.3 New host file — `views/CanopyColor.java`
```java
public final class CanopyColor {
  /** Parse a CSS color string to an ARGB int. Accepts #RGB/#RGBA/#RRGGBB/#RRGGBBAA,
   *  rgb()/rgba(), hsl()/hsla(), 'transparent', and named colors. */
  public static int parse(String s) { ... }
}
```
Used everywhere the host currently calls `Color.parseColor` (`CanopyHost.java:282,397,511`). This single file closes the §1.3 `rgb()/hsl()` invisible-UI bug.

### 3.4 New host file — `views/CanopyDecoration.java` (optional split)
If `applyDecoration` grows large, factor the bg+border+gradient+shadow→`Drawable` composition here:
```java
static Drawable build(CView cv, float density) { ... returns LayerDrawable / GradientDrawable / BorderDrawable }
```
Plus a `BorderDrawable extends Drawable` for the per-side case (Android has no built-in).

### 3.5 Image scale type — `ImageModule.java` / `CanopyBitmap`
`applyScaleType(cv, mode)` in `CanopyHost` sets `((ImageView)cv.view).setScaleType(...)`. URL loading is a separate plan; this only wires the style. Confirm both `RCTImageView` and `CanopyBitmap` (`CanopyHost.java:181-182`) get it.

### 3.6 `Native.Attributes.can` (optional ergonomic helpers)
`Native/Attributes.can` is the hand-rolled, non-`canopy/css` styling path (`:1-12`). It currently stops at `textAlign`. **Not required** (apps should use `Native.Css`), but for parity add thin wrappers: `transform`, `boxShadow`, `borderWidth`, `borderColor`, `overflow`, `zIndex`, `aspectRatio`, `resizeMode`, `pointerEvents`, percent/auto spacing, `rowGap`/`columnGap`. Each is one `VirtualDom.style key val`. Update the exposing list (`:1-12`) and `@docs`. Lower priority than the `Native.Css` path.

### 3.7 iOS — `CanopyHostFabric.mm` (blocked on project, code ready)
Mirror every Android case in `applyStyle:143` (currently 10 keys → ~30):
- color: replace `parseColor:43` with a full parser (hex 3/4/6/8, rgb/rgba/hsl/hsla, named).
- transform → `CGAffineTransform`; transformOrigin → `anchorPoint` + position fix.
- shadow → `layer.shadow*` + `shadowPath`.
- borders → `layer.border*` (uniform) / `CAShapeLayer` (per-side/corner).
- overflow → `clipsToBounds`.
- gradient → `CAGradientLayer` sublayer (resize in `applyFrames:171`).
- aspectRatio → `YGNodeStyleSetAspectRatio`.
- zIndex → `layer.zPosition`.
- objectFit → `UIImageView.contentMode`.
- text → `NSAttributedString` (lineHeight/kern/underline/transform) on `UILabel`.
- pointerEvents → `isUserInteractionEnabled` / `hitTest` override.
**Blocker:** no Xcode project exists (`README:15-17`); these compile only once the iOS project plan stands up a target linking UIKit+Yoga. Until then, this file is a spec that must stay in lockstep with the Android switch (shared test vectors — §6).

---

## 4. Web-Package Reuse (reuse vs re-back)

| Concern | Reuse as-is | Re-back natively | Why |
|---|---|---|---|
| `canopy/css` typed property fns (`Css.transform/boxShadow/border*/overflow/zIndex/aspectRatio/objectFit/lineHeight/letterSpacing/pointerEvents`) | ✅ **reuse verbatim** | — | They just produce `Property key value` strings; the native walker is pass-through. No native fork. |
| `Css/Value.can` serializers (`transformToString`, `shadowToString`, `gradientToString`, `rgb/hsl`) | ✅ reuse | — | Already produce the strings the bridge/host parse. |
| Value→host mapping (px-strip, color order, shorthand expansion) | partial | ✅ **re-back in `Native.Css`** | Web emits CSS the DOM understands; Yoga/host needs longhand + numeric + canonical color. This is the `Native.Css` bridge's whole job (§3.2). |
| `Css.Animation`/`Transition`/`Filter`/`Media`/`Grid`/`Selector`/`Shape` | ❌ not via this seam | (separate: animation plan; Grid has no Yoga analog) | `toFacts` already drops `MediaQuery/PseudoClass/Nested` (`Native/Css.can:73-77`). Grid/filter/shape are web-only on native. |
| Color parsing | — | ✅ **re-back** (`CanopyColor.java` / iOS parser) | RN/Yoga hosts need rgb/hsl/named; `Color.parseColor` can't. |
| `box-shadow`/gradient rendering | — | ✅ re-back (Drawable / CALayer) | No web CSS engine on device. |

**Net:** the entire authoring surface (`canopy/css`) is reused unchanged. The re-backing is confined to (1) `Native.Css` structural mappers and (2) host renderers. This is the maximal-reuse posture the mission wants.

**Coverage table — which `Css.*` work on native after this plan:**
- **Work via flat mapper (today):** all flex/size/spacing/inset, `backgroundColor`(+rgb/hsl after color fix), `borderRadius`, `opacity`, `color`, `fontSize`, `fontWeight`, `textAlign`.
- **Work via new host case + flat mapper:** `overflow`, `aspectRatio`, `zIndex`, `objectFit`, `lineHeight`, `letterSpacing`, `textDecoration`, `textTransform`, `pointerEvents`, percent/auto spacing, `rowGap`/`columnGap`.
- **Work via new `Native.Css` special-case + host case:** `transform`, `transformOrigin`, `boxShadow`, `border`/`borderTop…`/`borderWidth/Color/Style`, `borderRadius4`, `backgroundGradient`/`backgroundImage`(gradient), `inset`.
- **Web-only (dropped, documented):** pseudo-classes, media/container queries, nesting (`Native/Css.can:73`), `Grid.*`, `Filter.*`, `Shape.*` (clip-path), `cursor`, `userSelect`, `background-attachment`, `transition`/`animation` keyframes (handled by the animation plan, not this seam).

---

## 5. Testing Strategy

### 5.1 Mock-fabric unit tests (host-independent, run on Linux)
The walker copies style keys verbatim, and `testStyleValue` (`native.js:913-922`) returns the value of one style prop on the rendered root. So **`Native.Css` mapping is fully unit-testable without a device.**
- New `.can` tests asserting `testStyleValue "transform" view == "translate(10, 4) scale(1.2, 1.2)"` (proves the px-inside-parens fix), `testStyleValue "boxShadow" == "0 2 8 0 rgba(0,0,0,0.3)"`, `testStyleValue "borderWidth" == "1"` + `"borderColor" == "#fff"` (proves shorthand expansion), gradient pass-through unmangled, `inset` expansion.
- Harness: extend `native/harness/run*.js` + `mock-fabric.js` (`:33`) — the mock already stores `props.style`; add a `styleOf(handle, key)` control helper mirroring `findByTestID:107`.
- Diff/reset tests: render with a key, re-render without it, assert `updateProps` carries `{key: null}` (the reset path) — guards the §3.1(e) reuse machinery.

### 5.2 Device E2E (Android, real)
- A `styling-gallery` screen exercising every new key; visually diff against a reference (screenshot). Drive via the test driver — **requires `testID` to actually map to a findable view** (cross-ref the DX/testID plan; today `testID` is a no-op, `Native.Attributes.testID:292` is sent but the host ignores it — a blocker for automated E2E here).
- Per-property assertions where observable: shadow → non-zero `view.getElevation()`; border → background is a `GradientDrawable` with the stroke; overflow → `view.getClipToOutline()`; zIndex → `getChildDrawingOrder` returns the sorted index; transform → `view.getTranslationX/ScaleX/Rotation`.
- Recycle test: navigate screen A (styled) → B (unstyled reused node) → assert the view dropped A's transform/shadow/border (the reset path on-device).

### 5.3 Shared cross-host vectors
Keep a JSON table of `{ cssKey, cssValue, expectedYogaKey, expectedHostValue }` consumed by both the JS unit tests and (when iOS lands) an iOS XCTest, so Android and iOS stay in lockstep.

---

## 6. Milestones (effort + ordering)

1. **M1 — Color foundation** (S): `CanopyColor.java` (rgb/rgba/hsl/named/hex), repoint `CanopyHost` color call-sites, decide+apply the bridge-reorder removal, iOS parser stub. *Unblocks every color-taking property; fixes the §1.3 invisible-UI bug.* **Do first.**
2. **M2 — Borders + per-corner radius + overflow clip** (M): `Native.Css` border/inset shorthand expansion, host longhand cases, `BorderDrawable`, `applyDecoration` refactor (rename `applyBackground`), `applyClip`. Resets. Unit tests.
3. **M3 — box-shadow / elevation** (M): `ShadowSpec`, `shadowValue` bridge mapper, elevation + precise paths, `applyDecoration` integration, resets.
4. **M4 — transform + transformOrigin** (M): `transformValue` bridge mapper (the px-in-parens fix), host parse→View setters, Matrix skew/matrix path, pivot. Resets.
5. **M5 — gradients** (M): host gradient parse → `GradientDrawable`/shader, bridge pass-through guard, `applyDecoration` layer composition, resets.
6. **M6 — layout finishers** (S): `aspectRatio`, `zIndex` (drawing-order override), percent/auto spacing, `rowGap`/`columnGap`, `inset`. Mostly Yoga wiring.
7. **M7 — text styling** (S): `lineHeight`, `letterSpacing` (px→em), `textDecoration`, `textTransform`; fontSize tracking on CView; leaf dirtying. Resets.
8. **M8 — image resizeMode + pointerEvents** (S): scale-type map; pointer-events touch gating.
9. **M9 — iOS parity port** (L, **blocked**): mirror M1–M8 in `CanopyHostFabric.mm`. Gated on the iOS-project bring-up plan. Shared test vectors (§5.3).
10. **M10 — `Native.Attributes` parity helpers** (S, optional): thin wrappers for the non-`canopy/css` path.

**Suggested order:** M1 → M2 → M3 → M4 → M5 → M6 → M7 → M8 → (M9 when iOS unblocks) → M10. M2–M8 are independent of each other after M1 and after the `applyDecoration` refactor lands (do that refactor at the start of M2).

---

## 7. Risks / Open Questions

- **Color order swap (M1):** removing the bridge's 8-hex reorder (`Native/Css.can:142`) changes a value every existing styled view sends. Must land the host canonical parser in the same change or every hex bg flips channels. *Mitigation:* one atomic M1 commit + the recycle/visual test.
- **box-shadow fidelity gap:** Android `elevation` can't honor arbitrary shadow color/offset; the precise `setShadowLayer` path forces software rendering (perf). Decide per-shadow which path. RN itself has this limitation — acceptable, but document it.
- **Arbitrary gradient angles on Android:** `GradientDrawable.Orientation` is an 8-way enum; true arbitrary angles need a `LinearGradient` shader in a custom drawable. Scope: support enum angles first, shader path if a real app needs odd angles.
- **zIndex via drawing-order vs Yoga indices:** reordering actual children would corrupt Yoga's child indices (`insertChild`/`removeChild` math at `CanopyHost.java:103-125`). The `getChildDrawingOrder` approach avoids this but only affects *paint*, not hit-testing order — overlapping touchable views at different zIndex may hit-test wrong. Note for the events plan.
- **`testID` no-op blocks device E2E:** §5.2 automated assertions need the testID/DX plan to land first. Until then, M-level verification is mock-fabric + manual visual.
- **letterSpacing px→em needs fontSize:** order-dependence — if `letterSpacing` arrives before `fontSize` in the style object, the em conversion uses the stale fontSize. *Mitigation:* recompute letterSpacing whenever fontSize changes (store both, reapply).
- **transformOrigin percent resolution:** pivot from `%` needs post-layout view dimensions; applying it in `applyStyle` (pre-layout) may use 0×0. *Mitigation:* defer pivot application to first `onLayout`, or store pending pivot and apply when size known.
- **iOS entirely blocked:** M9 cannot be verified on this Linux box and depends on the separate iOS-project plan. The code is written speculatively against UIKit+Yoga public APIs.
- **`overflow` default mismatch:** Android `ViewGroup.clipChildren` defaults to true; CSS default `overflow:visible` means we must *disable* clipping by default to match web/RN. Confirm the reset/default direction so nested absolutely-positioned children aren't clipped unexpectedly.
