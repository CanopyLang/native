# Plan 08 — Testing & Device Matrix

**Area:** `testing-device-matrix`
**Goal:** a Playwright‑class cross‑device (Android + iOS) test capability on top of the
existing strong mock‑Fabric unit base — so Lumen (and any Canopy‑native app) can be tested
from a single `testID` vocabulary, in CI, across a real device farm, with the same
selectors driving unit, smoke, and E2E layers.

**Status of evidence:** every file:line below was read in the live tree on 2026‑06‑13.
The mock‑Fabric harness runs green today (`run.js` 17/17, `run-echo.js` 22/22 — verified).
This is the build reference; an engineer implements directly from it.

---

## 0. TL;DR build order

| # | Milestone | Effort | Blocks |
|---|-----------|--------|--------|
| T0 | **testID + a11y wiring** into the native a11y tree (Android + iOS) with reset‑on‑recycle | **M** | every E2E layer; also ships real a11y |
| T1 | **`Native.Testing` `.can` module** — un‑phantom the binding to the in‑JS TEST SUPPORT engine | **S** | `canopy test` property tests; `Test.Native`/`Test.NativeCss` currently can't compile |
| T2 | **Widen + CI‑wire mock‑Fabric harness** — TAP + JUnit output, more components, GitHub Actions | **M** | the always‑on regression net |
| T3 | **Appium 2 + WebdriverIO (TS) E2E** — UIAutomator2 + XCUITest, select by `testID`, Lumen spec | **L** | device E2E; needs T0 |
| T4 | **Maestro YAML smoke** — cross‑platform launch/flow smoke | **S** | quick per‑PR sanity; needs T0 |
| T5 | **Cross‑device matrix** — local emu/sim per‑RC + cloud farm (Firebase Test Lab / BrowserStack), sharded; screenshots/visual baselines; video/trace; flake control; crash symbolication | **XL** | release gate; needs T3 (+iOS project) |

**Ordering rationale:** T0 is the hard P0 prerequisite — without a stable, queryable
identifier in the platform a11y tree, no off‑the‑shelf driver (Appium, Maestro, Espresso,
XCUITest) can find an element, so T3/T4/T5 are all dead until it lands. T1 is tiny and
unblocks the already‑authored `.can` property tests today. T2 hardens the device‑free net
and puts it in CI. T3 is the real E2E muscle. T4 is a cheap parallel smoke. T5 is the
release‑grade matrix and is partly gated on the **iOS project bring‑up** (see §7), which
is a separate, large, non‑testing prerequisite.

**Reject Detox.** Detox is React‑Native‑specific: it hooks RN's bridge/`RCTBridge`
synchronization idle to know when the app is settled, and ships a grey‑box client baked
into the RN runtime. Canopy‑native has **no React Native** (bare Hermes + JSI + Yoga, per
`CanopyHost.java:1‑17`, `CanopyHostViewController.mm:1‑11`), so Detox's sync engine has
nothing to attach to and its component matchers don't exist. We use **black‑box** drivers
(UIAutomator2 / XCUITest via Appium, and Maestro) that select on the OS a11y tree — which
is exactly what T0 populates. Our settle signal is replaced by a tiny first‑party idle
hook (§4.4).

---

## 1. Current state (file:line evidence)

### 1.1 The device‑free base is strong and real

- **Mock Fabric** `harness/mock-fabric.js` implements the exact `__fabric_*` JSI surface
  `external/native.js` drives: `__fabric_createView/updateProps/insertChild/removeChild/
  setRoot/setEvents/requestFrame` (`mock-fabric.js:25‑86`), building a real in‑memory view
  tree + an ordered mutation `log`, with harness controls `findByTestID` (`:107`),
  `findByTag` (`:113`), `emit` (gesture inject, `:121`), `renderTree` (`:128`).
- **Three runners**, all green:
  - `harness/run.js` — drives the source walker via `mini-runtime` against the counter view;
    asserts §8 (native RCT tree, ONE targeted `updateProps` on tap, no re‑mount). 17/17.
  - `harness/run-compiled.js` — drives the **real compiled IIFE bundle**
    (`examples/counter/build/canopy.bundle.js`) the same way. End‑to‑end through the real
    scheduler.
  - `harness/run-echo.js` — drives the **real native‑module ABI** round‑trip with a
    `mock-native-modules.js` worker→JS hop (`run-echo.js:73‑159`). 22/22.
- **`canopy test` `.can` property tests already authored** but **cannot compile**:
  `tests/Test/Native.can` and `tests/Test/NativeCss.can` both `import Native.Testing as Testing`
  (`Test/Native.can:14`, `Test/NativeCss.can:13`) and call `Testing.rootTag` / `rootText` /
  `childTags` / `createCountForUpdate` / `updateCountForUpdate` / `textAfterUpdate` /
  `styleValue`. **There is no `src/Native/Testing.can`** and `Native.Testing` is **not** in
  `canopy.json` `exposed-modules` (`canopy.json:7‑14`). This is the phantom.

### 1.2 The TEST SUPPORT engine exists in JS but is unbound

`external/native.js:784‑923` is a complete, tree‑shakeable test engine that drives the
**real** walker (`_Native_render` / `_Native_updateTNode`) against an in‑JS mock Fabric:

- `_test_install()` (`:796‑826`) swaps in `__fabric_*` shims that record into `_test_views`
  / `_test_log`.
- Exported FFI functions with `@canopy-type` / `@name` annotations ready to bind:
  - `testRootTag` (`:848`), `testRootText` (`:858`), `testChildTags` (`:868`),
    `testCreateCountForUpdate` (`:882`), `testUpdateCountForUpdate` (`:894`),
    `testTextAfterUpdate` (`:906`), `testStyleValue` (`:918`).

These names map 1:1 onto what the `.can` tests already call. The only missing piece is a
`.can` `foreign import javascript "external/native.js"` wrapper module.

### 1.3 testID + accessibility flow to the host but are DROPPED — the P0 gap

- `Native.Attributes` declares `testID` and `accessibilityRole` as plain VDOM attributes:
  `testID = VirtualDom.attribute "testID"` (`Native/Attributes.can:292‑294`),
  `accessibilityRole` (`:287‑289`). **No `accessibilityLabel`/`accessibilityHint`/
  `accessible` exists yet.**
- The walker funnels attribute facts through `_Native_factsToProps`: the `a__1_ATTR` bucket
  is copied straight onto the props object (`native.js:170‑175`), so on a render the host's
  `applyProps` receives `props.testID = "save-button"`, `props.accessibilityRole = "button"`
  as **top‑level props**.
- **Android `CanopyHost.applyProps` consumes none of them.** It handles only `text`
  (`CanopyHost.java:200`), `bitmapHandle` (`:205`), the BeforeAfter handles (`:212‑216`),
  `style` (`:218`), `__events` (`:222`) — and silently `catch`es everything else. `testID`
  and `accessibilityRole` fall on the floor. There is **no** `setContentDescription`, **no**
  stable view id, **no** `setTag(key, …)`. (`view.setTag(cv)` at `:89` stores the internal
  `CView`, unrelated — and would actually collide with a single‑arg a11y tag, so we must use
  the keyed `setTag(int, Object)` overload, see T0.)
- **iOS `CanopyHostFabric.applyProps` consumes only `text` + `style`** (`CanopyHostFabric.mm:130‑141`).
  No `accessibilityIdentifier`, no `accessibilityLabel`, no `isAccessibilityElement`.
- **Net:** the headline "testID is a no‑op on BOTH hosts; Native.Testing is a phantom" is
  confirmed at file:line. A driver attaching to either host today finds an a11y tree with no
  identifiers — element selection is impossible.

### 1.4 The event round‑trip a driver will exercise

A tap on Android: `setEvents` makes the view clickable and posts
`CanopyHostJni.emitEvent(h,"press","{}")` (`CanopyHost.java:139‑147`); the JNI native
`emitEvent` (`CanopyHostJni.java:34`) hops to `canopy::canopyEmitEvent` on the JS thread,
which invokes the JS dispatcher installed by `installEventDispatcher`
(`native.js:778‑781`). iOS `setEvents` is a **TODO stub** that only records the names
(`CanopyHostFabric.mm:104‑110`) — gesture recognizers are not wired, so even tap‑driven E2E
on iOS is blocked until the host event seam is finished (tracked under §7 iOS bring‑up, not
this plan's scope to fix, but called out as a dependency for T3‑iOS).

### 1.5 No project/CI exists

- Android: a Gradle app at `host/android/` (`app/build.gradle` — `com.android.application`,
  bare Hermes/Yoga, no RN). No `androidTest`, no CI yaml anywhere in the tree.
- iOS: **two loose `.mm` files** (`host/ios/CanopyHost/CanopyHostFabric.mm`,
  `CanopyHostViewController.mm`) and **no `.xcodeproj`/`.xcworkspace`/Podfile** (`ls` of
  `host/ios/CanopyHost/` shows only the two files). iOS cannot build or run on a device →
  every iOS test layer is **blocked on the iOS project bring‑up** (§7).
- Harness has a `package.json` with `test: node run.js && run-compiled.js && run-echo.js`
  (`harness/package.json:6‑11`) but **no TAP/JUnit emitter and no CI invocation**.

---

## 2. Target design (RN parity, the testing pyramid)

```
            ▲  fewest, slowest, highest-fidelity
   ┌────────┴─────────┐
   │  Device MATRIX   │  T5  cloud farm (FTL/BrowserStack), sharded, visual+video+symbolication
   ├──────────────────┤
   │  E2E (Appium)    │  T3  real emu/sim, select by testID, full Lumen flow
   ├──────────────────┤
   │  Smoke (Maestro) │  T4  cheap cross-platform launch/flow YAML
   ├──────────────────┤
   │  Component props │  T1  `canopy test` §8 properties authored in Canopy
   ├──────────────────┤
   │  Mock-Fabric unit│  T2  device-free, TAP/JUnit, in CI on every push
   └──────────────────┘
            ▼  most, fastest, run on every push
```

**Single selector contract across all layers:** `testID`. It is:
1. the prop the mock‑Fabric harness already indexes (`findByTestID`, `mock-fabric.js:107`);
2. (after T0) the Android `View` content‑description **and** keyed resource tag, so
   UIAutomator2 selects via `resource-id`/`content-desc` and Espresso via tag;
3. (after T0) the iOS `accessibilityIdentifier`, so XCUITest selects via `id`.

`accessibilityRole` → the platform a11y role; `accessibilityLabel` → the spoken/queried
label. This is the RN convention (`testID`, `accessibilityLabel`, `accessibilityRole`,
`accessible`) so any RN‑familiar engineer and any black‑box driver behaves as expected.

**Data flow (unchanged seam):** Canopy attribute → `a__1_ATTR` fact → `_Native_factsToProps`
top‑level prop (`native.js:170‑175`) → host `applyProps`. T0 only adds **consumption** in
the two `applyProps` methods; the walker, css, and ABI are untouched.

---

## 3. T0 — testID + accessibility wiring (P0 prerequisite)

### 3.1 `.can` API additions — `Native.Attributes`

Add `accessibilityLabel`, `accessibilityHint`, `accessible` next to the existing
`testID`/`accessibilityRole` (`Native/Attributes.can:11`, `:287‑294`).

```canopy
-- Native/Attributes.can — add to the exposing list (line 11) and @docs (line 35)
{-| A spoken/queried label for assistive tech and test drivers (RN `accessibilityLabel`). -}
accessibilityLabel : String -> Attribute msg
accessibilityLabel =
    VirtualDom.attribute "accessibilityLabel"

{-| A supplementary hint read after the label (RN `accessibilityHint`). -}
accessibilityHint : String -> Attribute msg
accessibilityHint =
    VirtualDom.attribute "accessibilityHint"

{-| Mark this view as a single a11y element (collapses children for VoiceOver/TalkBack). -}
accessible : Bool -> Attribute msg
accessible b =
    VirtualDom.attribute "accessible" (if b then "true" else "false")
```

No walker change is needed — these ride the same `a__1_ATTR` path as `testID`.

### 3.2 Android — `CanopyHost.applyProps` (consume the a11y props)

**File:** `host/android/app/src/main/java/com/canopyhost/CanopyHost.java`

Add, inside `applyProps` (after the `text` block, before `style` at `:218`), a block that
reads the four props and writes the platform a11y tree, with **reset‑on‑recycle** (a recycled
view that lost a prop must drop the stale value — mirrors the `isNull` reset discipline the
file already uses for `text`/style, `:198‑203`/`:232`):

```java
// --- accessibility + test identity (T0) -----------------------------------
// testID → BOTH a stable id (UIAutomator2 resource-id) AND content-description
// (Espresso/content-desc fallback). accessibilityLabel → content-description
// (overrides testID if present). accessibilityRole → a Talkback role hint.
// Recycled-view reset: a prop removed on a diff arrives as JSON null → clear it.
if (props.has("testID")) {
  String tid = props.isNull("testID") ? null : props.optString("testID", null);
  // R.id.canopy_testid is a stable id resource (see ids.xml); set as a *keyed* tag so it
  // never collides with view.setTag(cv) at createView (:89). UIAutomator2 reads this via
  // the accessibility node's viewIdResourceName ONLY if it is a real resource id, so we
  // ALSO mirror it into the node's "test tag" used by setTag(key,…) which UiAutomator
  // surfaces through getViewIdResourceName on API 24+ via the a11y bridge below.
  cv.view.setTag(R.id.canopy_testid, tid);
  // Espresso & content-desc selectors:
  if (cv.testIDContentDesc) { cv.view.setContentDescription(tid); }
}
if (props.has("accessibilityLabel")) {
  String lbl = props.isNull("accessibilityLabel") ? null : props.optString("accessibilityLabel", null);
  cv.a11yLabel = lbl;
  // label wins over testID for content-description (what TalkBack speaks)
  cv.view.setContentDescription(lbl != null ? lbl : (String) cv.view.getTag(R.id.canopy_testid));
  cv.testIDContentDesc = (lbl == null); // if no label, testID may own content-desc
}
if (props.has("accessibilityRole")) {
  cv.a11yRole = props.isNull("accessibilityRole") ? null : props.optString("accessibilityRole", null);
  installAccessibilityDelegate(cv); // maps role → AccessibilityNodeInfo.setRoleDescription / className
}
if (props.has("accessibilityHint")) {
  cv.a11yHint = props.isNull("accessibilityHint") ? null : props.optString("accessibilityHint", null);
  installAccessibilityDelegate(cv);
}
if (props.has("accessible")) {
  boolean acc = !props.isNull("accessible") && "true".equals(props.optString("accessible"));
  cv.view.setImportantForAccessibility(acc
      ? View.IMPORTANT_FOR_ACCESSIBILITY_YES : View.IMPORTANT_FOR_ACCESSIBILITY_AUTO);
}
```

Supporting pieces in the same file:

```java
// CView fields (add near :53-61):
String a11yLabel = null, a11yRole = null, a11yHint = null;
boolean testIDContentDesc = true;   // testID owns content-desc until a label arrives

// One AccessibilityDelegate that publishes role/hint into the node info.
private void installAccessibilityDelegate(CView cv) {
  cv.view.setAccessibilityDelegate(new View.AccessibilityDelegate() {
    @Override public void onInitializeAccessibilityNodeInfo(View v, AccessibilityNodeInfo info) {
      super.onInitializeAccessibilityNodeInfo(v, info);
      if (cv.a11yRole != null) {
        info.setClassName(roleToClassName(cv.a11yRole));  // "button"→Button, "image"→ImageView, …
        info.setRoleDescription(cv.a11yRole);             // API 30+; harmless below
      }
      if (cv.a11yHint != null) info.setTooltipText(cv.a11yHint);
    }
  });
}
private static CharSequence roleToClassName(String role) {
  switch (role) {
    case "button": return "android.widget.Button";
    case "image":  return "android.widget.ImageView";
    case "header": return "android.widget.TextView";
    case "link":   return "android.widget.Button";
    default:       return "android.view.View";
  }
}
```

Add a stable id resource so UIAutomator2 can key on it:

**File (new):** `host/android/app/src/main/res/values/ids.xml`
```xml
<resources><item name="canopy_testid" type="id"/></resources>
```

> **Selector note (Android).** UIAutomator2's `resource-id` reflects the view's *resource*
> name, which we don't own per‑element at runtime; the robust, RN‑equivalent selector is
> **content‑description** (`~testID` / `accessibility id` in Appium). T0 makes `testID` the
> content‑description (when no explicit `accessibilityLabel`), so Appium's `~save-button`
> (accessibility‑id strategy) and Maestro's `id: "save-button"` both resolve. The keyed
> `setTag(R.id.canopy_testid, …)` additionally lets **Espresso** in‑process tests select via
> a custom `withTagValue` matcher if we ever add JVM `androidTest`.

**Reset‑on‑recycle correctness:** the walker emits a removed prop as JSON `null`
(`native.js` diff path, the same mechanism `applyStyle` relies on at
`CanopyHost.java:232`). Each `props.has(...)` block above handles the `isNull` case by
clearing the field/content‑description, so a `RCTView` recycled from a button into a plain
row drops its stale `testID`/role — matching the existing event‑reset discipline
(`setEvents` tears down stale click/gesture handlers, `:142‑157`).

### 3.3 iOS — `CanopyHostFabric.applyProps` (consume the a11y props)

**File:** `host/ios/CanopyHost/CanopyHostFabric.mm` — extend `applyProps` (`:130‑141`):

```objc
// --- accessibility + test identity (T0) -----------------------------------
id tid = props[@"testID"];
cv.view.accessibilityIdentifier = [tid isKindOfClass:[NSString class]] ? tid : nil;

id label = props[@"accessibilityLabel"];
if ([label isKindOfClass:[NSString class]]) {
  cv.view.isAccessibilityElement = YES;
  cv.view.accessibilityLabel = label;
} else if (props[@"accessibilityLabel"]) {           // explicit null on a diff → reset
  cv.view.accessibilityLabel = nil;
}

id hint = props[@"accessibilityHint"];
cv.view.accessibilityHint = [hint isKindOfClass:[NSString class]] ? hint : nil;

id role = props[@"accessibilityRole"];
if ([role isKindOfClass:[NSString class]]) {
  cv.view.accessibilityTraits = traitsForRole(role);  // button→UIAccessibilityTraitButton, …
} else if (props[@"accessibilityRole"]) {
  cv.view.accessibilityTraits = UIAccessibilityTraitNone;
}

id acc = props[@"accessible"];
if (acc) cv.view.isAccessibilityElement = [acc isEqual:@"true"] || [acc boolValue];
```

```objc
static UIAccessibilityTraits traitsForRole(NSString* role) {
  if ([role isEqualToString:@"button"]) return UIAccessibilityTraitButton;
  if ([role isEqualToString:@"image"])  return UIAccessibilityTraitImage;
  if ([role isEqualToString:@"header"]) return UIAccessibilityTraitHeader;
  if ([role isEqualToString:@"link"])   return UIAccessibilityTraitLink;
  return UIAccessibilityTraitNone;
}
```

**XCUITest selection:** `accessibilityIdentifier` is exactly the field XCUITest's
`app.buttons["save-button"]` / Appium's `~save-button` (accessibility id) resolves on iOS —
it is **not** read aloud, so it's the correct test handle, with `accessibilityLabel`
reserved for the human‑spoken string. This is RN's exact mapping.

> **iOS dependency:** these lines compile only inside an iOS target. They are written now so
> the bring‑up (§7) merely *links* them; until then iOS E2E is blocked. The unit and mock
> layers (T1/T2) are platform‑independent and validate the **prop is emitted** regardless.

### 3.4 Prove T0 without a device

`testID`/a11y props are now asserted in the **mock‑Fabric** layer (already records all
props): extend `run.js`/`run-compiled.js` (or a new `run-a11y.js`) to assert that the
counter's increment button carries `props.testID === "increment"` **and** (new) that a
recycled view drops a removed `testID` to `undefined`. This guards the seam that the hosts
consume, on every CI run, with no emulator.

---

## 4. T1 — `Native.Testing` `.can` module (un‑phantom the engine)

### 4.1 New file `src/Native/Testing.can`

Bind the seven engine functions (`native.js:848‑923`) following the **exact** `foreign
import` convention `Native.Module` uses (`Native/Module.can:39`). The JS already carries
`@canopy-type` / `@name` annotations so the names line up.

```canopy
module Native.Testing exposing
    ( rootTag, rootText, childTags
    , createCountForUpdate, updateCountForUpdate, textAfterUpdate
    , styleValue
    )

{-| **Device‑free component property tests for `Native` views.** Drives the REAL Fabric
walker (`_Native_render` / `_Native_updateTNode`) against an in‑memory mock Fabric (the
TEST SUPPORT engine in `external/native.js`), so `canopy test` can assert the architecture
§8 guarantees per component with no device:

  - the right Fabric component tag (`rootTag`)
  - the text it renders (`rootText`)
  - the structure of its children (`childTags`)
  - that a value change is a TARGETED update, not a re‑mount
    (`createCountForUpdate == 0`, `updateCountForUpdate == 1`)
  - that canopy/css → native style facts map correctly (`styleValue`)

This module is import‑gated: a production app that never imports it tree‑shakes the whole
engine out (the same proof the event dispatcher enjoys — see native.js §"TEST SUPPORT").

@docs rootTag, rootText, childTags
@docs createCountForUpdate, updateCountForUpdate, textAfterUpdate
@docs styleValue
-}

import VirtualDom


foreign import javascript "external/native.js" as Engine


{-| The Fabric component tag of the rendered root (e.g. `"RCTView"`, `"RCTText"`). -}
rootTag : VirtualDom.Node msg -> String
rootTag node =
    Engine.testRootTag node


{-| All text the tree renders (label fast‑path + descendants concatenated). -}
rootText : VirtualDom.Node msg -> String
rootText node =
    Engine.testRootText node


{-| The Fabric tags of the root's direct children, in order. -}
childTags : VirtualDom.Node msg -> List String
childTags node =
    Engine.testChildTags node


{-| Render `old`, diff to `new`; how many NEW views were created (0 = no re‑mount). -}
createCountForUpdate : VirtualDom.Node msg -> VirtualDom.Node msg -> Int
createCountForUpdate old new =
    Engine.testCreateCountForUpdate old new


{-| Render `old`, diff to `new`; how many `updateProps` were emitted. -}
updateCountForUpdate : VirtualDom.Node msg -> VirtualDom.Node msg -> Int
updateCountForUpdate old new =
    Engine.testUpdateCountForUpdate old new


{-| The text the tree shows after diffing `old` → `new`. -}
textAfterUpdate : VirtualDom.Node msg -> VirtualDom.Node msg -> String
textAfterUpdate old new =
    Engine.testTextAfterUpdate old new


{-| The value of one Fabric style key on the rendered root (`""` if absent). -}
styleValue : String -> VirtualDom.Node msg -> String
styleValue key node =
    Engine.testStyleValue key node
```

> The `.can` parameter types are `VirtualDom.Node msg`; the existing tests pass
> `Native.Node msg`, which is a `type alias … = VirtualDom.Node msg` (see `Native` core),
> so they unify. If the compiler's FFI arity checker wants the engine's `F2` shape for the
> two‑arg functions, it already gets it — `testCreateCountForUpdate` etc. are defined with
> `F2(...)` (`native.js:882`,`:894`,`:918`), matching a curried 2‑arg `.can` signature.

### 4.2 `canopy.json` — expose the module

```json
"exposed-modules": [
    "Native", "Native.Attributes", "Native.Events",
    "Native.BeforeAfter", "Native.Css", "Native.Module",
    "Native.Testing"          // ← add
],
```
(`canopy.json:7‑14`.) Keep it under the normal package (not test‑only) so apps may write
their own component property tests; the tree‑shake guarantee keeps it out of release bundles.

### 4.3 Verify

`canopy test tests/Test/Native.can` and `canopy test tests/Test/NativeCss.can` now compile
and run (they were authored against this exact API — `Test/Native.can:34‑139`,
`Test/NativeCss.can:20‑64`). Add to CI (T2). Extend `Test.Native` with **LIS‑reorder ≤ k**
and **a11y‑prop** properties:

```canopy
-- in Test.Native, new describe block:
keyedReorder : Test
keyedReorder =
    describe "keyed reorder is O(moves), not a re-mount"
        [ test "reversing a 5-item keyed list creates ZERO new views" <|
            \_ -> Expect.equal 0
                    (Testing.createCountForUpdate (keyedList [1,2,3,4,5]) (keyedList [5,4,3,2,1]))
        , test "moving one item emits ≤ k updateProps (LIS keeps the rest pinned)" <|
            \_ -> Expect.atMost 2
                    (Testing.updateCountForUpdate (keyedList [1,2,3]) (keyedList [2,1,3]))
        ]
-- a11y prop coverage (needs a thin engine helper testPropValue — see 4.5):
, test "testID lands as a top-level prop" <|
    \_ -> Expect.equal "save"
            (Testing.propValue "testID" (Native.button [ A.testID "save" ] "Save"))
```

### 4.4 (parallel) first‑party **idle hook** for E2E settle

Detox's value was "wait until the app is idle." We replace it with a 6‑line JSI export the
walker already has the data for. Add to `native.js` export block (`:932‑948`):

```js
// __canopy_idle(): true when no Cmd is in flight and no frame is queued. The host
// exposes this to the driver (Android: an a11y action / intent; iOS: a custom XCUITest
// helper) so E2E can poll instead of sleep. Cheap, deterministic, RN-Detox-equivalent.
function _Native_isIdle() { return _NM_pending === 0 && _Native_frameQueue.length === 0; }
```
Wire `globalThis.__canopy_idle = _Native_isIdle` at boot. The WDIO helper (§5.4) polls it
via a host bridge; if the bridge isn't present it falls back to Appium's `waitForIdle`.

### 4.5 Optional engine helper for prop assertions

Add one function beside `testStyleValue` so a11y props are unit‑assertable in `.can`:

```js
/** @canopy-type String -> VirtualDom.Node msg -> String
 *  @name testPropValue */
var testPropValue = F2(function (key, vNode) {
  var n = _test_render(vNode);
  var p = _test_views[n.__handle].props;
  return p && p[key] != null ? String(p[key]) : '';
});
```
Export it (`:933‑948`) and bind `propValue` in `Native/Testing.can`.

---

## 5. T2 — widen + CI‑wire the mock‑Fabric harness

### 5.1 TAP + JUnit output

The runners currently print ANSI checks (`run.js:26‑30`). Refactor the shared assertion
harness into `harness/lib/report.js` exporting `check/section/done` plus two emitters:

- **TAP 14** to stdout (`ok N - name` / `not ok N - name # detail`, a `1..N` plan, `# Subtest`
  for sections) — consumable by `tap-junit`, `node-tap`, and most CI test reporters.
- **JUnit XML** to `harness/reports/junit-<runner>.xml` (one `<testsuite>` per runner,
  `<testcase>` per check, `<failure>` with detail) — what GitHub Actions test‑report actions
  and Firebase/BrowserStack dashboards ingest.

```js
// harness/lib/report.js
function createReporter(suiteName) {
  let n = 0, fails = 0; const cases = [];
  return {
    check(name, cond, detail) {
      n++; const ok = !!cond; if (!ok) fails++;
      cases.push({ name, ok, detail });
      process.stdout.write(`${ok ? 'ok' : 'not ok'} ${n} - ${name}${ok ? '' : ' # ' + (detail||'')}\n`);
    },
    section(t) { process.stdout.write(`# ${t}\n`); },
    done() {
      process.stdout.write(`1..${n}\n`);
      writeJUnit(suiteName, cases);                // harness/reports/junit-<suite>.xml
      process.exit(fails ? 1 : 0);
    }
  };
}
```
Port `run.js`, `run-compiled.js`, `run-echo.js`, and the new `run-a11y.js` to use it. Keep
the human‑readable summary behind a `--pretty` flag for local use.

### 5.2 Widen component coverage

Today the harness exercises the counter + echo. Add fixtures/`.can` examples and harness
assertions for the components the audit flagged as the risky surface, so a regression in any
host‑facing prop is caught device‑free:

- `Native.scroll` → `RCTScrollView` tag + that children are inserted (catches the
  "scroll is a non‑scrolling stub" class of regressions at the JS seam).
- `Native.textInput` → `RCTSinglelineTextInputView` + `value`/`placeholder` props +
  `onChangeText` event registration (asserts the event name reaches `__events`).
- `Native.image` → `RCTImageView` + `source`/`bitmapHandle` prop pass‑through.
- `Native.text` style facts (fontSize/color/fontWeight) land in `props.style` with px
  stripped (the `Test.NativeCss` properties, but also in the JS harness for the compiled
  bundle).
- **a11y**: `testID`, `accessibilityRole`, `accessibilityLabel` arrive as top‑level props
  (guards T0's contract from the JS side).

These are pure VDOM→Fabric assertions — no host, no device — and run in milliseconds.

### 5.3 CI config (GitHub Actions)

**File (new):** `.github/workflows/native-tests.yml`

```yaml
name: native-tests
on: { push: {}, pull_request: {} }
jobs:
  mock-fabric:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: '22' }
      # The compiled-bundle + echo runners need the canopy compiler to (re)build fixtures.
      - name: Install canopy toolchain
        run: ./native/scripts/install-canopy.sh     # pins compiler 0.19.x + canopy-native
      - name: Build harness fixtures
        run: |
          (cd native/examples/counter && canopy-native build)
          (cd native/examples/echo    && canopy-native build)
      - name: Run mock-Fabric harness (TAP+JUnit)
        run: cd native/harness && node run.js && node run-compiled.js && node run-echo.js && node run-a11y.js
      - name: Canopy component property tests
        run: |
          (cd native/package && canopy test tests/Test/Native.can)
          (cd native/package && canopy test tests/Test/NativeCss.can)
      - uses: actions/upload-artifact@v4
        if: always()
        with: { name: junit, path: native/harness/reports/junit-*.xml }
      - uses: mikepenz/action-junit-report@v4
        if: always()
        with: { report_paths: native/harness/reports/junit-*.xml }
```

This job needs **no Android SDK / no Mac** — it runs on the box's documented ceiling (Node +
canopy compiler on PATH). It is the always‑on net.

---

## 6. T3 — Device E2E (Appium 2 + WebdriverIO, TS)

### 6.1 Why Appium+WDIO (not Detox)

- **Black‑box, OS‑level**: drives UIAutomator2 (Android) and XCUITest (iOS) via the OS a11y
  tree — exactly what T0 populates. No RN runtime dependency.
- **One selector vocabulary across both platforms**: `~testID` (accessibility id) resolves to
  Android content‑description and iOS `accessibilityIdentifier` — both written by T0.
- **TS first‑class**, integrates with the same JUnit/TAP CI as T2, and the same farm vendors
  (FTL/BrowserStack) host Appium natively (T5).

### 6.2 Project layout

```
native/e2e/
  package.json                 # appium, @wdio/cli, @wdio/local-runner, @wdio/mocha-framework,
                               # @wdio/junit-reporter, appium-uiautomator2-driver,
                               # appium-xcuitest-driver, ts-node, typescript
  tsconfig.json
  wdio.shared.conf.ts          # framework=mocha, reporters=[spec, junit], common caps
  wdio.android.conf.ts         # extends shared; UiAutomator2; app=<path>/app-debug.apk
  wdio.ios.conf.ts             # extends shared; XCUITest; app=<path>/Canopy.app  (blocked, §7)
  config/capabilities.ts       # device/OS matrix knobs (local vs farm)
  helpers/
    driver.ts                  # by(testID) → $('~'+id); waitIdle(); tapById(); typeInto()
    app.ts                     # launch/terminate/reset; install per-RC artifact
  specs/
    smoke.e2e.ts               # app launches, root surface present, first screen labels
    lumen-restore.e2e.ts       # the headline Lumen flow (below)
  reports/                     # junit + screenshots + video pointers
```

### 6.3 Shared config (essentials)

```ts
// wdio.shared.conf.ts
export const shared: WebdriverIO.Config = {
  runner: 'local',
  framework: 'mocha',
  specs: ['./specs/**/*.e2e.ts'],
  maxInstances: Number(process.env.WDIO_PARALLEL ?? 1),
  reporters: ['spec', ['junit', { outputDir: './reports', outputFileFormat: o => `e2e-${o.cid}.xml` }]],
  mochaOpts: { ui: 'bdd', timeout: 120000 },
  autoCompileOpts: { tsNodeOpts: { transpileOnly: true } },
};
```

```ts
// wdio.android.conf.ts
import { shared } from './wdio.shared.conf';
export const config = { ...shared, port: 4723, capabilities: [{
  platformName: 'Android',
  'appium:automationName': 'UiAutomator2',
  'appium:app': process.env.CANOPY_APK ?? '../host/android/app/build/outputs/apk/debug/app-debug.apk',
  'appium:appWaitActivity': 'com.canopyhost.MainActivity',
  'appium:autoGrantPermissions': true,
  'appium:newCommandTimeout': 120,
}]};
```

### 6.4 Driver helpers — select by testID

```ts
// helpers/driver.ts
export const by = (testID: string) => $(`~${testID}`);   // accessibility id (content-desc / a11y-id)

export async function waitIdle(timeout = 10000) {
  // Prefer the first-party idle hook (§4.4) exposed by the host as a mob: command or
  // a11y action; fall back to UIAutomator2/XCUITest quiescence.
  try {
    await browser.waitUntil(async () =>
      (await driver.execute('canopy: isIdle')) === true, { timeout, interval: 100 });
  } catch { await driver.waitForIdle?.({ timeout }); }
}

export async function tapById(id: string)        { await (await by(id)).click(); await waitIdle(); }
export async function typeInto(id: string, t: string) { await (await by(id)).setValue(t); }
export async function textOf(id: string)         { return (await by(id)).getText(); }
```

### 6.5 The runnable Lumen E2E spec

Grounded in the real flow (`apps/lumen/app/src/Main.can:11` "Photos.pick → RestoreEngine →
BeforeAfter wipe → paywall → save"; `Msg` at `:112‑139`; the buttons already carry
`A.testID id` at `:914`,`:935`). The app currently emits `testID`s for primary/secondary
buttons; T3 requires we also stamp `testID`s on the **screens' status label** and the
**BeforeAfter view** so the spec can assert state transitions. Add those `A.testID` calls in
`Main.can` (e.g. `pick-screen`, `status-label`, `before-after`, `paywall-restore`,
`save-button`) — cheap, one‑line each.

```ts
// specs/lumen-restore.e2e.ts
import { tapById, textOf, by, waitIdle } from '../helpers/driver';

describe('Lumen — pick → restore → compare → save', () => {
  it('launches to the Pick screen', async () => {
    await waitIdle();
    await expect(await by('pick-screen')).toBeDisplayed();
  });

  it('picks a photo and runs the restore (mocked picker + ESPCN seam on the device)', async () => {
    await tapById('pick-button');           // Main.can: Pick msg → Photos.pick
    // The test build registers a deterministic mock Photos module that returns the bundled
    // assets/lumen-test.jpg handle (host already ships it: android/.../assets/lumen-test.jpg),
    // so no system photo-picker UI is needed in CI.
    await waitIdle();
    await tapById('restore-button');        // → RestoreEngine.processBlob
    await browser.waitUntil(async () => (await textOf('status-label')).includes('ready'),
      { timeout: 60000, timeoutMsg: 'restore never completed' });
  });

  it('shows the before/after compare surface', async () => {
    await expect(await by('before-after')).toBeDisplayed();
  });

  it('gates save behind the paywall, then saves on entitlement', async () => {
    await tapById('save-button');           // not entitled → paywall
    await expect(await by('paywall-restore')).toBeDisplayed();
    await tapById('paywall-restore');       // Billing.restore → mock store grants entitlement
    await tapById('save-button');           // now Album.save
    await browser.waitUntil(async () => (await textOf('status-label')).includes('Saved'),
      { timeout: 30000 });
  });
});
```

**Determinism for E2E:** the device E2E uses a **test build flavor** that registers the same
deterministic mock capability modules the harness uses in spirit — mock `Photos` (returns the
bundled `lumen-test.jpg`), mock `Billing` (the FAKE store is already that — `BillingModule`),
real `RestoreEngine` ESPCN seam, mock `Notify`. This keeps the flow real end‑to‑end through
Yoga/Fabric/JSI while removing system‑UI nondeterminism (photo chooser, real Play purchase).
Add a `canopy.bundle.test.js` asset + a `BuildConfig.CANOPY_TEST` toggle in `MainActivity`.

### 6.6 Android E2E execution (local, today)

The box has a hardware‑accelerated emulator (`/dev/kvm`, AVD `canopy_echo`, per memory). The
loop:
```bash
appium --base-path / &                                    # Appium 2 server, UIAutomator2 installed
(cd native/host/android && gradle :app:assembleDebug)     # produces app-debug.apk
(cd native/e2e && npx wdio run wdio.android.conf.ts)
```
Appium installs UIAutomator2 onto the running AVD and drives the APK; selectors resolve via
the content‑descriptions T0 stamped. **This is runnable on this Linux box** once T0 + the
testID stamps land.

### 6.7 iOS E2E (blocked on §7)

`wdio.ios.conf.ts` + the XCUITest driver are written now, but require: (a) the iOS Xcode
project/target (none exists — §7); (b) the iOS host event seam (`setEvents` is a TODO stub,
`CanopyHostFabric.mm:104‑110`, so taps don't fire yet); (c) a Mac/cloud‑Mac runner. The
**same spec files run unchanged** once those land — that is the payoff of the single `testID`
contract.

---

## 7. iOS bring‑up — the blocker called out per piece

iOS testing (T0‑iOS verification, T3‑iOS, T4‑iOS, T5‑iOS) is gated on work that is **not in
this plan's scope to deliver** but must exist first:

1. **No Xcode project.** `host/ios/CanopyHost/` is two loose `.mm` files; there is no
   `.xcodeproj`/`.xcworkspace`/Podfile/`Info.plist`/app target. Until an iOS app target links
   UIKit + Yoga + Hermes and bundles `canopy.bundle.js`, nothing builds.
2. **iOS host event seam is a stub** (`CanopyHostFabric.mm:104‑110`) — no gesture recognizers,
   so even a launched app can't be tapped. (`testID` requires a Mac to *verify*, see §3.3.)
3. **Mac/cloud‑Mac required** — this Linux box can't build or simulate iOS (per memory's
   environment ceiling). T5's iOS leg therefore lands first on the **cloud farm** (FTL has no
   iOS; **BrowserStack App Automate** or a macOS CI runner is the iOS path).

What **is** unblocked for iOS right now: the `.can` API (T1), the mock‑Fabric unit assertions
(T2) — both platform‑independent — and the **already‑written** `applyProps` a11y lines
(§3.3) and `wdio.ios.conf.ts`/spec files, which sit ready for the bring‑up.

---

## 8. T4 — Maestro YAML smoke (cross‑platform)

Maestro selects by `id` (→ Android content‑desc / iOS accessibilityIdentifier — i.e. T0's
`testID`) and runs the **same YAML** on both platforms. It's the cheapest per‑PR smoke and
needs no driver server.

**File:** `native/e2e/maestro/lumen-smoke.yaml`
```yaml
appId: com.canopyhost
---
- launchApp
- assertVisible:
    id: "pick-screen"
- tapOn:
    id: "pick-button"
- tapOn:
    id: "restore-button"
- extendedWaitUntil:
    visible: { id: "before-after" }
    timeout: 60000
- assertVisible:
    id: "before-after"
```
Run: `maestro test native/e2e/maestro/lumen-smoke.yaml`. Maestro Cloud or `maestro test
--format junit` integrates with the same JUnit pipeline. Use it as the fast gate; reserve the
full WDIO Lumen spec (§6.5) for the matrix.

---

## 9. T5 — Cross‑device matrix

### 9.1 Local per‑RC tier (free, runs on this box for Android)

A scripted sweep over a few AVDs spanning API/screen/density (e.g. API 24 min, API 34
target, a tablet) before cutting a release candidate:
```bash
native/scripts/matrix-local.sh   # for each AVD: boot → install APK → run wdio + maestro → collect junit/screens
```
iOS local sim sweep mirrors this once §7 lands (on a Mac).

### 9.2 Cloud device farm (release gate)

- **Android → Firebase Test Lab.** Upload `app-debug.apk` + an Appium/Robo or
  instrumentation package; FTL shards across physical devices, returns video, logcat,
  screenshots, and **crash clusters with symbolication** when the debug `.so`s carry symbols.
  Wire via `gcloud firebase test android run --type robo` for a smoke and a custom Appium
  package for the full spec.
- **iOS → BrowserStack App Automate** (FTL has no iOS) or a macOS CI runner farm — uploads the
  `.app`/`.ipa`, runs the **same WDIO spec** with `app` pointed at the BrowserStack‑hosted
  build, returns video + device logs.
- **Single config drives both** via `config/capabilities.ts`: a `MATRIX` array of
  `{platform, device, osVersion}`; CI fans out one WDIO/Maestro run per cell with
  `WDIO_PARALLEL` and per‑cell JUnit, merged into one report.

### 9.3 Screenshot / visual‑regression baselines

- Capture per‑screen screenshots in the WDIO spec (`browser.saveScreenshot` after each
  `waitIdle`) keyed by `{platform}-{device}-{screen}`.
- Diff against committed baselines with `wdio-image-comparison-service` (pixel diff with a
  per‑device tolerance for status bar / safe‑area). First run seeds baselines; CI fails on a
  diff over threshold and uploads the diff image as an artifact.
- Baselines live under `native/e2e/baselines/<platform>/<device>/`; an explicit
  `--update-baselines` flag (gated to release branches) refreshes them.

### 9.4 Video / trace / flake control / symbolication

- **Video + trace:** FTL/BrowserStack record video per session; WDIO local uses
  `wdio-video-reporter` for failing specs only (keeps artifacts small).
- **Flake control:** `mochaOpts.retries: 1` for E2E specs; quarantine tag (`@flaky`) excluded
  from the gate but still reported; the **idle hook** (§4.4) is the primary flake killer
  (replaces sleeps). Track per‑test pass‑rate over the last N runs; auto‑quarantine below a
  threshold.
- **Crash symbolication:** ship debug `.so` symbol files (`libcanopyhost.so` etc.) and the
  Hermes `.map`/symbol output to FTL/BrowserStack so native crashes resolve to Canopy/host
  frames; for the JS layer, generate Hermes source maps at bundle build (`canopy-native
  build --sourcemap`, a tool flag to add in `Bundle.hs`) and symbolicate JS stacks with
  `hermesc`/`metro-symbolicate`‑equivalent.

### 9.5 Matrix CI job (sketch)

```yaml
  device-matrix:
    needs: mock-fabric
    if: github.ref == 'refs/heads/main' || startsWith(github.ref, 'refs/tags/rc-')
    strategy:
      fail-fast: false
      matrix:
        cell:
          - { platform: android, device: 'Pixel7,30' }
          - { platform: android, device: 'redfin,30' }
          # ios cells added after §7 bring-up
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: ./native/scripts/build-test-apk.sh           # debug + test-flavor bundle
      - run: ./native/e2e/run-farm.sh ${{ matrix.cell.platform }} ${{ matrix.cell.device }}
      - uses: actions/upload-artifact@v4
        if: always()
        with: { name: e2e-${{ matrix.cell.device }}, path: native/e2e/reports/** }
```

---

## 10. Web‑package reuse (reuse vs re‑back)

| Capability | Reuse as‑is | Re‑back for native |
|---|---|---|
| **Selector contract** | The `testID` prop and `findByTestID` indexing model from `mock-fabric.js:107` is reused verbatim across unit → E2E → Maestro. | — |
| **§8 property assertions** | `canopy/test` (`Expect`, `describe`, `test`) drives the `.can` property tests unchanged — same package web tests use. | The *engine* behind them (`native.js` TEST SUPPORT) is native‑specific (it asserts Fabric mutations, not DOM); already written. |
| **Component test authoring** | The `Test.Native`/`Test.NativeCss` style (the same `Expect.equal` web component tests use) ports 1:1. | — |
| **Visual regression** | The *concept* mirrors web Playwright snapshots; tooling (`wdio-image-comparison-service`) is native. | New baselines per device. |
| **Playwright itself** | **Not reusable** — Playwright drives browsers/DOM; there is no WebView here (the whole point, `CanopyHost.java:1‑13`). Appium/Maestro are the native analogs. | Full re‑back (T3/T4). |
| **CI scaffolding** | The TAP/JUnit + GitHub Actions pattern is shared with the web monorepo's test reporting. | The fixture build step is canopy‑native‑specific. |

**Principle:** reuse the *vocabulary* (`testID`, `Expect`/`describe`, JUnit) and the
*authoring ergonomics*; re‑back only the *drivers* (DOM→Fabric/a11y‑tree) where the host
fundamentally differs.

---

## 11. Testing strategy summary (what runs where)

| Layer | Tool | Selector | Where it runs | Gate |
|---|---|---|---|---|
| Walker §8 / mutation shape | `harness/run*.js` (mock Fabric) | `findByTestID`/tag | Node, no device | every push |
| Component properties | `canopy test` + `Native.Testing` | n/a (renders nodes) | Node, no device | every push |
| a11y/testID prop contract | `harness/run-a11y.js` | prop assertion | Node, no device | every push |
| Cross‑platform smoke | Maestro | `id` (=testID) | emu/sim | every PR |
| Full flow E2E | Appium 2 + WDIO (TS) | `~testID` | emu/sim, then farm | pre‑merge / per‑RC |
| Device matrix + visual | WDIO + FTL/BrowserStack | `~testID` + screenshots | cloud farm | release |

---

## 12. Risks & open questions

1. **Android `resource-id` vs content‑description.** UIAutomator2's `resource-id` reflects a
   compiled resource name we don't own per element; T0 makes `testID` the **content‑description**
   so Appium `~id`/Maestro `id` resolve. *Open:* confirm on‑device that a plain `View` with a
   content‑description but no `accessibilityRole` is reported as a queryable a11y node on API
   24 (may need `setImportantForAccessibility(YES)` even without `accessible:true`). Verify in
   the first T3 run on the AVD.
2. **content‑description double‑duty.** Using content‑description for both `testID` and
   `accessibilityLabel` means a view with both could speak the test id to TalkBack. T0 makes
   `accessibilityLabel` win and only falls back to `testID` — but a `testID`‑only button will
   announce its id. *Decision:* acceptable (RN has the same coupling); apps that care add an
   explicit `accessibilityLabel`. Revisit if real a11y review objects.
3. **iOS is blocked twice** — no Xcode project (§7‑1) *and* a stubbed event seam (§7‑2). Both
   are large, separate efforts. This plan ships iOS test *code* ready but its iOS legs are red
   until those land. Don't size T3/T5 as "done" without the iOS bring‑up plan.
4. **FFI arity for 2‑arg engine fns.** `Native.Testing` binds `testCreateCountForUpdate`
   (an `F2`). *Open:* confirm the compiler's `foreign import` lowering curries an `F2`
   correctly for a 2‑param `.can` signature (the `Native.Module.call` precedent takes 4 args
   and works, `Module.can:76‑78`, so this is very likely fine — verify with `canopy test`).
5. **Test‑build determinism.** E2E needs a test flavor that registers mock Photos/Billing.
   *Open:* the cleanest toggle (a `BuildConfig` flag selecting `canopy.bundle.test.js`, or a
   runtime module‑registry swap). The FAKE billing store already helps; Photos/Notify need a
   deterministic mock module path. Keep `RestoreEngine` real (it's the value).
6. **Idle hook coverage.** `__canopy_idle` (§4.4) covers Cmd + frame queue; it does **not**
   know about a native module still running ML on a worker thread *after* `_NM_pending`
   decrements at dispatch. *Open:* confirm `_NM_pending` stays >0 until `ctx.complete`
   resolves (it should, per the ABI in `mock-native-modules.js:39‑51`); if not, extend the
   idle predicate to count in‑flight native calls.
7. **Symbolication pipeline.** Hermes source maps need a `canopy-native build --sourcemap`
   flag that doesn't exist yet (`Bundle.hs`). *Open:* scope this small tool change; without it
   JS crash frames in the farm are unmapped.
8. **Cost/quota of the farm.** FTL/BrowserStack minutes are finite. *Decision:* matrix runs
   only on `main` + `rc-*` tags (CI `if:` guard, §9.5); PRs get mock‑Fabric + Maestro smoke on
   one local emulator only.

---

## 13. Concrete file manifest (what to create / edit)

**Create**
- `native/package/src/Native/Testing.can` (T1)
- `native/package/res?`/`native/host/android/app/src/main/res/values/ids.xml` (T0)
- `native/harness/lib/report.js`, `native/harness/run-a11y.js` (T2)
- `native/harness/reports/` (output dir, gitignored) (T2)
- `.github/workflows/native-tests.yml` (T2)
- `native/scripts/install-canopy.sh`, `native/scripts/matrix-local.sh`,
  `native/scripts/build-test-apk.sh` (T2/T5)
- `native/e2e/**` — `package.json`, `tsconfig.json`, `wdio.shared/android/ios.conf.ts`,
  `helpers/{driver,app}.ts`, `config/capabilities.ts`, `specs/{smoke,lumen-restore}.e2e.ts`,
  `maestro/lumen-smoke.yaml`, `run-farm.sh` (T3/T4/T5)

**Edit**
- `native/package/src/Native/Attributes.can` — add `accessibilityLabel/Hint/accessible`
  (`:11`,`:35`, new defs) (T0)
- `native/package/canopy.json` — expose `Native.Testing` (`:7‑14`) (T1)
- `native/package/external/native.js` — `testPropValue` + `_Native_isIdle` + exports
  (`:918`,`:932‑948`) (T1/T4)
- `native/host/android/.../CanopyHost.java` — a11y block in `applyProps` + `CView` fields +
  delegate (`:53‑61`,`:192‑223`) (T0)
- `native/host/ios/.../CanopyHostFabric.mm` — a11y block in `applyProps` + `traitsForRole`
  (`:130‑141`) (T0)
- `native/package/tests/Test/Native.can` — add keyed‑reorder + a11y‑prop properties
  (`:21‑27` describe list) (T1)
- `native/harness/run.js`/`run-compiled.js`/`run-echo.js` — switch to `lib/report.js` (T2)
- `native/harness/package.json` — add `test:a11y`, `test:tap` scripts (`:6‑11`) (T2)
- `apps/lumen/app/src/Main.can` — add `A.testID` to status label, before/after, screen roots,
  paywall (`:914`,`:935` precedent) (T3)
- `native/host/android/.../MainActivity.java` + `Bundle.hs` — test‑flavor bundle toggle +
  `--sourcemap` flag (T3/T5)
