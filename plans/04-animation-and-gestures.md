# Canopy Native — Animation & Gesture Subsystem (production plan)

Area: **animation-gestures**. Goal: a production animation + gesture subsystem at React Native /
Reanimated 3 + react-native-gesture-handler parity, **from zero**, designed for the *direct-views
+ Yoga* host (no React Native, so we cannot inherit Reanimated's worklet/UI-thread runtime — we
build the equivalent native-driven-property machinery ourselves).

The North Star: **animations and active gestures never round-trip the Hermes/TEA loop.** A drag,
a spring, a fling must run entirely on the platform UI thread from a spec pushed once across the
ABI, exactly like `BeforeAfterView` self-drives its wipe today — generalized into a reusable
native-driven-property mechanism. The TEA loop hears only coarse `start` / `commit` semantic
edges.

---

## 0. Current state (file:line evidence)

There is **no animation system and no general gesture system.** What exists:

### 0.1 The one hardcoded animation: `BeforeAfterView`
`host/android/app/src/main/java/com/canopyhost/views/BeforeAfterView.java`:
- A single bespoke `android.view.View` with a `ValueAnimator` snap on double-tap
  (`animateTo`, lines 229-245) and a `GestureDetector.onScroll` that moves `wipeFraction` and
  calls `invalidate()` per touch sample (lines 191-210) — **zero JS per frame** (the comment at
  lines 9-21 states the whole rule).
- It emits only two semantic edges: `wipeStart` (line 203) and `wipeCommit` (lines 175, 241).
- It owns one animatable scalar (`wipe`, line 64) with a `controlled` shadow (line 63) so a TEA
  re-render that pushes `wipeFraction` does **not** clobber a live drag (`setWipeFraction`
  guard, lines 112-118). **This is the entire animated-prop-vs-reconciler discipline, hardcoded
  for one property on one view.** The plan generalizes exactly this.
- `ValueAnimator` ticks via Android's `Choreographer` internally, but the result only mutates a
  private float + `invalidate()`; it does not touch Yoga or generic transform props.

### 0.2 The generic gesture installer (coarse, JS-per-sample)
`host/android/app/src/main/java/com/canopyhost/views/CanopyGestures.java`:
- Installs a `GestureDetector` + `VelocityTracker` for `pan`/`tap`/`doubleTap`
  (`install`, lines 48-56). `onScroll` emits a `"pan"` event **every frame** to JS
  (line 134) — `CanopyHostJni.emitEvent` → `canopyEmitEvent` → `__canopy_dispatchEvent` →
  decode → `update`. This is the jank path the architecture warns against
  (`Native/Events.can` doc lines 16-19, 120-121).
- Single recognizer only: no pinch, no rotate, no fling-with-momentum, no composition, no
  simultaneity, no axis-claim coordination across nested recognizers (only the local
  `requestDisallowInterceptTouchEvent` axis-bias, lines 130/160).
- Wire shape: `{"dx","dy","vx","vy"}` in dp (lines 152-156), decoded by
  `Native/Events.can` `panDecoder` (lines 111-117).

### 0.3 The `.can` surface
`package/src/Native/Events.can`: `onPan/onPanStart/onPanEnd` (lines 122-136),
`onTap/onDoubleTap` (87-95), `onPress` family. **No `Animated` value, no `interpolate`, no
`timing/spring/decay`, no `parallel/sequence/stagger`, no `LayoutAnimation`, no pinch/rotate.**
`package/src/Native/BeforeAfter.can` is the only "self-driving" API and it is single-purpose
(lines 41-74).

### 0.4 The render seam + ABI (what we extend)
`package/external/native.js`:
- The third walker (vnode → `__fabric_*` mutations). Style facts flow as `props.style`
  (`_Native_factsToProps`, lines 160-204); **transform/shadow are passed through as style
  keys but the host drops them** (see 0.6).
- Event dispatch in: `__canopy_dispatchEvent(handle, name, payload)` (lines 104-110),
  installed at boot (line 735).
- `_Native_requestFrame` (lines 668-673) prefers `__fabric_requestFrame`, the host vsync hook,
  else `setTimeout`. Used **only** by the model→frame coalescing animator
  (`_Native_makeAnimator`, 675-693) — *not* an animation driver.
- The reconciler: `_Native_diffApplyFacts` (474-498), `_Native_diffSub` (500-510). **A removed
  style key is sent as `null` and the host resets it** — this is precisely the mechanism that
  would clobber an animated transform on the next re-render (the central reconciler hazard;
  see §6).

The C++ JSI surface `host/shared/cpp/CanopyFabric.cpp`:
- Installs `__fabric_*` (lines 46-99) including `__fabric_requestFrame` (90-98, hops the cb
  back to the JS thread).
- `canopyEmitEvent` (101-110) is the only host→JS event path.
- **There is no `__anim_*` surface and no per-property native driver.**

The JNI vsync today is **not** a real Choreographer: `CanopyHostJni.cpp` `requestFrame`
(lines 99-104) routes through `postToJs` → `CanopyHostJni.scheduleOnJs` →
`Handler(mainLooper).post` (`CanopyHostJni.java` lines 53-58). A `setTimeout`/Handler post is
not vsync-aligned; the real driver must use `android.view.Choreographer`.

### 0.5 The threading model (the key enabler)
For the direct-views host **the JS thread IS the main/UI thread** (`CanopyHostJni.cpp` boot
comment lines 171-178; iOS `CanopyHostViewController.mm` lines 50-61). So a native driver that
mutates `View` transforms on the UI thread and a JS reconciler that mutates the same views are
*on the same thread* — no cross-thread races, but also: **a long native animation must not block
the JS thread.** The driver runs on the Choreographer callback (UI thread), does only float math
+ `view.setTranslationX(...)` (cheap), and never calls into Hermes except to emit coarse edges.
This is why Reanimated's separate UI runtime is unnecessary *here*: we already render on the UI
thread; we just need a per-frame native ticker that does not wake Hermes.

### 0.6 Style facts the host currently drops (animation-relevant)
`CanopyHost.java applyStyle` (lines 226-305) is an explicit whitelist. It handles `opacity`
(line 280) but **silently drops `transform`, `shadow*`, `overflow`, `border*` (except radius),
`resizeMode`.** `canopy/css` already *has* the transform vocabulary
(`css/src/Css.can` lines 1007-1016, `Css/Value.can` `translate/scale/rotate/skew`
lines 2217-2247) — the value layer is reusable; only the host applicator and the
animated-driver are missing.

---

## 1. Target design at RN parity

Three coordinated layers. The `.can` API is *declarative* (you describe the animation/gesture),
the wire is a *spec* pushed once, and the host owns a **native driver** that ticks per-vsync.

### 1.1 Layer A — `Animated` (native-driven properties)
RN-`Animated`/Reanimated-shared-value analog:

- **`Animated.Value`** — an opaque float owned by the host's driver, addressed by a stable
  integer id. Created by the app, referenced in style via `Animated.transform`/`Animated.opacity`.
- **Driver animations**: `timing` (duration + easing), `spring` (stiffness/damping/mass or
  bounciness/speed), `decay` (initial velocity + deceleration). These run on the native
  Choreographer/CADisplayLink loop.
- **`interpolate`**: input range → output range mapping (clamp/extend), computed natively each
  frame so one `Value` drives many props at different scales.
- **Composition**: `parallel`, `sequence`, `stagger`, `delay`, `loop`, `repeat(n)` — composed
  in the *spec* and executed natively (the driver runs a small instruction list, never JS).
- **Event mapping** (RN `Animated.event`): a gesture's native translation feeds an
  `Animated.Value` **directly inside the host** — the finger drives the value with zero JS
  (the BeforeAfter pattern, generalized to any value).
- **Completion callback**: when a driver animation finishes, the host emits ONE coarse
  `animEnd` edge → optional `msg`. Mid-animation the TEA loop is silent.

### 1.2 Layer B — `LayoutAnimation` (animate Yoga deltas)
RN `LayoutAnimation` analog: when the *next* TEA re-render changes layout (a row appears, a
card grows), the host animates each view from its **old Yoga frame to its new Yoga frame**
instead of snapping. Configured by a one-shot spec set *before* the render that causes the
change. This is a host-level frame-tween, not an `Animated.Value`.

### 1.3 Layer C — Gestures (the gesture-handler analog)
A general native gesture primitive: `pan`, `pinch`, `rotation`, `fling`, `longPress`, `tap`,
`force`, with:
- **Direct native binding** to `Animated.Value`s (drag → translateX value, pinch → scale
  value) so the gesture drives props **without JS per sample** — the core jank fix.
- **Composition**: `simultaneous` (pan + pinch + rotate together on a photo),
  `exclusive`/`race` (pan OR longPress), `requireToFail` (single-tap waits for double-tap).
- **Coarse edges only** to JS: `onBegin`, `onStart` (recognized), `onEnd`/`onFinalize` with the
  final translation + velocity; **never per-frame** unless the app explicitly opts into a
  `continuous` listener (escape hatch, kept for parity but documented as the jank path).
- **Cross-recognizer arbitration**: a native gesture coordinator decides which recognizer in a
  nested tree owns the touch stream (replaces today's ad-hoc `requestDisallowIntercept`).

### 1.4 Data-flow summary

```
APP (.can)                          ABI (native.js / __anim_*)        HOST (Android/iOS driver)
─────────                           ──────────────────────────        ─────────────────────────
Animated.value 0       ──create──▶  __anim_createValue(id, 0)    ──▶  driver.values[id] = 0
style [ Animated.opacity v ]  ─────  prop {__animBindings:[...]}  ──▶  bind view.alpha ← value id
Animated.start                       __anim_run(specJson)         ──▶  driver schedules instrs;
  (timing/spring/parallel…)                                            Choreographer ticks each frame
                                                                       → view.setAlpha / setTranslationX
[every frame: NO JS]                                                   [host math only, UI thread]
                            ◀──animEnd──  __canopy_dispatchEvent  ◀──  driver emits ONE edge on done
Gesture.pan |> onChange v   ──────────  __gesture_config(specJson)──▶  recognizer drives value id
[drag: NO JS]                                                          live, per-frame, native
                            ◀──onEnd────  __canopy_dispatchEvent  ◀──  one edge: {tx,ty,vx,vy}
```

---

## 2. The `.can` API (new + changed modules)

New package modules under `package/src/Native/`. Add to `canopy.json` `exposed-modules`
(currently lists `Native`, `Native.Attributes`, `Native.Events`, `Native.BeforeAfter`,
`Native.Css`, `Native.Module` — `package/canopy.json`).

### 2.1 `Native.Animated` (NEW — `package/src/Native/Animated.can`)

```can
module Native.Animated exposing
    ( Value, value                       -- create an animated scalar (host-owned)
    , Anim, timing, spring, decay         -- driver animations
    , Easing, linear, easeIn, easeOut, easeInOut, bezier
    , SpringConfig, gentle, wobbly, stiff -- presets + a record ctor
    , parallel, sequence, stagger, delay, loop, repeat
    , interpolate, Extrapolate(..)
    , start, stop, setValue              -- Cmd-producing actuators
    , transformX, transformY, scaleXY, rotateZ, opacity  -- style bindings
    , onAnimEnd
    )
```

Key types & semantics:
- `Value` is an opaque `{ id : Int }` minted via `value : Float -> ( Value, Cmd msg )` — the
  `Cmd` calls `__anim_createValue` once at the host so the driver allocates the slot. (The id
  generator lives in `external/native-animated.js`; mirrors how handles are minted.)
- `Anim` is a *pure value* describing a driver instruction tree — **no side effect until
  `start`**. `timing v { to, duration, easing }`, `spring v { to, config }`,
  `decay v { velocity, deceleration }`.
- `parallel : List Anim -> Anim`, `sequence : List Anim -> Anim`,
  `stagger : Float -> List Anim -> Anim`, `loop : Anim -> Anim`, `repeat : Int -> Anim -> Anim`.
  These build a JSON spec; the *host* executes the tree.
- `start : Anim -> (Bool -> msg) -> Cmd msg` — fires the spec (`__anim_run`), resolves the `msg`
  with `finished : Bool` when the **whole tree** completes (one coarse edge). `stop : Value ->
  Cmd msg`. `setValue : Value -> Float -> Cmd msg` (instant jump).
- `interpolate : Value -> { inputRange, outputRange, extrapolate } -> Value` returns a *derived*
  Value (host computes the mapping each frame; the derived id is bound to a downstream prop).
- Style bindings produce a **special attribute fact** (not a plain CSS style string): e.g.
  `opacity : Value -> Attribute msg` emits `VirtualDom.property "__animBind"
  (Encode.object [("prop","opacity"),("valueId", Encode.int v.id)])`. The walker collects these
  into an `__animBindings` array on the view's props (see §3).

`start`/`stop`/`setValue` are **plain Cmds via `Task.attempt` over a tiny FFI**, NOT effect
modules — this sidesteps the effect-module install gap flagged in memory
(`canopy-buildout-state.md` blocker #1). The FFI is a direct host-global call
(`__anim_run` etc.) wrapped in a `Task`, exactly like `Native.Module.call` but to the
`__anim_*` surface instead of `__canopy_call`.

### 2.2 `Native.Gesture` (NEW — `package/src/Native/Gesture.can`)

```can
module Native.Gesture exposing
    ( Gesture
    , pan, pinch, rotation, fling, longPress, tap, doubleTap
    , onBegin, onStart, onChange, onEnd, onFinalize   -- coarse edges (+ opt-in onChange)
    , drivesX, drivesY, drivesScale, drivesRotation   -- bind a recognizer to an Animated.Value
    , simultaneous, exclusive, race, requireToFail     -- composition
    , enabled, minDistance, minPointers, maxPointers, axis, Axis(..)
    , detector                                         -- attach to a view as an attribute
    )
```

- `Gesture` is a pure value (a recognizer spec). `detector : Gesture -> Attribute msg` attaches
  it: emits `VirtualDom.property "__gesture" (encodeGesture g)`. The walker forwards the spec to
  the host once (`__gesture_config(handle, specJson)`).
- `drivesX v` binds the pan's x-translation **directly to Animated.Value `v` in the host** — the
  zero-JS drag. The recognizer mutates the value slot every frame natively.
- `onEnd : (GestureData -> msg)` — the only data that crosses to JS at gesture end:
  `{ translationX, translationY, velocityX, velocityY, scale, rotation, state }`. `onChange` is
  the documented escape hatch (per-frame, jank) for cases that genuinely need JS each sample.
- Composition combinators build a tree the host arbitrates: `simultaneous [pan, pinch, rotation]`
  for a photo manipulator; `requireToFail tap doubleTap` so a single tap waits.

### 2.3 `Native.LayoutAnimation` (NEW — `package/src/Native/LayoutAnimation.can`)

```can
module Native.LayoutAnimation exposing
    ( Config, easeInEaseOut, spring, linear
    , configureNext        -- arm the NEXT render's layout delta to animate
    , Property(..)         -- Opacity | ScaleXY  for create/delete views
    )
```

`configureNext : Config -> Cmd msg` calls `__layout_configureNext(specJson)`; the host tweens
old→new Yoga frames on the next mount pass. One-shot, RN-identical ergonomics.

### 2.4 `Native.Attributes` — extend the applied-style set (`package/src/Native/Attributes.can`)
Add static (non-animated) transform/visual helpers so the *static* path matches RN too:
`translateX/translateY/scale/rotate` (emit `VirtualDom.style "transform" "..."` reusing
`canopy/css` `Value.transformToString`), `shadowColor/shadowOpacity/shadowRadius/elevation`,
`overflow`, `borderWidth/borderColor`. These are non-animated style facts; the host applicator
(§4) gains the matching cases. **Reuse `canopy/css`'s transform encoder rather than re-inventing
it** (`Css/Value.can` lines 2203-2247).

---

## 3. The ABI / `native.js` protocol changes

### 3.1 New host surface (installed by the C++ JSI layer alongside `__fabric_*`)

```
__anim_createValue(id, initial)                 -> void   allocate a driver value slot
__anim_run(specJson)                            -> runId  start a driver instruction tree
__anim_stop(valueId | runId)                    -> void   cancel
__anim_setValue(id, v)                          -> void   instant set
__anim_bind(handle, [{prop, valueId, interp?}]) -> void   bind view props to value ids
__gesture_config(handle, specJson)              -> void   install/replace a recognizer tree
__gesture_clear(handle)                         -> void   remove recognizers
__layout_configureNext(specJson)                -> void   arm next layout-delta animation
```

Completion + coarse gesture edges reuse the **existing** `__canopy_dispatchEvent(handle, name,
payload)` path — no new event channel. The driver emits `("animEnd", {runId, finished})` and
gestures emit `("gestureBegin"/"gestureEnd"/…, payload)` through the same dispatcher
(`native.js` lines 104-110). The `.can` decoders register via the normal event-fact path, so
`_Native_eventRegistry` and `_Native_makeCallback` are reused unchanged.

New file: **`package/external/native-animated.js`** — mints value ids, builds spec JSON, calls
the `__anim_*` / `__gesture_* `/ `__layout_*` host globals (lazy-resolved like
`_Native_host()`), and exposes the `Task`-wrapped actuators that `Native.Animated`/`Gesture`
import. Modeled on `native-module.js`. In the Node harness these globals are provided by a new
**`harness/mock-driver.js`** (§7).

### 3.2 Walker change: collect animated bindings and gesture specs
In `native.js` `_Native_factsToProps` (lines 160-204) and the deferred path
(`_Native_factsToPropsDeferred`, 302-320), add: after building `props`, scan the plain props for
the special keys `__animBind` (one binding) — coalesce repeated `__animBind` facts into a single
`props.__animBindings` array — and `__gesture` (the recognizer spec). These travel as ordinary
props to the host. The host's `applyProps` (§4) calls `__anim_bind` / `__gesture_config` from
them. **No change to the create/update/insert/remove core**; bindings ride props.

### 3.3 The reconciler hazard + fix (THE central correctness issue)
The diff sends a removed style key as `null` so the host resets it
(`_Native_diffSub` lines 500-510; `CanopyHost.applyStyle` `resetStyleKey`). If a view's
`transform`/`opacity` is being driven natively and the next TEA `view` does **not** re-declare
that style, the diff would null it and the host would snap the prop back — clobbering the
animation.

**Fix — "host owns animated props":** once a prop is bound via `__anim_bind` or driven by a
gesture, the host marks it *driver-owned* on that view. The host's `applyStyle`/`resetStyleKey`
**ignores `transform`/`opacity` writes (set OR reset) for driver-owned props** until the binding
is explicitly cleared (the `.can` side stops the animation / drops the binding, which sends an
`__animBind` removal → host unmarks). This means:
- A normal re-render that happens to touch other props does not disturb a live animation.
- The app keeps `opacity`/`transform` in style for the *resting* value; the driver overlays the
  animated value; when the animation ends the driver writes the final value and (optionally) the
  app's `setValue` keeps model + native in sync.

This mirrors the existing `BeforeAfterView.controlled` vs `wipe` shadow (lines 63-64,
`setWipeFraction` guard 112-118) — generalized: the host's driver layer is the authority for
bound props; the reconciler is the authority for everything else. Document this invariant at the
top of `native-animated.js` and in `CanopyHost`'s applyProps.

### 3.4 Why this composes safely with thunks/keyed reconciliation
Animated bindings live on a stable view `handle`. Reconciliation reuses handles across renders
(the no-remount discipline, `testCreateCountForUpdate === 0`). As long as a bound view is *not
re-mounted* (handle stable), its driver binding persists. If a keyed reorder or type change
*does* remount (`_Native_redraw`, lines 441-452), the host must tear the binding down — hook
`_Native_releaseEvents` (lines 454-458) to ALSO call `__gesture_clear`/unbind on the dead handle
(it already deletes the event registry there; add the driver cleanup symmetrically).

---

## 4. Host: Android driver (the core of the work)

### 4.1 The vsync driver — `host/android/.../anim/CanopyAnimDriver.java` (NEW)
A single process-wide driver bound to the `CanopyHost`. Replaces the `setTimeout`-ish frame hook
with a **real `android.view.Choreographer`** loop (the current `__fabric_requestFrame` →
main-Looper post is NOT vsync-aligned — `CanopyHostJni.cpp` 99-104).

```java
final class CanopyAnimDriver implements Choreographer.FrameCallback {
  final SparseArray<float[]> values;     // valueId -> {current, ...}
  final List<Instr> active;              // running timing/spring/decay nodes
  final Map<Integer, List<Binding>> bindingsByView; // viewHandle -> [{prop, valueId, interp}]
  boolean scheduled;

  void createValue(int id, float v) { values.put(id, new float[]{v}); }
  void run(String specJson) { /* parse tree → schedule Instr list; ensureScheduled(); */ }
  void bind(int viewHandle, JSONArray bindings) { /* store; apply current immediately */ }

  @Override public void doFrame(long frameTimeNanos) {
    scheduled = false;
    boolean stillRunning = stepAll(frameTimeNanos);   // advance every active Instr
    applyBindings();                                   // write values → view props (UI thread)
    if (stillRunning) Choreographer.getInstance().postFrameCallback(this);
    // emit animEnd edges for completed runs (coarse, ONE per run)
  }
}
```

- **`Instr` kinds**: `Timing` (start time, duration, easing fn, from, to), `Spring` (RK4 or
  semi-implicit Euler with stiffness/damping/mass; rest threshold on position+velocity),
  `Decay` (velocity * deceleration^dt). Composition (`Sequence`/`Parallel`/`Stagger`/`Loop`) is
  a small interpreter over child instrs with start gates.
- **`applyBindings`**: for each bound view, compute the prop from the (possibly interpolated)
  value and write it: `opacity → view.setAlpha(f)`; `translateX → view.setTranslationX(dp*f)`;
  `scaleXY → view.setScaleX/Y(f)`; `rotateZ → view.setRotation(deg)`. These are **View
  compositor properties** — they do NOT invalidate Yoga layout (transform/alpha are draw-time),
  so an animation is cheap and never triggers `requestLayout`. This is the key perf property and
  the reason transform/opacity are the animatable set (RN's `useNativeDriver` allowlist, for the
  same reason).
- **Driver-owned marking**: `bind` records that `(viewHandle, prop)` is driver-owned; expose
  `isDriverOwned(handle, prop)` so `CanopyHost.applyStyle` can skip those keys (§3.3).
- **Interpolation**: a derived value id stores `{srcId, inputRange, outputRange, extrapolate}`;
  resolved in `applyBindings` by reading the source's current value.

### 4.2 Wire the driver into `CanopyHost.java` (`host/.../CanopyHost.java`)
- In `applyProps` (after line 217), handle `__animBindings` → `driver.bind(h, arr)` and
  `__gesture` → `gestureCoordinator.config(h, cv.view, spec)`; handle their removals (null) →
  `driver.unbind(h)` / `gestureCoordinator.clear(h)`.
- In `applyStyle` (lines 226-305): for `transform`/`opacity`, **guard** with
  `if (driver.isDriverOwned(h, key)) continue;` so the reconciler cannot clobber a live anim
  (§3.3). Add the *static* transform/shadow/overflow/border cases here too (§2.4) — reuse the
  same `View.setTranslationX/setScaleX/setRotation` setters for static transforms parsed from
  the `transform` string; `elevation`/shadow via `view.setElevation` + `GradientDrawable`.
- In `createView`, the `BeforeAfterView` special-case (lines 84-86) becomes one instance of the
  general "self-driving view" pattern — but BeforeAfter stays as-is; we are adding the *generic*
  path beside it, not rewriting it (de-risks the milestone).

### 4.3 The gesture coordinator — `host/android/.../gesture/CanopyGestureCoordinator.java` (NEW)
Replaces the per-view `CanopyGestures` ad-hockery with a composable recognizer system. Use
Android's native recognizers where they fit, custom where they don't:
- **Pan**: a custom touch-slop tracker (more controllable than `GestureDetector.onScroll` for
  simultaneity) OR keep `GestureDetector` for the simple case. Pan binds → driver value
  (`drivesX/Y`): on each `MotionEvent.ACTION_MOVE` it writes the translation **directly into the
  driver value slot** and calls `driver.applyBindings()` (or schedules a frame) — **no
  `emitEvent` per sample**. Only `ACTION_DOWN`→`gestureBegin`, recognition→`gestureStart`,
  `ACTION_UP`→`gestureEnd` (with `VelocityTracker` velocity) cross to JS.
- **Pinch**: `ScaleGestureDetector` → drives a scale value.
- **Rotation**: custom two-pointer angle delta → drives a rotation value.
- **Fling**: `VelocityTracker` at end → start a `decay` Instr on the bound value (momentum
  continues natively after lift, zero JS).
- **Composition**: a per-view recognizer group with `simultaneous` (all process the same
  `MotionEvent`), `exclusive`/`race` (first to recognize wins, others cancel), `requireToFail`
  (a recognizer defers success until its dependency fails — implemented with a short timeout for
  tap-vs-doubleTap). The coordinator owns the touch stream and the
  `requestDisallowInterceptTouchEvent` decision centrally (replacing the scattered calls in
  `CanopyGestures.java` 158-166).

`CanopyGestures.java` stays for backward-compat `onPan` (the documented jank path), but new code
goes through the coordinator.

### 4.4 LayoutAnimation — `host/android/.../anim/CanopyLayoutAnimator.java` (NEW)
- `configureNext(spec)` sets a one-shot flag + config.
- In `CanopyHost`'s `YogaViewGroup.onLayout` (lines 447-458): if armed, before applying new
  frames, capture each child's **current** frame; after Yoga computes new frames, instead of
  `ch.layout(newFrame)` immediately, start a Choreographer tween from old→new
  (translation/scale to fake the move, then settle into the real layout). For
  create/delete: fade/scale in/out per `Property`. Disarm after one pass. RN-identical
  ergonomics; implemented as a frame-tween over the driver.

### 4.5 JNI + C++ surface
- `host/shared/cpp/CanopyAnim.{h,cpp}` (NEW): installs `__anim_*`, `__gesture_*`,
  `__layout_*` host functions, marshalling jsi↔string exactly like `CanopyFabric.cpp`
  (lines 46-99). Each forwards to a `CanopyAnimHost` abstract method (mirrors `CanopyHost`).
- `host/android/.../jni/CanopyHostJni.cpp`: add a `JavaBackedAnimHost` (like `JavaBackedHost`
  lines 76-110) forwarding `__anim_run` etc. to Java `CanopyAnimDriver`/coordinator over JNI;
  call `installCanopyAnim(*g_runtime, animHost)` in `boot` (after line 185).
- The driver's `animEnd`/gesture edges call back via the **existing** `CanopyHostJni.emitEvent`
  → `canopyEmitEvent` (lines 248-255) — no new C++ event path.
- **Replace the frame hook**: change `JavaBackedHost::requestFrame` (lines 99-104) to post a
  `Choreographer.FrameCallback` (via the driver) instead of `postToJs`/main-Looper, so
  `_Native_makeAnimator` and the driver share one vsync source. (Keep the worker→JS hop
  `postToJs` for module completions — that's orthogonal.)
- `CMakeLists.txt`: add `${SHARED_CPP}/CanopyAnim.cpp` to the `canopyhost` target (after
  `CanopyFabric.cpp`, line ~ the `add_library` block).

---

## 5. Host: iOS approach (blocked on project bring-up, designed now)

iOS is two loose `.mm` files with **no Xcode project** (`host/ios/CanopyHost/*.mm`); the project
bring-up is a separate milestone (cross-area dependency — see `risks`). The animation/gesture
design is symmetric and can be written against the existing `CanopyHostIOS`
(`CanopyHostFabric.mm`) the moment the project exists:

- **Driver**: a `CADisplayLink`-backed `CanopyAnimDriver` (Obj-C++), the exact analog of the
  Choreographer driver. `displayLink.add(to: .main, forMode: .common)`; in the callback, step
  instrs and write **`CALayer`/`UIView` transform + opacity**:
  `view.transform = CGAffineTransform(...)`, `view.alpha = f`. Like Android, transform/opacity
  are compositor properties — no Auto Layout / Yoga re-run.
- **Springs**: prefer `UIViewPropertyAnimator`/`CASpringAnimation` for the common case
  (battery-tuned, vsync-correct), but keep the custom integrator for `Animated.Value`s that must
  be *driven by a gesture* (Core Animation can't be fed a live finger value mid-flight; the
  custom integrator can). Mirror RN's split.
- **Gestures**: `UIPanGestureRecognizer`, `UIPinchGestureRecognizer`,
  `UIRotationGestureRecognizer`, `UILongPressGestureRecognizer`, `UITapGestureRecognizer`. Native
  **simultaneity** via `UIGestureRecognizerDelegate.gestureRecognizer(_:shouldRecognizeSimultaneouslyWith:)`
  — iOS has first-class simultaneity, so `simultaneous`/`requireToFail` (via
  `require(toFail:)`) map *directly* (cleaner than Android). A pan recognizer's
  `translation(in:)` writes the driver value each callback — zero JS, same as Android.
- **`__anim_*` install**: `installCanopyAnim` is portable C++ (`CanopyAnim.cpp`) and is shared;
  only the `CanopyAnimHostIOS` implementation (Obj-C++) differs, registered in
  `CanopyHostViewController.mm bootCanopy` (after line 62) once the project exists.
- The existing `requestFrame` (`CanopyHostFabric.mm` lines 112-115) is a `dispatch_async(main)`
  placeholder; it becomes the `CADisplayLink` tick.

**Status: iOS driver/gesture code is fully specified here but cannot compile until the Xcode
project + Hermes-framework build exists (needs a Mac/cloud — memory: "iOS still needs a Mac").**
Write it behind the same `CanopyAnimHost` interface so it is a drop-in.

---

## 6. Web-package reuse

| Concern | Reuse vs re-back | Evidence / note |
|---|---|---|
| Transform value vocabulary (`translate/scale/rotate/skew`, `transformToString`) | **Reuse** `canopy/css` `Css/Value.can` 2203-2247 | The `.can` static-transform helpers and the animated `transform` encoder both serialize via the same functions; do not re-invent. |
| Easing / bezier curves | **Reuse the curve math, re-back the runtime** | `canopy/css` has `transition-timing-function`/`cubic-bezier` *values* (`Transition.can`), but they are CSS strings interpreted by a browser. The **native driver must compute the bezier itself** each frame. Reuse the *names/parameters* from `Css.Value`'s timing-function values for API familiarity; implement the sampler natively (Android/iOS). |
| Keyframes (`Css.Animation`) | **Re-back** | `Css/Animation.can` keyframes are declarative CSS the browser runs. The native equivalent is `sequence`/`parallel` of `timing` instrs. Optionally provide a `keyframesToAnim` adapter later, but the execution is native. |
| The reconciler / walker / event registry | **Reuse unchanged** | `native.js` `_Native_makeCallback`, `_Native_eventRegistry`, the diff — animated bindings and gesture specs ride existing props + the existing `__canopy_dispatchEvent` edge path. Only additive scanning in `_Native_factsToProps`. |
| `Native.Module` ABI pattern | **Reuse the *pattern*, new surface** | `__anim_*` actuators copy the `Task`-over-host-global shape of `native-module.js`, but hit `__anim_*` (sync UI calls) not `__canopy_call` (async worker). Avoids the effect-module install gap (memory blocker #1) by being plain Cmds. |
| `VelocityTracker`/`GestureDetector` reuse on Android | **Reuse platform, keep `CanopyGestures` as legacy** | The new coordinator can wrap `ScaleGestureDetector` etc.; `CanopyGestures.java` stays for `onPan` back-compat. |
| `BeforeAfterView` self-drive | **Generalize, don't replace** | It becomes one concrete instance of "gesture drives native prop, emits coarse edges." Keep it; the new system is the reusable form. |

**Net:** the value-encoding layer and the entire reconciler are reused; the *driver runtime*
(per-frame integration on Choreographer/CADisplayLink) and the *gesture coordinator* are
genuinely new native code with no web analog (the web gets this from the browser compositor).

---

## 7. Testing strategy

### 7.1 Mock-driver unit tests (no device) — `harness/mock-driver.js` (NEW)
Mirror `harness/mock-fabric.js`. Install `__anim_*`/`__gesture_*`/`__layout_*` globals on
`globalThis` backed by an in-memory driver with a **deterministic, steppable clock**:
- `createValue/run/bind/setValue` record into a value table + an instr list.
- `tick(ms)` advances the clock and recomputes each value (a JS reimplementation of the same
  timing/spring/decay math the native driver uses — kept in `harness/anim-math.js`, the single
  source of truth the Java/Obj-C drivers are validated against by golden vectors, §7.3).
- `flushFrames()` drives to quiescence; `emit(handle, 'animEnd', …)` and gesture edges go
  through the existing `__canopy_dispatchEvent`.

Assertions (extend `run-echo.js` style):
- `Animated.start (timing …)` → after N ticks the bound view's `opacity`/`transform` prop
  reaches the target; **zero `updateProps` from the JS side during the tween** (the jank
  criterion — the driver mutated props, not the reconciler).
- A TEA re-render that does NOT re-declare the animated style does **not** null the bound prop
  (the §3.3 clobber test — assert the value table is untouched after a diff).
- `parallel`/`sequence`/`stagger` ordering: assert per-tick value snapshots.
- Gesture: `emit(handle,'gestureBegin')` then simulated move samples → assert the bound value
  tracks the translation and **no per-frame JS msg fires**; only `onEnd` delivers a msg.
- `requireToFail tap doubleTap`: a single tap does not fire until the double-tap window lapses.

### 7.2 `Native.Testing` wrappers (close the phantom-module gap)
The audit notes `Native.Testing` is a phantom (engine exists in `native.js`, no `.can` wrapper).
Add `package/src/Native/Testing.can` exposing the existing `_test_*` engine functions PLUS new
anim/gesture probes in `native-animated.js` (e.g. `testAnimValueAfter : Anim -> Float -> Float`
that runs the JS driver math and returns the value at time t) so animation specs are unit-testable
inside `canopy test` with no device — same discipline as `testCreateCountForUpdate`
(`native.js` 882-887).

### 7.3 Device E2E + golden vectors
- **Golden math vectors**: a fixed set of `(spec, t) → value` cases generated by
  `harness/anim-math.js`; the Java `CanopyAnimDriver` and the Obj-C driver have a debug entry
  that runs the same cases and logs results; compare on-device (emulator screencap / logcat) to
  the golden file. This catches Java/JS integrator drift.
- **Android emulator** (the box has `/dev/kvm`, per memory): a probe app (extend
  `native/examples/lumen-probe`) with buttons that start a timing/spring/decay anim and a
  draggable photo (pan+pinch+rotate simultaneous). Validate via `uiautomator dump` + screencap
  that (a) the view moves, (b) logcat shows **one** `animEnd`/`gestureEnd` per interaction, not
  per-frame `dispatch` lines — the jank-free proof. (Memory's emulator tip: use `uiautomator
  dump` for exact coords.)
- **`testID` prerequisite**: gesture/anim E2E needs `testID` to find elements; today it is a
  no-op on both hosts (cross-area dependency on the DX/testID milestone). Until then, drive via
  fixed coordinates.
- **iOS**: blocked on project bring-up; the golden-vector test is the portable part and runs the
  moment the project compiles.

### 7.4 Performance assertion
On-device: a continuous spring/loop while logging frame times; assert no Hermes activity during
the animation (no `CanopyJS` logcat lines mid-tween) and frame pacing near display refresh. This
is the literal restatement of the "no JS per frame" rule the BeforeAfter comment encodes
(`BeforeAfterView.java` 9-21).

---

## 8. Milestones, effort, ordering

Ordering rationale: the **driver value + binding + one timing anim** is the spine everything else
hangs on; build it end-to-end (math → ABI → Android → harness) before breadth. Gestures reuse the
binding mechanism. iOS shadows each piece behind the shared interface, gated on project bring-up.

| # | Milestone | Effort | Deliverables |
|---|---|---|---|
| A1 | **Anim math core + harness** | **M** | `harness/anim-math.js` (timing/spring/decay/interpolate), `harness/mock-driver.js`, golden vectors. Pure JS, no host. Unblocks all later tests. |
| A2 | **`Native.Animated` `.can` + `native-animated.js` ABI** | **M** | `Animated.can` (Value/timing/spring/interpolate/parallel/sequence/start), `external/native-animated.js`, `__anim_*` spec encoder, walker scan for `__animBindings` in `native.js`. Passes A1 harness. |
| A3 | **Android driver (Choreographer) + bind into CanopyHost** | **L** | `CanopyAnimDriver.java`, `CanopyAnim.{h,cpp}`, JNI `JavaBackedAnimHost`, CMake add, `applyProps`/`applyStyle` binding + driver-owned guard (§3.3, §4.1-4.2). Emulator: a view fades/moves with one `animEnd`. |
| A4 | **Reconciler clobber-proofing + handle-teardown** | **S** | `native.js` `_Native_releaseEvents` also unbinds; host `isDriverOwned` skip in `applyStyle`/`resetStyleKey`. Harness clobber test green (§7.1). |
| A5 | **`Native.Gesture` + Android coordinator (pan/pinch/rotate/fling, simultaneity)** | **L** | `Gesture.can`, gesture spec in `native-animated.js`, `CanopyGestureCoordinator.java`, `drivesX/Y/Scale/Rotation` → driver value, coarse edges only. Emulator: drag/pinch a photo, one `gestureEnd`. |
| A6 | **Static transform/shadow/overflow/border in the host** | **S** | `Native.Attributes` helpers (reuse `Css.Value`), `CanopyHost.applyStyle` cases. Closes the "styling drops transform/shadow" audit gap for the static path. |
| A7 | **LayoutAnimation** | **M** | `LayoutAnimation.can`, `__layout_configureNext`, `CanopyLayoutAnimator.java`, old→new Yoga-frame tween in `YogaViewGroup.onLayout`. |
| A8 | **`Native.Testing` wrappers + anim/gesture probes** | **S** | `Native/Testing.can` (existing engine + anim probes), `canopy test` cases. |
| A9 | **iOS driver + gesture (CADisplayLink + UIKit recognizers)** | **L** (blocked) | `CanopyAnimHostIOS`, `CADisplayLink` driver, UIKit recognizer mapping, register in `CanopyHostViewController.mm`. **Gated on the iOS Xcode-project bring-up milestone (separate area).** |
| A10 | **Device E2E + perf assertion** | **M** | lumen-probe extension, golden-vector on-device check, no-JS-per-frame logcat proof. |

Critical path: A1 → A2 → A3 → A4 → (A5 ‖ A6 ‖ A7) → A8 → A10; A9 parallel once iOS project lands.

---

## 9. Risks & open questions

1. **Driver-owned vs reconciler authority (the central correctness risk).** The §3.3 invariant
   (host ignores reconciler writes to bound `transform`/`opacity`) must be airtight, or
   animations flicker on unrelated re-renders. Mitigation: the A4 harness clobber test is a gate;
   model the resting value in the app and the animated overlay in the driver, with explicit
   bind/unbind lifecycle tied to handle teardown. Open: should `setValue` on animation end push
   the resting value back into the model (so a later re-render is consistent) automatically, or
   leave it to the app? RN leaves it to the app; recommend the same but document loudly.

2. **Choreographer vs the existing frame hook.** Replacing `requestFrame`'s main-Looper post with
   a real `Choreographer` (§4.5) touches `_Native_makeAnimator`'s frame source too. Risk: double
   frame scheduling or a stalled loop. Mitigation: one shared driver owns the single
   `postFrameCallback`; the render animator and the prop driver both register through it.

3. **Gesture simultaneity is asymmetric across platforms.** iOS has first-class
   `shouldRecognizeSimultaneouslyWith`; Android has none — the coordinator must hand-roll
   simultaneous dispatch + arbitration (§4.3). Risk of subtle divergence (which recognizer
   "wins" a borderline pan-vs-pinch). Mitigation: shared spec semantics + a documented arbitration
   policy; golden interaction traces.

4. **iOS is hard-blocked on project bring-up** (no Xcode project, no Hermes framework, needs a
   Mac/cloud — memory). A9 is fully designed but uncompilable here. Open: schedule the iOS
   project milestone (separate area) before A9 can land; until then only the portable
   `CanopyAnim.cpp` + golden math are exercised.

5. **`testID` no-op blocks gesture/anim E2E element-finding** (cross-area DX dependency). Until
   `testID` lands on the hosts, device E2E drives by fixed coordinates (brittle). Sequence the
   testID fix near A10.

6. **Effect-module install gap (memory blocker #1).** Animation actuators are deliberately plain
   Cmds (`Task.attempt` over `__anim_*`), avoiding the need for a kernel-trusted effect package —
   but a *streaming* gesture listener (the opt-in `onChange` escape hatch) might want a Sub. Open:
   keep `onChange` as a one-shot-per-frame Cmd-free event fact (rides the existing event
   dispatcher, no Sub) to dodge the install gap — recommended.

7. **Spring integrator stability.** A naive Euler spring diverges at low frame rates / large dt.
   Mitigation: clamp dt, use semi-implicit Euler or RK4, rest thresholds on both position and
   velocity; validate against golden vectors (A1) so JS, Java, and Obj-C agree numerically.

8. **`Animated.Value` reuse vs interpolation derived-value lifecycle.** Derived (interpolated)
   values reference a source id; if the source is freed (view unmounted) the derived must be torn
   down too. Open: reference-count value ids in the driver; free on last binding removal.

9. **The `BeforeAfter` collapse bug is still open** (memory blocker #2 — `LumenBeforeAfterView`
   collapses its parent to 0 height in the Yoga tree). The generic driver path uses *compositor*
   properties (alpha/translation) on normally-laid-out views and does **not** reproduce that
   custom-leaf measurement issue — but if we ever fold BeforeAfter into the generic system, that
   measurement bug must be fixed first. Keep BeforeAfter separate until then.
