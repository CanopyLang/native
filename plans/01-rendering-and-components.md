# Plan 01 — Rendering & Components to RN Parity

Area: **rendering-components**. This is the build reference for bringing Canopy Native's
component/rendering layer up to React Native parity. It is file-level and exhaustive: it cites
the real code as it stands today, specifies the target design, and lists every file to
create/edit with signatures and the JSI/Yoga/JNI/ObjC wiring.

The six deliverables:

- **(a)** a real `ScrollView` (Android `NestedScrollView` over the Yoga content; momentum,
  `contentInset`, `onScroll`, `RefreshControl`).
- **(b)** **List virtualization** — a `FlatList`/`VirtualizedList` equivalent.
- **(c)** the **LIS move-minimization** pass in the keyed reconciler.
- **(d)** a **working `TextInput`** (listeners, focus/blur, keyboard config, secure/multiline).
- **(e)** `Image` from URL/asset/file with `resizeMode`, caching, `onLoad`/`onError`.
- **(f)** a **`Modal`/portal** primitive (top-level overlay, transparent, hardware-back).

The seam discipline is non-negotiable (architecture.md §3, restated at the top of
`external/native.js:17-20`): JS binds **only** to the public `VirtualDom` node shape and the
small `__fabric_*` surface. Everything version-sensitive lives behind `CanopyHost` (Java) /
`CanopyHostIOS` (ObjC). Each deliverable below keeps that line.

---

## 0. Current state (file:line evidence)

### 0.1 The three render seams and the walker
`external/native.js` is the third walker. It mirrors `virtual-dom.js`: `_Native_render`
(`native.js:214`), `_Native_updateTNode` (`native.js:371`), facts→props
(`_Native_factsToProps`, `native.js:160`), unkeyed kids (`_Native_updateKids`, `native.js:558`),
keyed kids (`_Native_updateKeyedKids`, `native.js:600`), the animator (`_Native_makeAnimator`,
`native.js:675`), and the entry point `element` (`native.js:723`). The host surface it drives
is exactly six functions plus two optional: `__fabric_createView/updateProps/insertChild/
removeChild/setRoot` + optional `__fabric_setEvents/requestFrame` (documented `native.js:24-31`,
installed in `CanopyFabric.cpp:46-99`).

The `.can` constructors are thin `VirtualDom.node` wrappers (`Native.can:99-161`):
`view`→`RCTView`, `column`/`row`→`RCTView`+flexDirection, `text`→`RCTText`,
`scroll`→`RCTScrollView`, `image`→`RCTImageView`, `textInput`→`RCTSinglelineTextInputView`,
`pressable`→`RCTView`+accessibilityRole.

### 0.2 ScrollView — a NON-scrolling stub
`Native.scroll` produces a `RCTScrollView` node (`Native.can:133-135`), but the host maps
**every** non-leaf tag to a plain `YogaViewGroup` — the `default:` branch of `makeView`
(`CanopyHost.java:185-187`), whose comment literally says `RCTScrollView (scroll deferred)`.
A `YogaViewGroup` has no scroll behavior, no `onScroll`, no momentum, no overscroll, no
`RefreshControl`. iOS at least constructs a `UIScrollView` (`CanopyHostFabric.mm:124`) but
never sets `contentSize`, so it also will not scroll.

### 0.3 List virtualization — absent
There is no `FlatList`/`VirtualizedList` anywhere. `Native.can` exposes no list primitive.
A long list today is N keyed children all mounted at once, reconciled by
`_Native_updateKeyedKids` (`native.js:600`) — every cell is a live `android.view`. The
web side already ships a **headless windowing engine**, `canopy/virtual-list`
(`virtual-list/src/VirtualList.can`), with `compute`/`VirtualRange`/`ItemHeight(Fixed|Variable
|Dynamic)`/overscan (`VirtualList.can:1-18, 263-318`) — but it depends on `canopy/html` +
`canopy/browser` (`virtual-list/canopy.json`), so it cannot be imported by a Native app as-is.

### 0.4 Keyed reconciler — correct but NOT move-minimal
`_Native_updateKeyedKids` (`native.js:600-657`) matches keys, recycles orphans, then **detaches
and re-inserts every child in order** (`native.js:651-655`): "move-minimization is a later
optimization." For a reorder of N rows that is N host `insertChild` ops (each a real
`ViewGroup.removeView`+`addView` on Android, `CanopyHost.java:103-116`). The web walker already
solved this with an O(n log n) LIS pass: `_VirtualDom_lisIndices` (`virtual-dom.js:2416`) +
the right-to-left move loop (`virtual-dom.js:2698-2728`). We mirror that.

### 0.5 TextInput — inert
`Native.textInput` makes an `RCTSinglelineTextInputView` (`Native.can:147-149`), the host
makes a bare `EditText` (`CanopyHost.java:179`). But:
- `setEvents` (`CanopyHost.java:135-158`) only wires `press`/`pan`/`tap`/`doubleTap`. There is
  **no** `addTextChangedListener`, no `setOnEditorActionListener`, no focus listener — so
  `changeText`/`submitEditing`/`focus`/`blur` (declared in `_Native_KNOWN_EVENTS`,
  `native.js:50-54`, and in `Native.Events.onChangeText`/`onSubmitEditing`,
  `Events.can:70-79`) never fire.
- `applyProps` (`CanopyHost.java:192-224`) handles `text` for any `TextView` but never reads
  `placeholder`/`value`/`editable` (the attrs exist in `Attributes.can:302-320`), and there is
  no `secureTextEntry`/`keyboardType`/`multiline`/`returnKeyType`/`autoFocus` path at all.
- Setting `text` on the `EditText` every render (`CanopyHost.java:200-202`) would fight the
  user's cursor; there is no controlled-input reconciliation.

### 0.6 Image — cannot load a URL/asset/file
`Native.image`→`RCTImageView`→a bare `ImageView` (`CanopyHost.java:177-178`). `applyProps`
only ever sets a bitmap via `bitmapHandle` from the blob registry
(`CanopyHost.java:205-210`) — the `canopy/image` zero-copy path (`Image.can:220-229`,
`ImageModule.java`). The `source` attribute exists (`Attributes.can:297-299`) and rides through
as a plain prop, but **nothing reads it**: no URL fetch, no file/asset decode into the view, no
`resizeMode`, no `onLoad`/`onError`, no cache. There is no Glide/Coil dependency.

### 0.7 Modal/portal — absent
No `Modal`. Every view mounts under the single root surface (`CanopyHost.setRoot`,
`CanopyHost.java:127-133`, adds one root to a `FrameLayout`). There is no overlay window, no
top-level portal, no `onRequestClose`/hardware-back integration for a dialog.

### 0.8 The event + relayout plumbing (shared by all deliverables)
- Events go out via `CanopyHostJni.emitEvent(handle, name, payloadJson)`
  (`CanopyHostJni.java:34`) → JNI `Java_..._emitEvent` (`CanopyHostJni.cpp:249`) →
  `canopyEmitEvent` (`CanopyFabric.cpp:101`) → `__canopy_dispatchEvent` →
  `_Native_dispatchEvent` (`native.js:104`) → the registered decoder.
- The walker announces the event-name set both via `__fabric_setEvents` and an `__events`
  prop (`native.js:197-200`); the host re-runs `setEvents` when `__events` changes on a diff
  (`CanopyHost.java:222`).
- Any layout-affecting change calls `requestRelayout()` (`CanopyHost.java:463-468`), which
  re-runs the root's measure pass; the `YogaViewGroup` computes the whole tree in `onMeasure`
  (`CanopyHost.java:424-445`) and positions children in `onLayout` (`CanopyHost.java:447-458`).
- The JS thread == the Android main/UI thread (the worker→JS hop in `CanopyHostJni.java:48-58`),
  so every `__fabric_*` call already runs where it is safe to touch `android.view`.

---

## 1. Cross-cutting design decisions (apply to all six)

1. **New Fabric component tags, not overloaded `RCTView`.** Each new primitive gets a distinct
   tag so `makeView`/`isLeaf` can branch and the iOS host can mirror:
   `RCTScrollView` (now real), `CanopyVirtualList`, `RCTSinglelineTextInputView` +
   `RCTMultilineTextInputView`, `RCTImageView` (now URL-capable), `CanopyModalHost`.
2. **Plain props carry config; `style` carries layout/visual; `a__1_EVENT` carries handlers.**
   This matches the existing fact buckets read in `_Native_factsToProps` (`native.js:160-204`).
   New per-component config (e.g. `keyboardType`, `resizeMode`, `transparent`) are plain
   `VirtualDom.attribute`/`VirtualDom.property` facts, so they flow through the walker with **no
   walker change** unless the component needs special create/diff handling.
3. **The host JSON wire is the contract.** Every new prop/event is documented as a wire shape
   at the top of its host file, exactly like `ImageModule.java:20-26` and `BeforeAfterView.java
   :23-31`. The mock-fabric harness (`harness/mock-fabric.js`) asserts against the same shapes.
4. **Effort markers** S<½d, M≈1-2d, L≈3-5d, XL≈1-2wk (Android only; iOS multiplies once the
   project exists — see §9).
5. **iOS is blocked on project bring-up.** `host/ios` is two loose `.mm` files with no Xcode
   project (`CanopyHostFabric.mm`, `CanopyHostViewController.mm`). Every iOS sketch below is
   written so it drops into `CanopyHostFabric.mm`'s `makeView`/`applyProps`/`applyFrames` once
   the project from Plan 08 (host/DX) exists. Where a piece is genuinely blocked, it is flagged
   **[iOS-BLOCKED-ON-PROJECT]**.

---

## 2. Deliverable (c) FIRST — LIS move-minimization in the keyed reconciler

Ordered first because virtualization (b) and any list-heavy screen depend on cheap reorders,
and it is a pure-JS change provable in the harness today with **zero host or device work**.

### 2.1 Target
Replace the detach-all/reinsert-all tail of `_Native_updateKeyedKids` (`native.js:651-655`)
with the web walker's algorithm: build the desired order, compute the LIS of the
already-correct subsequence, and emit `insertChild` **only** for nodes not in the LIS, plus
fresh nodes — right-to-left so anchor indices stay valid.

### 2.2 native.js changes (`external/native.js`)
- **Add** `_Native_lisIndices(arr)` — a verbatim port of `_VirtualDom_lisIndices`
  (`virtual-dom.js:2416-2443`). It is self-contained (patience sort + parent chain, returns a
  `Set` of kept indices). Place it just above `_Native_updateKeyedKids`.
- **Rewrite the reorder tail** of `_Native_updateKeyedKids` (currently `native.js:651-656`).
  The match/recycle/orphan-removal passes (`native.js:604-649`) stay. After `newN` is built,
  compute each entry's *prior* index:
  - Build `handleToOldIndex`: map each `oldN[i].__handle` → `i` (the current child order under
    `parent`). Fresh/recycled-into-new nodes whose handle was not previously a direct child get
    index `-1`.
  - `var lis = _Native_lisIndices(oldIndices)`.
  - Right-to-left over `newN`: if `i ∈ lis` skip; else `insertChild(parent, newN[i].__handle, i)`.
    Because the host's `insertChild` already removes the child from its current parent slot and
    re-inserts at the target index (`CanopyHost.java:103-116`; `mock-fabric.js` same), a single
    `insertChild` per moved node is a true move. This is index-addressed, matching the
    `__fabric_insertChild(parent, child, index)` contract — simpler than the DOM walker's
    anchor-node form because the host addresses by index, not sibling reference.
- Keep the `nNode.__kids = newN` assignment (`native.js:656`).
- **Optional fast paths** (also from the web walker, big constant-factor wins, all pure JS):
  - *Same-length same-order* (`virtual-dom.js:2542-2557`): if `xLen===yLen` and every key
    matches positionally, update in place, **zero** inserts. This is the common "list content
    changed, order didn't" case (a `FlatList` re-render).
  - *Trim-from-front* (`virtual-dom.js:2518-2536`): pure remove of a head run.
  These guard the LIS pass from running on the hot path.

### 2.3 Host changes
**None.** The host already treats `insertChild` of an existing child as a move
(`CanopyHost.java:103-110` removes from the old owner first; iOS `CanopyHostFabric.mm:77-88`
does the same with `removeFromSuperview`/`YGNodeRemoveChild`). This is purely a reduction in
the *number* of `__fabric_insertChild` calls the walker emits.

### 2.4 Testing
Extend the test harness section of `native.js` (the `_test_*` block, `native.js:792-923`). Add
`testInsertCountForUpdate(old,new)` mirroring `testCreateCountForUpdate` (`native.js:882`) but
counting `op==='insertChild'`. Assert: a reverse of 10 keyed rows emits **≤ N−LIS** inserts
(for a full reverse, N−1), a single-row move emits **1**, a same-order content change emits
**0**. Drive it from `harness/run.js`.

**Effort: M.** **iOS: no work** (host-agnostic).

---

## 3. Deliverable (a) — a REAL ScrollView

### 3.1 Target design (RN parity surface)
`RCTScrollView` becomes a scrolling viewport that:
- scrolls its single Yoga-laid-out content child (vertical default; horizontal opt-in),
- emits `onScroll` with `{contentOffset:{x,y}, contentSize:{w,h}, layoutMeasurement:{w,h}}`
  (RN's shape, the exact fields `VirtualList.ScrollEvent` wants: `scrollTop`/`scrollHeight`/
  `clientHeight`, `VirtualList.can:206-219`),
- supports `onScrollBeginDrag`/`onScrollEndDrag`/`onMomentumScrollBegin`/`onMomentumScrollEnd`,
- honors `horizontal`, `showsScrollIndicator`, `scrollEnabled`, `contentInset`,
  `contentContainerStyle`, `pagingEnabled`,
- hosts a pull-to-refresh `RefreshControl` (`refreshing`+`onRefresh`).

### 3.2 How Yoga measure composes with a scroll viewport (the key design point)
The viewport view has a **fixed** outer size (from flex/explicit style — the visible window).
Its **content** is a single inner `YogaViewGroup` that is allowed to grow unbounded on the
scroll axis. Concretely, on the scroll axis the content child is measured with an
`UNSPECIFIED` Yoga measure mode so it takes its natural (full) height, while the viewport
itself clamps to its own resolved frame. The Android `NestedScrollView` then scrolls the inner
content within the outer bounds — this is exactly how RN's `RCTScrollView` wraps an
`RCTScrollContentView`. So the model is: **outer Yoga node = the bounded viewport; one inner
Yoga node = the unbounded content; the platform scroller bridges them.**

### 3.3 `.can` API (`Native.can` + a new `Native/Scroll.can`)
Keep `Native.scroll` (`Native.can:133-135`) as the no-frills constructor. Add a richer module
`Native/Scroll.can` exposing typed config + the event:
```
module Native.Scroll exposing
    ( scroll, ScrollEvent, onScroll, onMomentumEnd
    , horizontal, scrollEnabled, showsIndicator, pagingEnabled
    , contentInset, RefreshControl, refreshControl
    )
scroll : List (Attribute msg) -> List (Node msg) -> Node msg          -- VirtualDom.node "RCTScrollView"
type alias ScrollEvent = { x : Float, y : Float, contentWidth : Float
                         , contentHeight : Float, viewportWidth : Float, viewportHeight : Float }
onScroll : (ScrollEvent -> msg) -> Attribute msg     -- VirtualDom.on "scroll" (Normal scrollDecoder)
onMomentumEnd : (ScrollEvent -> msg) -> Attribute msg
horizontal : Bool -> Attribute msg                   -- VirtualDom.property "horizontal" (Encode.bool b)
scrollEnabled : Bool -> Attribute msg
showsIndicator : Bool -> Attribute msg
pagingEnabled : Bool -> Attribute msg
contentInset : { top:Int,bottom:Int,left:Int,right:Int } -> Attribute msg  -- property, encoded object
refreshControl : Bool -> msg -> Attribute msg        -- two facts: property "refreshing" + on "refresh"
```
Add `scroll`/`onScroll`/`ScrollEvent` to `Native.can`'s `exposing` for convenience re-export.
`scrollDecoder` lives in `Native/Scroll.can` and decodes the wire shape in §3.1.

### 3.4 native.js (walker) changes
**Almost none.** `horizontal`/`scrollEnabled`/`contentInset`/`refreshing` are plain props →
already flow through `_Native_factsToProps`/`_Native_plain` unchanged. `scroll`/`refresh`/
`momentumEnd` events are already in the known-events flow (`scroll` is in `_Native_KNOWN_EVENTS`,
`native.js:53`; the `|| true` at `native.js:195` already lets any event through). Add the new
event names (`momentumScrollEnd`, `scrollBeginDrag`, `scrollEndDrag`, `refresh`) to
`_Native_KNOWN_EVENTS` (`native.js:50-54`) for documentation parity. **One real change:** the
content-container wrapping is done host-side (§3.5), so the walker still emits children as
direct kids of the `RCTScrollView` handle — no change to `_Native_renderElement`.

### 3.5 Android host changes (`CanopyHost.java`)
- `isLeaf` (`CanopyHost.java:162-170`): leave `RCTScrollView` a non-leaf (it has children).
- `makeView` (`CanopyHost.java:172-188`): add `case "RCTScrollView": return makeScrollView();`.
  `makeScrollView()` builds a new `com.canopyhost.views.CanopyScrollView` (NEW FILE, §3.6) and
  returns it. The view internally owns a single inner `YogaViewGroup` content host.
- The CView needs to know "my Yoga children go on the inner content node, my view children go
  in the inner content view." Two clean options; pick **Option A** (less invasive):
  - **Option A — scroll view *is* the Yoga container, inner content view is a plain
    `LinearLayout`-free passthrough.** The `CanopyScrollView extends NestedScrollView` holds
    one child `YogaViewGroup content`. Override `insertChild`/`removeChild` in `CanopyHost` so
    that when `p.view instanceof CanopyScrollView`, children are added to `scroll.content()`
    (both the `android.view` and the Yoga node parented to the *content's* YogaNode). The
    scroll view's own `CView.yoga` is the bounded outer node; the content's YogaNode is a child
    of it sized `flexGrow:0` on the scroll axis with `UNSPECIFIED` height. Wire this with a
    `cv.contentYoga`/`cv.contentView` pair on `CView` (`CanopyHost.java:53-61`).
- `applyProps` (`CanopyHost.java:192-224`): add a block `if (cv.view instanceof CanopyScrollView)`
  reading `horizontal`/`scrollEnabled`/`pagingEnabled`/`contentInset`/`refreshing`, forwarding
  to the view's setters.
- `setEvents` (`CanopyHost.java:135-158`): add handling so when the names array contains
  `scroll`/`momentumScrollEnd`/`refresh`, the `CanopyScrollView` is told to emit them (it owns
  its own `OnScrollChangeListener` + `SwipeRefreshLayout` callback; not the generic
  `CanopyGestures`).

### 3.6 NEW FILE: `host/android/.../views/CanopyScrollView.java`
```
public final class CanopyScrollView extends androidx.core.widget.NestedScrollView {
  // owns: SwipeRefreshLayout refresh (optional wrapper), YogaViewGroup content (the single child).
  // public:
  //   ViewGroup content()                         -> the inner Yoga content host children mount into
  //   void setHorizontal(boolean)                 -> swap to a HorizontalScrollView path (see note)
  //   void setScrollEnabled(boolean)
  //   void setContentInset(int t,int b,int l,int r) -> setPadding on content + clipToPadding(false)
  //   void setRefreshing(boolean), void setEmitEvents(int handle, boolean scroll, boolean refresh)
  // emits: on scroll → throttled (every ~16ms / when delta>1px) CanopyHostJni.emitEvent(handle,
  //        "scroll", "{\"x\":..,\"y\":..,\"contentWidth\":..,\"contentHeight\":..,
  //        \"viewportWidth\":..,\"viewportHeight\":..}"). dp-normalize offsets/sizes (/density).
  //   onScrollStateChanged-equivalent: NestedScrollView has setOnScrollChangeListener; detect
  //        momentum end via a 100ms "settled" debounce → emit "momentumScrollEnd".
}
```
Notes:
- **Vertical vs horizontal.** `NestedScrollView` is vertical-only. For `horizontal:true` build
  a `HorizontalScrollView`-backed variant; cleanest is one wrapper class that delegates to a
  vertical `NestedScrollView` or a `HorizontalScrollView` chosen at first `setHorizontal`. For
  the Lumen vertical-feed use case, ship vertical first (M), horizontal second (S).
- **RefreshControl.** Wrap the content in `androidx.swiperefreshlayout.widget.SwipeRefreshLayout`
  when `refreshControl` is present; `setOnRefreshListener` → emit `refresh`; `setRefreshing` is
  driven by the `refreshing` prop. Add the `androidx.swiperefreshlayout:swiperefreshlayout`
  dependency to `app/build.gradle`.
- **Yoga measure of content.** In `CanopyScrollView`, when laying out the content child, the
  content `YogaViewGroup` must compute with an UNSPECIFIED height on the scroll axis. Reuse the
  `YogaViewGroup.onMeasure` path (`CanopyHost.java:424-445`) but pass `YogaConstants.UNDEFINED`
  for the scroll-axis dimension so the content takes its full natural height; the
  `NestedScrollView` provides the clipping viewport. This is the literal expression of §3.2.

### 3.7 iOS sketch (`CanopyHostFabric.mm`)
- `makeView` (`CanopyHostFabric.mm:118-128`) already returns `UIScrollView` for `RCTScrollView`.
  In `applyFrames` (`CanopyHostFabric.mm:171-179`) set `scrollView.contentSize` from the
  content Yoga node's natural size (compute content with `YGUndefined` height like §3.6).
- `applyProps`: map `horizontal`→`alwaysBounceHorizontal`/axis, `scrollEnabled`,
  `contentInset`→`UIEdgeInsets`, `pagingEnabled`. Add a `UIScrollViewDelegate` whose
  `scrollViewDidScroll:`/`scrollViewDidEndDecelerating:` call `canopyEmitEvent` (needs the
  runtime pointer the host must hold — same TODO as `CanopyHostFabric.mm:104-110`).
- `RefreshControl` → `UIRefreshControl` on the scroll view; `valueChanged` → emit `refresh`.
- **[iOS-BLOCKED-ON-PROJECT]** for device validation; the code drops into the existing host.

**Effort: L (Android vertical + refresh), +S horizontal.**

---

## 4. Deliverable (b) — List virtualization (FlatList / VirtualizedList)

### 4.1 Architecture decision: **JS-driven windowing over the real ScrollView** (not a
native RecyclerView host component).

Rationale, grounded in this codebase:
- The walker's reconciler is already a precise diff engine that re-mounts nothing on content
  change (the `text` fast-path `native.js:276-282`, keyed recycling `native.js:600`). With the
  LIS pass (§2) a window slide is a handful of host ops. A JS-windowed list is therefore cheap
  *and* keeps the entire cell-rendering path in ordinary Canopy `view` code — no new ABI, no
  keyed-data protocol to design, no second reconciler living in Java.
- A native `RecyclerView` host component would require shipping cell *data* (not views) across
  the ABI and re-implementing cell rendering in Java/ObjC twice — that breaks the "render the
  same VirtualDom three ways" thesis and duplicates the reconciler. We explicitly reject it for
  v1. (It stays an option for 100k-row infinite feeds; noted in §11.)
- The headless windowing math **already exists and is reusable**: `canopy/virtual-list`'s
  `compute`/`VirtualRange`/`ItemHeight` (`VirtualList.can:263-318`) is pure value code. The
  only thing tying it to the web is the `Html`/`Html.Keyed` *rendering* helpers and the
  `Html.Events` scroll decoder (`virtual-list/canopy.json` deps). We reuse the **math**,
  re-back the **render** onto `Native`.

### 4.2 The component: `Native.List` (a `FlatList` equivalent) backed by `Native.Scroll`
A `Native.List` is: a `Native.Scroll.scroll` viewport (§3) + a content column whose total
height is forced to `totalHeight` + a **keyed** set of only the windowed rows, each absolutely
positioned at its computed `offset`. On `onScroll`, the app stores the offset and re-renders;
the walker diffs the keyed window — rows entering/leaving the window are the only inserts/
removes, and the LIS pass keeps the survivors in place. This is `FlatList` semantics: windowed,
recycled (by key), with overscan.

Two integration shapes, ship both:
- **Headless (`Native.List` over `Native.Scroll`)** — gives `getItemLayout`-equivalent
  (`ItemHeight Fixed`/`Variable`), `onEndReached`, `keyExtractor`, overscan, all in Canopy.
- **Absolute-position content** — each windowed row is wrapped in a `Native.view` with
  `A.position "absolute"`, `A.top offset`, `A.height size`, `A.left 0`, `A.right 0`. The
  content host has `A.height totalHeight` so the scrollbar is correct. (`position:absolute` +
  per-edge `top` already work in the host: `CanopyHost.java:262-267`.)

### 4.3 `.can` API: NEW package `canopy/native-list` OR a `Native/List.can` module
Recommended: a module **inside `canopy/native`** so it has no extra package install
(the effect-module install gap from MEMORY does not apply — this is pure value + view code).
Port the windowing math by **vendoring the pure functions** from `VirtualList.can` (the
`compute`/`computeRange`/`findStartIndex`/`findEndIndex`/`buildItems`/prefix-sum helpers,
`VirtualList.can:263-360+`) into `Native/List/Window.can`, dropping the `Html` imports.
```
module Native.List exposing
    ( State, init, Config, ItemHeight(..), onScroll
    , view, viewKeyed, onEndReached )

type alias Config data msg =
    { items : Array data
    , itemHeight : ItemHeight data        -- Fixed Float | Variable (data->Float)
    , viewportHeight : Float
    , overscan : Int
    , keyExtractor : data -> String       -- FlatList keyExtractor
    , renderItem : data -> Native.Node msg
    , onScroll : Native.Scroll.ScrollEvent -> msg
    , onEndReached : Maybe msg            -- fired when within `endThreshold` of bottom
    , scrollState : State }

view : Config data msg -> Native.Node msg
```
`view` = `Native.Scroll.scroll [ onScroll, style fill ] [ contentColumn ]`, where
`contentColumn` is a `VirtualDom.keyedNode "RCTView"` of the windowed rows (keyed so the
reconciler recycles) sized to `totalHeight`, each row absolutely positioned. `onEndReached`
fires from the scroll handler when `y + viewportHeight >= totalHeight - threshold` (the
`isAtBottom` logic, `VirtualList.can:128-141`).

### 4.4 native.js (walker) changes
**None for the headless path** — `Native.List` produces ordinary keyed `RCTView`/`RCTText`
nodes the existing walker already renders/diffs. The LIS pass (§2) is what makes window slides
cheap. (If profiling later shows the per-frame re-render of `view(model)` is too heavy because
the *whole* tree is rebuilt each scroll, the fix is the existing thunk/`lazy` mechanism
`native.js:216-218,353-363`, not a walker change.)

### 4.5 Host changes
**None beyond §3 (ScrollView).** Virtualization is entirely JS + `Native.Scroll`. This is the
payoff of choosing JS-windowing: the host work is just "have a real ScrollView."

### 4.6 onScroll throttle + jank note
The scroll→`update`→re-render→diff round-trip happens per scroll event. To avoid TEA-loop
thrash, the `CanopyScrollView` throttles `scroll` emits to ~1/frame (§3.6). The window only
changes when the offset crosses a row boundary, so most frames diff to an identical window
(the same-order fast path §2.2 → **0** host ops). This is acceptable for Lumen's feed; for a
fling over 10k rows, add the optional native pre-scroll content sizing in §11.

### 4.7 iOS
Same — `Native.List` is host-agnostic; it needs only the iOS ScrollView from §3.7.
**[iOS-BLOCKED-ON-PROJECT]** for validation only.

### 4.8 Testing
- Harness unit (`native.js` `_test_*`): render a `Native.List` of 1000 items with
  `viewportHeight` for ~10 visible + overscan; assert the rendered tree has only ~10–14
  `RCTView` rows (not 1000). Simulate a `scroll` event by feeding a new `scrollState` and
  re-rendering; assert the create count for the slide is ≤ (rows entering window), and the
  insert count (LIS) is minimal.
- Device E2E: a screen-capture of a scrolling list + `uiautomator dump` to confirm only
  windowed rows exist in the view hierarchy.

**Effort: L (depends on §2 + §3).** Windowing math reuse saves ~½ of it.

---

## 5. Deliverable (d) — a working TextInput

### 5.1 Target (RN parity)
- Events back to Canopy: `changeText {text}`, `submitEditing`, `focus`, `blur`, `keyPress`
  (optional), `endEditing {text}`.
- Props in: `value` (controlled), `placeholder`, `placeholderTextColor`, `editable`,
  `secureTextEntry`, `keyboardType` (default/numeric/email-address/phone-pad/decimal-pad),
  `returnKeyType` (done/go/next/search/send), `autoCapitalize`, `autoCorrect`, `autoFocus`,
  `maxLength`, `multiline` (→ a distinct `RCTMultilineTextInputView`), `selectionColor`,
  `numberOfLines`.

### 5.2 `.can` API additions
`Native.can`: keep `textInput`→`RCTSinglelineTextInputView` (`Native.can:147-149`); add
`textArea`→`RCTMultilineTextInputView`.
`Native/Attributes.can` (extend `exposing` `Attributes.can:1-12`): add plain-prop helpers
```
secureTextEntry : Bool -> Attribute msg        -- VirtualDom.attribute "secureTextEntry" "true"/"false"
keyboardType : String -> Attribute msg         -- attribute "keyboardType"
returnKeyType : String -> Attribute msg
autoCapitalize : String -> Attribute msg
autoFocus : Bool -> Attribute msg
maxLength : Int -> Attribute msg
multiline : Bool -> Attribute msg
placeholderTextColor : String -> Attribute msg
```
`Native/Events.can` (extend `Events.can:1-7`): `onChangeText`/`onSubmitEditing` exist
(`Events.can:70-79`); add
```
onFocus : msg -> Attribute msg            -- VirtualDom.on "focus" (Normal (Decode.succeed msg))
onBlur : msg -> Attribute msg
onEndEditing : (String -> msg) -> Attribute msg   -- decode {text}
```

### 5.3 native.js (walker) changes — the controlled-input subtlety
- `focus`/`blur`/`endEditing` already pass through the event flow (`focus`/`blur` are in
  `_Native_KNOWN_EVENTS`, `native.js:52-53`). Add `keyPress`/`endEditing` there for parity.
- **Controlled value reconciliation.** The walker must not re-push `value` to the host on every
  keystroke-driven re-render if the host already has that exact string (it would yank the
  cursor). Two clean options:
  - **Host-side guard (preferred, zero walker change):** the host's `applyProps` compares the
    incoming `value` to the `EditText`'s current text and skips `setText` if equal *and* only
    sets selection to the end when it does change (see §5.4). This keeps the walker pure and is
    how RN's Android `ReactEditText` does it (it tracks an event counter; we approximate with
    string equality which is sufficient for Canopy's synchronous TEA value).
  So: **no walker change required** for controlled inputs beyond letting `value` flow as a plain
  prop (it already does, `Attributes.can:307-309` → `_Native_plain`).

### 5.4 Android host changes (`CanopyHost.java`)
- `isLeaf` (`CanopyHost.java:162-170`): add `RCTMultilineTextInputView` to the leaf set
  (text inputs size themselves) alongside the existing `RCTSinglelineTextInputView`.
- `makeView` (`CanopyHost.java:172-188`): `case "RCTMultilineTextInputView":` → an `EditText`
  with `setSingleLine(false)`, `setGravity(TOP|START)`, `inputType |= TYPE_TEXT_FLAG_MULTI_LINE`.
- `applyProps` (`CanopyHost.java:192-224`): add a `cv.view instanceof EditText` block (must run
  **before** the generic `TextView` `text` handler, or special-case it):
  - `value` → guarded `setText` (skip if equal; on change, `setSelection(len)`); the existing
    `text` branch (`CanopyHost.java:200-202`) must be made to **ignore `EditText`** so controlled
    inputs use `value`, not `text`.
  - `placeholder` → `setHint`; `placeholderTextColor` → `setHintTextColor`.
  - `editable` → `setEnabled`/`setFocusable`.
  - `secureTextEntry` → `setInputType(TYPE_CLASS_TEXT | TYPE_TEXT_VARIATION_PASSWORD)` +
    `setTransformationMethod(PasswordTransformationMethod)`.
  - `keyboardType` → map to `InputType` (numeric→`TYPE_CLASS_NUMBER`, email→
    `TYPE_TEXT_VARIATION_EMAIL_ADDRESS`, phone-pad→`TYPE_CLASS_PHONE`, decimal-pad→
    `TYPE_NUMBER_FLAG_DECIMAL`).
  - `returnKeyType` → `setImeOptions` (done→`IME_ACTION_DONE`, etc.).
  - `autoCapitalize` → `TYPE_TEXT_FLAG_CAP_*`; `autoCorrect`→`TYPE_TEXT_FLAG_NO_SUGGESTIONS`.
  - `maxLength` → `setFilters(new InputFilter.LengthFilter(n))`.
  - `autoFocus` → `requestFocus()` + show the IME via `InputMethodManager` once attached.
  - Any input-type/content change → `cv.yoga.dirty()` (leaf re-measure), as the existing text
    path does (`CanopyHost.java:202`).
- `setEvents` (`CanopyHost.java:135-158`): when the names array contains text events, install
  listeners on the `EditText` (idempotent: detach prior ones first, mirroring the press
  teardown `CanopyHost.java:142-147`):
  - `changeText` → `addTextChangedListener` whose `afterTextChanged` emits
    `emitEvent(h,"changeText","{\"text\":<escaped>}")`. **Guard against echo:** when the host
    sets `value` programmatically (§5.4 `setText`), set a `suppressWatcher` flag so the watcher
    does not re-emit the change it just applied.
  - `submitEditing` → `setOnEditorActionListener` emitting `submitEditing` on `IME_ACTION_*`/
    enter.
  - `focus`/`blur` → `setOnFocusChangeListener` emitting `focus`/`blur`.
  - `endEditing` → emit on focus-loss with the current text.
  - JSON-escape the text payload (a NEW small `jsonEscape(String)` helper on `CanopyHost`, since
    the current emitters only send `{}`/numeric payloads, `CanopyGestures.java:152-156`).

### 5.5 iOS sketch (`CanopyHostFabric.mm`)
- `makeView` already returns `UITextField` for `RCTSinglelineTextInputView`
  (`CanopyHostFabric.mm:126`); add `UITextView` for `RCTMultilineTextInputView`.
- `applyProps`: `placeholder`→`placeholder`/`attributedPlaceholder`(+color); `secureTextEntry`→
  `secureTextEntry`; `keyboardType`/`returnKeyType`→`UIKeyboardType`/`UIReturnKeyType`;
  `value`→guarded `.text`; `editable`→`enabled`/`editable`; `autoFocus`→`becomeFirstResponder`.
- Events: a `UITextFieldDelegate`/`UITextViewDelegate` (`textFieldDidChange`→`changeText`,
  `textFieldShouldReturn`→`submitEditing`, `DidBeginEditing`/`DidEndEditing`→`focus`/`blur`),
  each calling `canopyEmitEvent`. **[iOS-BLOCKED-ON-PROJECT]** (needs the runtime pointer the
  host must retain — same gap as `CanopyHostFabric.mm:104-110`).

### 5.6 Testing
- Harness: `native.js` `_test_*` — render a `textInput [value "hi", onChangeText …]`, assert the
  Fabric props carry `value:"hi"` + `__events` includes `changeText`. Add a mock that simulates
  the host emitting `changeText {text:"hix"}` → assert the decoded msg reaches the app sink
  (extend `mock-fabric.js` with an `emit(handle,name,payload)` that routes through
  `_Native_dispatchEvent`, `native.js:104`).
- Device E2E: a `testID`-tagged input (depends on Plan 08 making `testID` real); type via
  `uiautomator`/`adb input text`, assert the model updated by reading a label that echoes it.

**Effort: L.** **iOS: M once project exists.**

---

## 6. Deliverable (e) — Image from URL / asset / file (with cache, resizeMode, onLoad/onError)

### 6.1 Distinct from the existing blob path
Keep the zero-copy `CanopyBitmap`/`bitmapHandle` path (`Image.can:220-229`,
`CanopyHost.java:205-210`) untouched — it is for native-produced pixels (decode/restore output).
This deliverable adds the **declarative `source`** path for `RCTImageView`: load a URL/asset/
file *by string*, with caching and load callbacks, the way RN's `<Image source={{uri}}>` works.

### 6.2 Android: back `RCTImageView` with Coil
- Add `io.coil-kt:coil` to `app/build.gradle` (Kotlin-free Java-callable API; Glide is the
  alternative — Coil is lighter and modern). Coil gives memory+disk caching, downsampling to
  the target view size, and `onSuccess`/`onError` callbacks for free.
- `Native.can`: `image` stays `RCTImageView` (`Native.can:140-142`).
- `Native/Attributes.can`: `source` exists (`Attributes.can:297-299`); add
  `resizeMode : String -> Attribute msg` (cover/contain/stretch/center → maps to
  `ImageView.ScaleType`). Document `source` URI schemes: `http(s)://`, `file://`, `asset:NAME`,
  `content://`.
- `Native/Events.can`: add `onLoad : msg` / `onError : (String->msg)` (decode `{error}`); also
  `onLoadEnd`. (These are new event names — they ride the generic event flow.)

`CanopyHost.java` changes:
- `applyProps` (`CanopyHost.java:192-224`): in the `RCTImageView` path, when `source` is present
  (and `bitmapHandle` is not), call `loadSource(cv, uri)`:
  - parse scheme; for `http(s)` hand to Coil's `ImageLoader.enqueue(ImageRequest)`, target the
    `ImageView`; on success → `emitEvent(h,"load","{}")` + `cv.yoga.dirty()`; on error →
    `emitEvent(h,"error","{\"error\":<msg>}")`. asset/file/content go through Coil's data
    sources too (it accepts `Uri`/`File`/asset paths).
  - guard: only reload when the `source` string actually changes (store `cv.lastSource`).
- `resizeMode` in `applyStyle` or `applyProps` → `ImageView.setScaleType` (cover→`CENTER_CROP`,
  contain→`FIT_CENTER`, stretch→`FIT_XY`, center→`CENTER`).
- Add `lastSource`/`scaleType` fields to `CView` (`CanopyHost.java:53-61`).
- `setEvents`: `load`/`error`/`loadEnd` need no listener wiring (Coil fires them inline in
  `loadSource`), but the host must remember which events the node wants so it only emits
  requested ones — store a small per-handle event-name set (reuse the `__events` already
  applied in `applyProps`, `CanopyHost.java:222`).

### 6.3 native.js (walker) changes
**None.** `source`/`resizeMode` are plain/style facts; `load`/`error`/`loadEnd` ride the
generic event path (the `|| true` admit at `native.js:195`). Optionally add them to
`_Native_KNOWN_EVENTS` (`native.js:50-54`) for documentation.

### 6.4 Caching
Coil's `ImageLoader` carries an in-memory `MemoryCache` + a disk `DiskCache` by default; expose
nothing to Canopy beyond the implicit cache. A single shared `ImageLoader` is built once
(lazy static in a NEW `views/CanopyImageLoader.java` or inline in `CanopyHost`) so the cache is
process-wide. This is the RN-Image behavior (URL dedup + cache).

### 6.5 iOS sketch
- `RCTImageView`→`UIImageView` (`CanopyHostFabric.mm:125`). For `source`:
  - `asset:`/`file:`→`UIImage(contentsOfFile:)`/named; `http(s)`→an async `URLSession` data task
    (or SDWebImage if a pod is added) setting `.image` on completion + emitting `load`/`error`.
  - `resizeMode`→`contentMode` (cover→`scaleAspectFill`+`clipsToBounds`, contain→
    `scaleAspectFit`, stretch→`scaleToFill`, center→`center`).
- **[iOS-BLOCKED-ON-PROJECT]** for the URL task validation; the synchronous file/asset path
  drops in immediately.

### 6.6 Testing
- Harness: render `image [source "asset:x.png", resizeMode "contain", onLoad Loaded]`; assert
  props carry `source` + `__events` has `load`. (Actual decode can't run in Node; the harness
  asserts the *wire*, the device asserts the *pixels*.)
- Device E2E: load `asset:lumen-test.jpg` (already in assets, see
  `host/android/.../assets/lumen-test.jpg`), screen-capture to confirm it renders with the right
  scale type; a deliberately-bad URL to confirm `onError` fires (assert via an error label).

**Effort: M (Android).** **iOS: M once project + http path.**

---

## 7. Deliverable (f) — Modal / portal primitive

### 7.1 Target
A top-level overlay that escapes the normal Yoga tree: `transparent`, full-screen or centered
content, dim backdrop, `visible` toggle, `onRequestClose` (hardware back / backdrop tap),
`animationType` (none/fade/slide). RN parity for dialogs, sheets, the Lumen paywall.

### 7.2 Architecture: a host-managed overlay, mounted off-tree
A `Modal` node renders to a `CanopyModalHost` Fabric view that is **not** laid out inline —
the host pulls its content into a separate top-level window/overlay. On Android this is a
`Dialog` (or a `FrameLayout` added to the Activity's `android.R.id.content` / a `WindowManager`
overlay); on iOS a separate `UIWindow`/`presentViewController`. The content children still come
through the normal walker (`insertChild` into the modal's content host), so cell rendering is
ordinary Canopy view code — only the *mount target* differs.

### 7.3 `.can` API: NEW `Native/Modal.can`
```
module Native.Modal exposing
    ( modal, visible, transparent, animationType, onRequestClose )
modal : List (Attribute msg) -> List (Node msg) -> Node msg     -- VirtualDom.node "CanopyModalHost"
visible : Bool -> Attribute msg                                  -- property "visible"
transparent : Bool -> Attribute msg                             -- property "transparent"
animationType : String -> Attribute msg                         -- attribute "animationType"
onRequestClose : msg -> Attribute msg                           -- VirtualDom.on "requestClose" (Normal …)
```
Pattern: the app keeps `modal [ visible model.showPaywall, onRequestClose Close ] [ … ]`
**always in the tree**; `visible:false` makes the host hide the overlay (no unmount churn).

### 7.4 native.js (walker) changes
- **The modal content must mount even though it is "off-screen" in layout.** The walker renders
  `CanopyModalHost` like any element (`_Native_renderElement`, `native.js:270`) — it creates the
  view, applies props, inserts children. The host decides the content is shown in an overlay.
  So **no special walker case** is needed: a `CanopyModalHost` is just a view whose host
  implementation reparents itself to a Dialog. `visible`/`transparent`/`animationType` are plain
  props; `requestClose` is a normal event.
- One subtlety: the `CanopyModalHost` view itself occupies a 0×0 slot in the normal Yoga tree
  (its real content lives in the overlay). Set its Yoga node to `display:none`-equivalent
  (`width:0,height:0,position:absolute`) so it contributes nothing to the inline layout — done
  host-side in `makeView` (§7.5), not in the walker.

### 7.5 Android host changes
- `makeView` (`CanopyHost.java:172-188`): `case "CanopyModalHost":` → a NEW
  `com.canopyhost.views.CanopyModalHost` (NEW FILE). It is a tiny placeholder `View` in the
  inline tree (measures 0×0) that **owns** an `android.app.Dialog` (themed transparent,
  `Window.FEATURE_NO_TITLE`, dim or clear). Its `content()` is the Dialog's content
  `YogaViewGroup`.
- `insertChild`/`removeChild` (`CanopyHost.java:103-125`): when the parent is a `CanopyModalHost`,
  route children into `modal.content()` (its Dialog content host + that host's YogaNode), exactly
  like the ScrollView content-host trick (§3.5 Option A). Generalize the content-host indirection
  so both ScrollView and Modal share it (a `CView.contentView`/`contentYoga` pair).
- `applyProps`: `visible:true`→`dialog.show()` (and lay out the content host with the screen
  size); `visible:false`→`dialog.hide()`; `transparent`→clear vs dim window background;
  `animationType`→set `WindowManager.LayoutParams.windowAnimations`.
- Hardware back: the Dialog's `setOnCancelListener`/`onBackPressed` → emit `requestClose`. The
  Activity already owns an `OnBackPressedDispatcher` (`MainActivity.java:108-122`); when a modal
  is visible the Dialog naturally intercepts back, so emit `requestClose` from the Dialog's
  back handler and let the app flip `visible` to false.
- Backdrop tap (when `transparent`) → a click on the Dialog's root outside the content → emit
  `requestClose`.

### 7.6 NEW FILE: `host/android/.../views/CanopyModalHost.java`
```
public final class CanopyModalHost extends android.view.View {
  // 0x0 inline placeholder; owns a Dialog whose content is a YogaViewGroup.
  // ViewGroup content();  void setVisible(boolean); void setTransparent(boolean);
  // void setAnimationType(String); void setEmitHandle(int h);  // requestClose target
  // onMeasure → setMeasuredDimension(0,0).  Dialog.setOnCancelListener → emit "requestClose".
}
```

### 7.7 iOS sketch
- `CanopyModalHost`→a 0×0 `UIView` placeholder owning a child `UIWindow` (or a
  `presentViewController:` on the root VC). `visible`→`makeKeyAndVisible`/`dismiss`;
  `transparent`→`backgroundColor` clear vs dimmed; back-equivalent is the swipe-down/backdrop
  tap → emit `requestClose`. **[iOS-BLOCKED-ON-PROJECT]**.

### 7.8 Testing
- Harness: render `modal [visible True] [ text [] "Hi" ]`; assert a `CanopyModalHost` view is
  created with a child `RCTText` carrying "Hi" and `visible:true` prop. Toggle to `visible:false`
  → assert a single `updateProps {visible:false}` (no unmount).
- Device E2E: tap a button that flips `visible`, screen-capture the dialog; press hardware back,
  assert `requestClose` fired (model flips, dialog gone).

**Effort: L (Android).** **iOS: M once project exists.**

---

## 8. Web-package reuse map (reuse vs re-back)

| Need | Reuse as-is | Re-back onto Native | Notes |
|---|---|---|---|
| LIS reorder (§2) | `_VirtualDom_lisIndices` (`virtual-dom.js:2416`) + move loop (`:2698`) | port verbatim into `native.js` | host addresses by index, so the move loop is simpler |
| List windowing (§4) | `canopy/virtual-list` `compute`/`VirtualRange`/`ItemHeight`/prefix-sum (`VirtualList.can:263-360`) | vendor the pure fns into `Native/List/Window.can`, drop `Html`/`Html.Keyed`/`Html.Events` deps | math is pure; only the *render* + scroll decoder are web-bound |
| Scroll event shape (§3) | `VirtualList.ScrollEvent` field names (`VirtualList.can:206-219`) | new `Native.Scroll.scrollDecoder` (native wire) | keep field names aligned so `Native.List` feeds `VirtualList`-style math |
| Image declarative API (§6) | `canopy/image`'s handle path stays for blobs | NEW `source`/`resizeMode`/`onLoad` on `Native` (`Image.can` is blob-only) | two complementary paths, not a merge |
| TextInput/Modal/ScrollView .can | `Html`'s attribute *vocabulary* as a naming guide | all new in `Native.*` | the DOM impls don't transfer; the API names should match RN/Html for portability |
| css→Yoga (all) | `Native.Css` (`Css.can`) already bridges `canopy/css` | extend `Css.can`'s `translate` (`Css.can:79-104`) if new keys (e.g. `resizeMode` is NOT css — keep it a plain attr) | reuse the existing camel/px/hex normalization |

Re-back, never re-import: `canopy/html`, `canopy/browser` (DOM-bound). Reuse freely: the
**pure value** layers — windowing math, LIS, css translation, the `VirtualDom` node shape, and
all of `core/runtime.js`.

---

## 9. iOS status & the bring-up gate

iOS today is `CanopyHostFabric.mm` (272 lines, `CanopyHostFabric.mm:1-192`) +
`CanopyHostViewController.mm` — **no Xcode project, no Hermes framework, no runtime pointer
retained for event emit** (`CanopyHostFabric.mm:104-110` TODO), and `testID` ignored. Every
iOS sketch above is written as a drop-in to `makeView`/`applyProps`/`applyFrames`/a per-view
delegate, so the work is "fill in the host methods" once the project exists. The hard
prerequisite (owned by Plan 08, host/DX) is:
1. An Xcode project + a vendored Hermes.xcframework + Yoga pod (mirroring the Android vendor
   recipe in MEMORY).
2. The host retaining `jsi::Runtime&` so `setEvents`/delegates can call `canopyEmitEvent`
   (`CanopyFabric.cpp:101`) — without it, **no iOS events fire** (the single biggest iOS gap
   for TextInput/ScrollView/Modal).
3. `testID`→`accessibilityIdentifier` so the E2E driver can find elements.

Until then, all six iOS sketches are **[iOS-BLOCKED-ON-PROJECT]** for *validation*; the code is
specified and can be written ahead of the project.

---

## 10. Testing strategy (consolidated)

### 10.1 Mock-fabric unit (runs in Node, no device) — the primary regression net
The harness (`harness/mock-fabric.js` + the `_test_*` block in `native.js:792-923`) already
drives the **real** walker against an in-memory Fabric and asserts §8 properties (create count,
update count, text). Extend it:
- Add `op==='insertChild'` counting → assert LIS minimality (§2.4).
- Add an `emit(handle, name, payload)` to `mock-fabric.js` that routes through
  `_Native_dispatchEvent` (`native.js:104`) so event round-trips (changeText, scroll, requestClose)
  are testable headlessly (§5.6, §7.8).
- Add windowing assertions: a 1000-item `Native.List` renders ~14 rows, a simulated scroll slides
  the window with minimal ops (§4.8).
Wire all of these into `harness/run.js` so `node harness/run.js` is the per-commit gate.

### 10.2 Device E2E (emulator, Android only for now)
The MEMORY notes the emulator is hardware-accelerated and the capability gates are validated by
`uiautomator dump` + `screencap`. Per-component device checks:
- ScrollView: fling, assert offset changes via a label bound to `onScroll`.
- List: `uiautomator dump`, assert only windowed rows exist in the hierarchy.
- TextInput: `adb input text`, assert the model echoes; needs **real `testID`** (Plan 08) so the
  driver can target the field — today `testID` is a no-op on both hosts.
- Image: `asset:lumen-test.jpg` renders; bad URL fires `onError`.
- Modal: open/close, hardware-back fires `requestClose`.

### 10.3 The `testID` dependency (flagged risk)
E2E for **every** component above needs `testID` to be real. It is currently dropped
(`Attributes.testID` produces a plain prop the host never reads). Making it real
(`view.setTag`/`setContentDescription` on Android, `accessibilityIdentifier` on iOS) is small
but is a **hard prerequisite** owned by Plan 08; this plan's device tests are blocked on it.

---

## 11. Risks & open questions

1. **Per-frame re-render cost for virtualization (§4.6).** Each `scroll` event re-runs
   `view(model)` for the whole app. Mitigation: throttle emits to 1/frame + the same-order fast
   path (§2.2) makes most frames diff to nothing. Open: if a screen's `view` is heavy, we need
   `lazy`/thunk discipline (already supported, `native.js:216-218`) around the list. If that is
   still too slow for 100k-row feeds, the fallback is a native `RecyclerView` host component with
   a keyed-data ABI — explicitly deferred (§4.1).
2. **ScrollView ⊃ Yoga measure interaction (§3.2/§3.6).** The "content node measured with
   UNSPECIFIED on the scroll axis" trick must compose with the existing root-drives-layout model
   (`CanopyHost.java:424-445`). Risk: a nested scroll inside a flex column. Needs a focused
   device test; the inner content host must not be re-clamped by the outer `EXACTLY` spec.
3. **Controlled TextInput cursor/IME (§5.3/§5.4).** String-equality guard is an approximation of
   RN's event-counter scheme. Edge cases: IME composition (CJK), fast typing while a slow update
   round-trips. Acceptable for Lumen (Latin, light input); flagged for hardening.
4. **Coil/Glide dependency size + license (§6.2).** Adds a transitive dep to a bare-RN host that
   has so far vendored only `.so`s. Confirm it doesn't pull a conflicting `kotlin-stdlib`/
   `androidx` version against the existing `swiperefreshlayout`/`activity` deps. Glide (Java, no
   Kotlin) is the fallback if Coil's Kotlin runtime is unwanted.
5. **Modal off-tree reparenting (§7.2).** A `Dialog`-owned content host is a second Yoga root;
   `requestRelayout` (`CanopyHost.java:463-468`) only relayouts the main root. The modal content
   host needs its own relayout trigger on its own prop changes. Generalize `requestRelayout` to
   relayout the nearest content-host root, not always `root`.
6. **iOS event emit (§9).** Until the host retains the runtime pointer, **no** iOS interactive
   component works. This is the single largest iOS unblock and is a Plan-08 dependency.
7. **`testID` is a no-op (§10.3).** Blocks all device E2E. Small fix, external dependency.
8. **Horizontal scroll + RefreshControl coexistence (§3.6).** `SwipeRefreshLayout` is vertical;
   combining with horizontal lists needs care. Ship vertical-with-refresh first.

---

## 12. Milestones & ordering

| # | Milestone | Effort | Deliverables |
|---|---|---|---|
| R1 | **LIS keyed reconciler** (§2): port `_Native_lisIndices` + rewrite reorder tail + fast paths in `native.js`; harness insert-count tests | M | (c) — pure JS, no host, unblocks lists |
| R2 | **Real ScrollView** (§3): `Native/Scroll.can`, `CanopyScrollView.java` (vertical + RefreshControl), host `makeView`/`applyProps`/`setEvents`/content-host indirection; gradle swiperefresh dep | L | (a) |
| R3 | **List virtualization** (§4): vendor windowing math into `Native/List/Window.can`, `Native/List.can` over `Native.Scroll`; harness windowing tests | L | (b) — depends on R1+R2 |
| R4 | **TextInput** (§5): `Native/Attributes`+`Native/Events` additions, `RCTMultilineTextInputView`, host `EditText` listeners + controlled-value guard + `jsonEscape`; harness event round-trip | L | (d) |
| R5 | **Image source** (§6): Coil dep, `source`/`resizeMode`/`onLoad`/`onError`, host `loadSource` + scaleType + shared `ImageLoader` | M | (e) |
| R6 | **Modal** (§7): `Native/Modal.can`, `CanopyModalHost.java` (Dialog), host content-host reuse + back/backdrop → `requestClose` | L | (f) |
| R7 | **Horizontal scroll** (§3.6) + per-component device E2E (gated on Plan-08 `testID`) | S+M | (a) polish, all E2E |
| Ri | **iOS host methods** for a–f, dropped into `CanopyHostFabric.mm` | XL | all, **[BLOCKED on Plan-08 iOS project + runtime pointer]** |

Ordering rationale: R1 is free and unblocks R3; R2 (ScrollView) is the substrate R3 (List) and
R6 (Modal content-host) reuse; R4/R5 are independent and can run in parallel after R2. iOS (Ri)
trails the project bring-up and reuses every `.can`/walker artifact unchanged.

**Critical path:** R1 → R2 → R3, with R4/R5/R6 parallelizable after R2. Total Android-only:
~3 L + 2 M + 1 S ≈ 18–24 engineer-days; iOS adds an XL once unblocked.
