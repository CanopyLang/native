# canopy/native — Architecture

How idiomatic Canopy `view` code becomes a real native iOS/Android app, and why the
compiler, `core`, and `virtual-dom` never change. This distills the feasibility study
(`~/projects/research/canopy-native-mobile-feasibility.md`) into the design as built,
plus what the implementation actually proved.

---

## TL;DR

Canopy is already a multi-target renderer in disguise. `Html` walks `VirtualDom.Node`
data to the browser DOM; `Ssr` walks the **same** data to HTML strings. **`Native` is a
third walker over the same data that emits create/update/insert/remove mount calls over
JSI** to a thin native host (`__fabric_*` — Canopy's *own* mount ABI; the name borrows
Fabric's vocabulary but it is **not** RN's Fabric runtime — see
[`rn-coupling.md`](rn-coupling.md)). Keep the compiler emitting JavaScript, run it on
**Hermes** (the JS engine), and swap only the render seam. No new backend, no own engine,
no Skia — and **no RCTBridge / Fabric MountingManager / TurboModule** (Android mounts via
plain JNI → `android.view`; iOS mounts `UIView` with direct Yoga layout).

This was **validated end-to-end on the real toolchain** (see [§7](#7-validation)):
the actual `canopy` compiler compiles the `Native` package, and the emitted bundle —
running the real `core/runtime.js` scheduler and the real walker — renders a native
view tree and turns a tap into a single targeted `updateProps`, no re-mount.

---

## 1. Three layers, one coupled seam

| Layer | File(s) | Coupling | What we do |
|---|---|---|---|
| **A. Compiler** | `compiler/.../Generate/JavaScript.hs` | Emits JS; no DOM assumptions | **Nothing.** Ship the JS it already produces, run it on Hermes. |
| **B. Runtime / effects** | `core/external/runtime.js` | Browser-free TEA loop + Cmd/Sub scheduler | **Nothing.** Runs unchanged; its only host global is `setTimeout` (in `_Process_sleep`). |
| **C. Render seam** | `virtual-dom/external/virtual-dom.js` | DOM-hardcoded *patcher* | Write a **parallel walker** (`native.js`); never touch the original. |

The load-bearing fact: the vdom **node is renderer-agnostic data**, proven by `Ssr`
walking the exact same node tags to strings while *skipping events*. The native renderer
is "Ssr, but it emits `__fabric_*` mount calls instead of strings" — those calls hit
Canopy's own host, not RN's Fabric runtime.

---

## 2. The third walker (`package/external/native.js`)

Mirrors `virtual-dom.js`'s architecture exactly, swapping DOM ops for `__fabric_*`:

| `virtual-dom.js` (browser) | `native.js` (`__fabric_*` mount ABI) |
|---|---|
| `tNode = { __domNode, __kids }` | `nNode = { __handle, __kids }` |
| `_VirtualDom_render` → `document.createElement` | `_Native_render` → `__fabric_createView` |
| `_VirtualDom_applyFacts` → `setAttribute`/`style`/`addEventListener` | `_Native_factsToProps` → `__fabric_updateProps` |
| `_VirtualDom_updateTNode` (inline diff+patch, no patch objects) | `_Native_updateTNode` (same shape) |
| `_VirtualDom_diffFacts` → minimal prop delta | `_Native_diffApplyFacts` → one `updateProps` |
| keyed reconciliation (key map + LIS moves) | `_Native_updateKeyedKids` (key map + recycle; LIS pending) |
| `_Browser_makeAnimator` (requestAnimationFrame) | `_Native_makeAnimator` (`__fabric_requestFrame`) |
| event → `sendToApp` via `_VirtualDom_makeCallback` | event → `sendToApp` via `_Native_makeCallback` + `_Native_dispatchEvent` |

**Text fast-path** (the §8 crux): a node whose only child is text carries the string as
a `text` *prop* (mirrors the DOM `textContent` fast-path), so a label change is a single
`updateProps({text})` — never a re-mount. The validation asserts exactly this.

### Facts → native props
The organized facts object is read the same way `ssr.js` reads it:
`a__1_STYLE` → the view's `style` prop (Yoga consumes flexbox keys directly — no layout
engine to write), `a__1_ATTR` + plain props → native props, `a__1_EVENT` → registered
callbacks + a `__events` announcement the host uses to decide which gestures to emit.

---

## 3. The seam (`Native.element`)

Replicates `browser.js`'s `element` exactly, swapping two things:

```js
// browser.js                                  // native.js
domNode = args['node']                         rootHandle = args['node'] ?? createView('RCTRootView')
currNode = _VirtualDom_virtualize(domNode)     currNode = null  // nothing to virtualize
_VirtualDom_update(domNode, curr, next, send)  _Native_update(rootN, curr, next, send)
_Browser_makeAnimator (requestAnimationFrame)  _Native_makeAnimator (__fabric_requestFrame)
```

`view(model)`, `init`, `update`, `subscriptions`, and all of `core/` are **unchanged**.
`_Platform_initialize(flagDecoder, args, init, update, subscriptions, stepperBuilder)`
is called with the identical signature.

---

## 4. The host (`host/`)

```
external/native.js  ──__fabric_*──▶  CanopyFabric.cpp (JSI installer, portable)
                                          │ marshals jsi::Value ⇄ strings/ints
                                          ▼
                                     CanopyHost (per-platform mount)
                                     ├─ iOS:     CanopyHostFabric.mm  (UIView + Yoga)
                                     └─ Android: CanopyHost.java      (View + Yoga)
```

The JSI surface (`CanopyFabric.cpp`) is identical on both platforms; only the mount
differs. The host boots the program with `__canopy_boot(rootTag, flags)` and emits
gestures back with `canopyEmitEvent(handle, name, payloadJson)` → `__canopy_dispatchEvent`.

**Host strategy — what's actually built:** the host uses *direct platform views + Yoga*
(binds only to UIKit/Android-View + Yoga's stable public C API — the lowest-risk first
light). There is **no** RCTBridge, **no** Fabric `MountingManager`, **no** `ShadowTree`,
**no** TurboModule; Android uses **plain JNI** (`jni.h`), not fbjni. The exact,
grep-pinned coupling surface is enumerated and CI-enforced in
[`rn-coupling.md`](rn-coupling.md).

**Future option (aspirational, NOT current):** to inherit React Native's full component +
native-module catalog, one *could* back `CanopyHost` with RN's Fabric `MountingManager`
without changing the JS or the JSI surface. This is a possible future direction only — the
present code does not do it, and `rn-coupling.md`'s guard would flag the day it starts to.

---

## 5. The survival rule — and what the build taught us

The 2017 `elm-native-ui` died from coupling to *unstable private internals* on both
sides. The rule: **bind only to stable, public surfaces.** Concretely:

- **JS side:** `native.js` is a normal FFI file with a normal foreign-import boundary,
  binding only to the public `VirtualDom.Node` data shape — not compiler kernel guts.
- **Native side:** the host binds only to *stable, public* surfaces — **JSI** (a tiny
  `jsi::Value` subset), **Hermes** (one symbol: `makeHermesRuntime()`), **Yoga**'s public
  C API (iOS), and **plain JNI** (Android) — never RN's Fabric runtime, RCTBridge,
  TurboModules, or private headers. See [`rn-coupling.md`](rn-coupling.md) for the frozen,
  CI-checked list.

### Packaging note (a real finding from the build)
`native.js` reads `VirtualDom` node internals (`__tag`, `__kids`, `a__1_STYLE`, …) —
**exactly like `canopy/ssr` does.** The compiler emits regular package FFI *verbatim*
but rewrites these `__`-fields in **kernel-trusted** FFI files. So `canopy/native` must
be installed as a **kernel-trusted package alongside `canopy/virtual-dom`** (same trust
class as `ssr`), and must be paired with `canopy/virtual-dom` (whose node shape it
matches) — *not* Elm's original `elm/virtual-dom` (different field names). On a fresh
machine without the `canopy/*` packages registered, the example compiles the fork's
`virtual-dom` source directly (see `examples/counter/README.md`).

---

## 6. App Store guideline 2.5.2 (the one real risk)

Running a JS engine on **bundled** code is explicitly fine — this is why React Native
passes review, and `canopy/native` has the identical posture (`canopy.bundle.js` ships
inside the app, Hermes runs it). The trap is **over-the-air** delivery of *new* Canopy
code that changes behavior: tolerated only within narrow bug-fix limits. **Design for
bundled-and-reviewed as the default; treat OTA as bug-fix-only.** Google Play is more
permissive, so architect to Apple's rule and Android follows. See
[`app-store-2.5.2.md`](app-store-2.5.2.md).

---

## 7. Validation

Two headless harnesses (no device required), both green:

| Harness | What it exercises | Result |
|---|---|---|
| `harness/run.js` | the **source** walker + a faithful mini-runtime double, against a mock Fabric | **17/17 PASS** |
| `harness/run-compiled.js` | the **real `canopy`-compiled bundle** (real `core/runtime.js` scheduler + tree-shaken `native.js`) + Hermes preamble, against a mock Fabric | **14/14 PASS** |

Both assert the §8 criteria: a real native view tree (`RCTRootView > RCTView > RCTText`…,
never a WebView); a tap → Canopy `update` → **exactly one targeted `updateProps`** on the
same label handle (`Count: 0` → `1`); zero `createView`/insert/remove (no re-mount);
counting + reset across taps with the label never re-mounted.

Plus: the Haskell tool builds and its 22 unit tests pass; `canopy-native build` runs the
full pipeline (compile → assemble Hermes bundle → emit Fabric codegen).

---

## 8. Proof-of-concept spec (the bar this cleared)

A Canopy `view` of one native label + buttons; tapping increments `model`; the label
re-renders via a single Fabric `updateProps`. Pass criteria:

1. ✅ real native views (inspectable as `RCTView`/`RCTText`, not a WebView/DOM)
2. ✅ tap → `update` → **one targeted `updateProps`** (not a re-mount)
3. ✅ **zero changes** to `compiler/`, `core/`, or `virtual-dom/`

The third criterion is the whole thesis — and it holds: the only new code is the
`native` package + the host shell + the build tool.
