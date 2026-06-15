# Canopy Native — Master Roadmap to React Native Parity

> **Status:** Reference document. This is THE plan of record for taking Canopy Native from a validated Android prototype to a platform that competes with React Native, such that apps like **Lumen** ship on it natively (Android + iOS).
>
> Synthesized from 8 area plans (linked in §6). Each area plan owns the file-level detail; this document owns the **vision, sequencing, phasing, effort totals, and the immediate next actions**.

---

## 1. Vision & Definition of Done

**Vision:** Canopy apps written in `.can` compile once and run as first-class native apps on Android and iOS — same rendering fidelity, same effect/capability breadth, same animation feel, and the same "edit-and-see-it" developer loop that React Native + Expo give you today. The web target stays the source of truth for the package ecosystem; native re-backs the seams, never forks the packages.

The architecture bet that makes this affordable is already validated: a **portable C++ core** (the `__fabric_*` render seam + the `__canopy_*` effect ABI) plus **per-platform host renderers** (Android `CanopyHost.java` / iOS `CanopyHostFabric.mm`). Adding a capability means re-backing a seam, not rewriting a package.

### Definition of Done — RN-Parity Checklist

We can call Canopy Native a **competitor to React Native** when **all** of the following are true on **both Android and iOS**:

**Rendering & components**
- [ ] `ScrollView` (vertical + horizontal) with momentum, content-size from Yoga.
- [ ] Virtualized lists (windowing) — large lists scroll at 60fps without mounting every row.
- [ ] Keyed-reorder reconciliation via a Longest-Increasing-Subsequence (LIS) pass (no O(n) full re-mount on reorder).
- [ ] `TextInput` — controlled value, focus/blur, submit, keyboard types.
- [ ] `Image` from URL (network) **and** from local/blob source, with `resizeMode`.
- [ ] `Modal` / overlay surface.

**Layout & styling (Yoga/RN parity, ~30 → ~60 keys)**
- [ ] Color parser accepts `rgb()/rgba()/hsl()/hsla()/#hex(3/4/6/8)/named/transparent` everywhere a color is taken (bg/text/border/shadow/gradient).
- [ ] `transform` (translate/scale/rotate/skew/matrix) + `transformOrigin`.
- [ ] `box-shadow` / elevation, `border*` longhands + per-corner radius, `overflow` clip.
- [ ] Linear & radial gradients.
- [ ] `aspectRatio`, `zIndex`, percent + `auto` margins/paddings/insets, `rowGap`/`columnGap`, inset shorthand.
- [ ] Text styling: `lineHeight`, `letterSpacing`, `textDecoration`, `textTransform`.
- [ ] `resizeMode` / `object-fit`, `pointerEvents`.
- [ ] Every style key has a reset-on-null entry (recycled views never leak a prior screen's style).

**Effects, capabilities & transport**
- [ ] Real native **HTTP** transport (OkHttp / NSURLSession) — no DOM `XMLHttpRequest` dependency.
- [ ] Real native **WebSocket** + per-call streaming channels; SSE.
- [ ] **Real billing** (Play Billing v6 / StoreKit 2) with entitlement persistence and restore.
- [ ] Structured native-module error taxonomy (`{code, message}`), bytes-blob bridge.
- [ ] Expo-comparable capability breadth: permissions, files, clipboard, haptics, geolocation, biometrics, push, deep links, camera, audio, video, sensors (codegen-scaffolded).
- [ ] Web-package reuse: `http`/`web-crypto`/`storage`/`url`/`encoding`/`bytes` run **byte-for-byte unmodified** via a `native-webcompat` global layer.

**Animation & gestures (Reanimated 3 + gesture-handler parity)**
- [ ] Native per-frame driver (Choreographer / CADisplayLink) that owns `Animated.Value` slots and writes compositor props (alpha/transform) with **zero JS per frame**.
- [ ] `Native.Animated`: timing/spring/decay/interpolate/parallel/sequence/stagger.
- [ ] `Native.Gesture`: pan/pinch/rotate/fling with simultaneity / require-to-fail composition.
- [ ] `Native.LayoutAnimation`: old→new Yoga-frame tweens.
- [ ] Reconciler clobber-proofing: driver-owned props survive unrelated re-renders.

**Production readiness & developer loop**
- [ ] **Red-box**: every JS→host re-entry site is guarded; JS errors show an overlay, never SIGABRT.
- [ ] Deterministic bundle/asset sync (content-hashed manifest, Gradle-integrated) — no manual `cp`.
- [ ] `canopy-native run` + dev server + Fast Refresh (watch → recompile → push → re-boot).
- [ ] Source maps end-to-end — red-box stacks symbolicate to `.can` lines.
- [ ] Release pipeline: R8/minify, ABI splits (drop x86_64), Hermes HBC precompile, signing, `.aab`.

**Testing & device matrix**
- [ ] `testID` → native a11y tree on **both** hosts (the prerequisite for all device E2E).
- [ ] `Native.Testing` `.can` module shipped (un-phantom the engine).
- [ ] Mock-Fabric harness emits TAP + JUnit, wired into CI (no Android SDK / Mac needed).
- [ ] Appium 2 + WebdriverIO device E2E (the Lumen restore flow, selecting by `testID`).
- [ ] Maestro cross-platform smoke; cloud device matrix (Firebase Test Lab + BrowserStack) with visual baselines, flake control (`__canopy_idle`), and crash symbolication.

**The single litmus test:** Lumen — the full pick → restore → before/after compare → paywall → save → share flow — runs natively on a real iPhone and a real Android device, ships to TestFlight and the Play Store, and passes the same E2E spec on both.

---

## 2. Current State (honest, one paragraph)

Canopy Native is a **validated Android prototype at roughly ~15% of React Native parity**. The two hard architectural seams are done and verified on-device: the `__fabric_*` render seam (`external/native.js` → `CanopyHost.java` over Yoga) mounts and reconciles real view trees, and the C1 native-module ABI (`__canopy_call/cancel/resolve`, the JNI module patterns, the worker→JS-thread `postToJs` hop) is solid and general. Beyond that, the gaps are wide and concrete: styling is a ~30-key flexbox-only subset with a confirmed invisible-UI color bug (`rgb()/hsl()` strings throw and get swallowed to transparent); there is no `ScrollView`, no list virtualization, no `TextInput`, no network `Image`; `http`/`websocket` exist as full effect modules but are 100% DOM `XMLHttpRequest`/`WebSocket` (throw on Hermes), and `billing` is a fake `SharedPreferences` store; there is no animation/gesture subsystem beyond one hardcoded `ValueAnimator` in `BeforeAfterView`; native-module breadth is ~12% of RN; five unguarded JS→host re-entry sites **SIGABRT** instead of showing an error; the bundle reaches the device by a manual `cp`; `testID` is a **no-op** on both hosts (so no driver can find elements); and **iOS is two loose `.mm` files (272 lines) with no Xcode project, no event path, ~12 style keys, and one module registered** — design-complete in the plans but unbuildable on the current Linux box. It works, it's the right architecture, and it is a multi-month build from here.

---

## 3. Dependency Graph / Sequencing

The hard blockers that dictate ordering:

```
                          ┌─────────────────────────────────────────────┐
                          │  PORTABLE C++ CORE (DONE):                   │
                          │  __fabric_* render seam  +  __canopy_* ABI   │
                          │  BlobRegistry · JniModule · postToJs hop     │
                          └───────────────┬─────────────────────────────┘
                                          │ inherited verbatim by iOS
        ┌─────────────────────────────────┼──────────────────────────────────┐
        ▼                                 ▼                                    ▼
┌───────────────┐              ┌─────────────────────┐            ┌───────────────────────┐
│ RED-BOX       │              │ testID → a11y tree  │            │ iOS Xcode PROJECT     │
│ (guard 5 JSI  │              │ (T0)                │            │ bring-up (M0/M1)      │
│  re-entry)    │              │                     │            │                       │
│ ── unblocks ──│              │ ── unblocks ALL ──  │            │ ── unblocks ALL ──    │
│ safe running  │              │ device E2E / matrix │            │ iOS work (every       │
│ of everything │              │ (T3/T4/T5)          │            │ area's iOS milestone) │
└───────┬───────┘              └──────────┬──────────┘            └───────────┬───────────┘
        │                                 │                                   │
        ▼                                 ▼                                   ▼
┌───────────────┐              ┌─────────────────────┐            ┌───────────────────────┐
│ native.js     │              │ Native.Testing.can  │            │ (Mac required from    │
│ setTimeout +  │              │ (un-phantom engine) │            │  here; author all     │
│ asset-sync fix│              │ + mock-Fabric CI    │            │  Swift/C++ on Linux   │
└───────┬───────┘              └─────────────────────┘            │  first)               │
        │                                                          └───────────────────────┘
        ▼
┌─────────────────────────────────────────────────────────────────┐
│ Color parser (M1, layout)  ── blocks every color-taking key ──▶  │
│ borders/shadow/gradient/transform/text-styling                   │
├─────────────────────────────────────────────────────────────────┤
│ Bytes-blob + structured error taxonomy (M1, modules)             │
│   ── must precede capability codegen + HTTP re-backing ──▶        │
├─────────────────────────────────────────────────────────────────┤
│ HTTP re-backing (Net module)                                     │
│   ── transitively unblocks ──▶ analytics, error-tracking,        │
│      graphql, SSE, model/CDN fetch, ALL cloud features           │
├─────────────────────────────────────────────────────────────────┤
│ LIS reconciler (R1) + ScrollView (R2)  ── both block ──▶         │
│   List virtualization (R3)                                       │
├─────────────────────────────────────────────────────────────────┤
│ webcompat globals  ── moves http/crypto/storage/url/encoding ──▶ │
│   into "reusable unmodified" (rides HTTP/Crypto/KeyValue modules)│
├─────────────────────────────────────────────────────────────────┤
│ Anim/gesture driver  ── reuses css transform vocabulary;         │
│   needs reconciler clobber-proofing; static transform from       │
│   layout M4 shares the value mappers                             │
└─────────────────────────────────────────────────────────────────┘
```

**The four load-bearing blockers, stated plainly:**

1. **`testID`-as-a-no-op blocks all device testing.** Until `testID` reaches the platform a11y tree on both hosts (Testing plan **T0**), no Appium/Maestro/XCUITest driver can find elements. Every area's device-E2E and on-device verification is dead until this lands. **P0.**
2. **The iOS Xcode project blocks all iOS work.** Every iOS milestone in every plan (`Ri`, `M9`/`M9`, `A9`, `M6`, all of plan 06) is BLOCKED on `06-ios-bringup M0/M1`. iOS authoring (Swift/ObjC++) is done on Linux first; compile/run/sign needs a Mac.
3. **Red-box blocks safe running.** Five unguarded JS→host re-entry sites SIGABRT today; every other task is harder to debug until the guard + overlay lands. **P0.**
4. **HTTP re-backing blocks all cloud features.** `http` throws on Hermes today. The native Net module transitively unblocks analytics, error-tracking, graphql, SSE, and model/CDN fetch for free (they're transport-agnostic).

**Intra-area orderings worth pinning:**
- Color parser (layout **M1**) blocks borders/shadow/gradient/transform/text-styling. Do first.
- Structured error taxonomy + bytes-blob (modules **M1**) must precede capability codegen (**M4**) so generated capabilities are born structured.
- LIS (**R1**) + ScrollView (**R2**) both block list virtualization (**R3**).
- `native.js` `setTimeout` delay bug (package-reuse **M0**) is **live today** and mis-fires `Process.sleep`/`Time.every` for any reused package — fix before trusting timer-dependent packages.
- The asset-sync manual-`cp` fix (DX) should land alongside red-box so dev iteration is sane.

---

## 4. Phased Plan

Each phase lists its milestones (pulled from the area plans, with their area code), the rough effort, and the **"you can now ship X"** outcome. Effort sizes use the area plans' own scale: **S** ≈ 0.5–1 pw, **M** ≈ 1.5–2 pw, **L** ≈ 3–4 pw, **XL** ≈ 5–8 pw (person-weeks, one engineer).

---

### Phase 0 — Foundational Unblockers

*Make it safe to run, observable, and testable. Nothing else is debuggable until these land.*

| Milestone | Area | Effort | Deliverable |
|---|---|---|---|
| Red-box + graceful error | DX | M | Wrap the 5 JSI re-entry sites in `guardJsCall`; `CanopyError.h/.cpp` (portable, iOS inherits); `CanopyRedBox.java` dev overlay + `CanopyErrorScreen.java` prod; JS error boundaries + unhandled-rejection tracker. |
| Bundle + asset sync pipeline | DX | M | `Assets.hs`, content-hashed `canopy.manifest.json`, Gradle `syncCanopyAssets` task + `preBuild` dep, `MainActivity` manifest-driven loader with sha verify. Kills the manual `cp`. |
| `native.js`/preamble correctness | Pkg-Reuse | S | Fix `Bundle.hs:48` `setTimeout` delay bug; splice `webcompat.js`; pure-JS shims (TextEncoder/Decoder, atob/btoa, URL, Blob, FormData, structuredClone, queueMicrotask, performance, setInterval). |
| `testID` → native a11y tree (Android + iOS) | Testing | M | `CanopyHost.java` applyProps consumes `testID`→content-description + keyed `setTag`; AccessibilityDelegate (label/role/hint); `res/values/ids.xml`; reset-on-recycle; iOS `accessibilityIdentifier` (code ready, run blocked). **P0 — unblocks ALL device testing.** |
| `Native.Testing` `.can` module | Testing | S | New `src/Native/Testing.can` binding the 7 engine fns; expose in `canopy.json`; un-phantoms `Test/Native.can` + `Test/NativeCss.can`. |
| Mock-Fabric harness → TAP/JUnit + CI | Testing | M | `report.js` TAP14 + JUnit; port `run.js`/`run-echo.js` + new `run-a11y.js`; `.github/workflows/native-tests.yml` (no Android SDK / Mac needed). |
| Anim math core + harness | Anim | M | `harness/anim-math.js` (timing/spring/decay/interpolate single source of truth) + `mock-driver.js` steppable clock + golden vectors. Pure JS — unblocks all later anim tests. |

**Effort:** ~10 pw.
**You can now ship:** a **debuggable, CI-gated dev build** — JS errors show a red-box instead of crashing, the bundle syncs deterministically, timers work, the test engine compiles, every commit runs the mock-Fabric harness, and `testID` is queryable so device E2E can begin. **This phase unblocks everything downstream.**

---

### Phase 1 — Android RN-Parity

*Make Android a real RN competitor: the missing components, the missing styles, real transport, real billing.*

| Milestone | Area | Effort | Deliverable |
|---|---|---|---|
| Color foundation | Layout | S | `CanopyColor.java` (#hex 3/4/6/8 + rgb/rgba/hsl/hsla/named/transparent); repoint all host color call-sites; remove bridge 8-hex reorder in the **same atomic commit**. Fixes the invisible-UI bug. **Blocks all color-taking keys.** |
| Borders + corners + overflow clip | Layout | M | `Native.Css` border/inset shorthand expansion; host longhand cases + per-corner radius; `BorderDrawable`; `applyBackground`→`applyDecoration`; `applyClip`; resets. |
| box-shadow / elevation | Layout | M | `ShadowSpec` + dual Android path (elevation default, `Paint.setShadowLayer` precise); bridge mapper; resets. |
| transform + transformOrigin | Layout | M | `transformValue` bridge mapper (fixes px-inside-`f(...)` bug); host parse → `setTranslation/Scale/Rotation/setAnimationMatrix`; pivot deferred to `onLayout`; resets. |
| gradients | Layout | M | Host parse of linear/radial gradient strings → `GradientDrawable`/`LinearGradient` shader; pass-through guard; resets. |
| layout finishers | Layout | S | `aspectRatio`, `zIndex` via `getChildDrawingOrder`, percent+auto spacing, `rowGap`/`columnGap`, inset shorthand. |
| text styling | Layout | S | `lineHeight`, `letterSpacing` (px→em via tracked fontSize), `textDecoration`, `textTransform`; leaf `yoga.dirty`; resets. |
| resizeMode + pointerEvents | Layout | S | `object-fit`→`setScaleType`; `pointerEvents` gating via touch interception; resets. |
| LIS reconciler | Render | M | Longest-Increasing-Subsequence keyed-reorder pass (no full re-mount on reorder). |
| ScrollView | Render | L | JS windowing over a real ScrollView; content-size from Yoga; momentum. |
| List virtualization | Render | L | Windowing; depends on **R1 + R2**. |
| TextInput | Render | L | Controlled value, focus/blur, submit, keyboard types. |
| Image source | Render | M | Two paths — network (URL) + local/blob — with `resizeMode`. |
| Modal | Render | L | Overlay surface. |
| Bytes-blob + structured error taxonomy | Modules | M | `jniBlobPutBytes/GetBytes` + `bytes` blob kind; `Rejected {code,message}`; migrate the 6 existing capabilities **before** the fan-out. |
| HTTP re-backing (Net module) | Modules | L | `NetModule.java` (OkHttp); `http-native.js` twin (same exports); FFI override in `Build.hs`; StreamingJniModule registration. **Transitively unblocks analytics/error-tracking/graphql/SSE/model-fetch.** |
| WebSocket re-backing + per-call streaming | Modules | M | `Net.wsOpen/wsSend/wsClose`; `websocket-native.js` twin; per-call channels; SSE bonus. |
| Real Play Billing v6 | Modules | L | Rewrite `BillingModule.java` (v6: query/launch/acknowledge/restore); config-driven SKUs; callId parking across the activity round-trip; license-test E2E. |
| Sync JSI globals + host timer (Android) | Pkg-Reuse | M | `__canopy_setTimeout/clearTimeout`, `__canopy_random`, `__canopy_blob_read/release`; drain microtasks after every `postToJs`. |
| Http module + XHR shim | Pkg-Reuse | L | `HttpModule.java` over OkHttp + XHR/Blob/FormData shim; moves `http`+`beacon` to reusable-unmodified. |
| KeyValue module + localStorage shim | Pkg-Reuse | M | `KeyValueModule.java` + boot-snapshot mirror; moves `storage` to reusable-unmodified. |
| Crypto module + crypto shim | Pkg-Reuse | L | `CryptoModule.java` (javax.crypto/SecureRandom) + `crypto.subtle` shim; moves `web-crypto`+`auth` to reusable-unmodified. |
| Downstream reuse validation | Pkg-Reuse | S | Run auth/streams/i18n/beacon against new backings; `navigator.language`; document the shipped reuse matrix. |
| Static transform/shadow/overflow/border in host | Anim | S | `Native.Attributes` helpers reusing css `transformToString`; closes the static-path styling-drop gap (overlaps Layout M2–M4). |
| Horizontal scroll + E2E | Render | M | Horizontal `ScrollView` + first device E2E (rides Phase 0 `testID`). |

**Effort:** ~38 pw.
**You can now ship:** a **feature-complete Android Canopy app** — full styling fidelity, scrolling virtualized lists, text input, network images, modals, real HTTP/WebSocket transport (so every cloud feature works), unmodified reuse of the `http`/`crypto`/`storage`/`url`/`encoding` packages, and **real in-app purchases**. Lumen's data/UI/billing layers run on Android. (Animation polish and the release pipeline are Phase 2.)

---

### Phase 2 — Animation, Gestures, Release & E2E (Android)

*Make it feel native and make it shippable.*

| Milestone | Area | Effort | Deliverable |
|---|---|---|---|
| `Native.Animated` `.can` + ABI | Anim | M | `Animated.can` (Value/timing/spring/interpolate/parallel/sequence/start); `native-animated.js` spec encoder + `__anim_*` actuators; walker scan for `__animBindings`. |
| Android Choreographer driver + host bind | Anim | L | `CanopyAnimDriver.java` (real vsync loop); `CanopyAnim.{h,cpp}` JSI installer; applyProps/applyStyle binding + driver-owned guard. |
| Reconciler clobber-proofing + handle teardown | Anim | S | `_Native_releaseEvents` unbinds dead handles; host `isDriverOwned` skip so re-render can't null a live transform/opacity. |
| `Native.Gesture` + Android coordinator | Anim | L | `Gesture.can` (pan/pinch/rotation/fling, simultaneous/exclusive/race/requireToFail); `CanopyGestureCoordinator.java` binding recognizers directly to driver values (zero JS per sample); fling→decay. |
| LayoutAnimation | Anim | M | `LayoutAnimation.can`, `__layout_configureNext`, `CanopyLayoutAnimator.java`, old→new Yoga-frame tween. |
| `Native.Testing` anim/gesture probes | Anim | S | `testAnimValueAfter` probes + canopy test cases. |
| Capability codegen (`gen-capability`) | Modules | L | `Capability.hs` + `CapabilityCodegen.hs` emitting `.can` + Java + Swift stub + registrations + mock from one spec. **The only realistic route from 12% → Expo breadth.** |
| Permissions + Files + Clipboard + Haptics | Modules | L | 4 capabilities via codegen; shared `PermissionRequester`; re-back `file`/`storage`. |
| Geolocation + Biometrics + Push + Links | Modules | XL | 4 capabilities (3 streaming Subs): FusedLocation, BiometricPrompt, FCM push, deep/universal links. Depends on Permissions. |
| Shared WorkerPool + receipt validation + background | Modules | M | `canopy::WorkerPool`; server-side receipt validation; WorkManager background-task design (host-native work emitting into a Sub on foreground). |
| Dev loop: `canopy-native run` + Fast Refresh | DX | L | `Run.hs` + `DevServer.hs`; Node `canopy-dev-server.js` (ws + chokidar); `DevClient.java` (okhttp WS); `__canopy_teardown/getState/bootWithState`; `adb reverse`. |
| Source maps end-to-end | DX | M | `shiftSourceMap` + `sourceMappingURL`; Hermes map load; `__canopy_symbolicate` / `Error.prepareStackTrace` → red-box stacks point to `.can`. |
| Release pipeline | DX | L | `release` buildType + signingConfigs + ABI splits (drop x86_64) + Hermes HBC precompile + `proguard-rules.pro` (JNI/Yoga/ORT keep-rules) + `.aab`. |
| CI: emulator build + smoke | DX | M | `.github/workflows/canopy-native.yml`: stack build/test + node harness gate + `assembleDebug` + emulator smoke asserting a mounted tree. |
| E2E driver + testID prereq (CI feed) | DX | M | `tool/e2e/*`, `CanopyHostJni.dumpTree`, adb-driven Node E2E feeding the CI smoke job. |
| Device E2E: Appium 2 + WebdriverIO (TS) | Testing | L | `native/e2e` project (UIAutomator2/XCUITest configs, `by(testID)`/`waitIdle`/`tapById`); runnable `lumen-restore.e2e.ts`; test-flavor build with mock Photos/Billing/Notify + real RestoreEngine. Android runnable now. |
| Maestro YAML cross-platform smoke | Testing | S | `lumen-smoke.yaml` selecting by `id`; JUnit into the per-PR gate. |
| Camera + Audio + Video + Sensors | Modules | XL | CameraX/MediaRecorder/MediaPlayer/SensorManager (bytes-blob heavy) + render-side view-managers for camera preview + video surface (coordinate with Render plan). |

**Effort:** ~50 pw.
**You can now ship:** a **polished, releasable Android app with a real developer loop** — 60fps native-driven animations and gestures (zero JS per frame), Expo-comparable capability breadth (permissions, files, geolocation, biometrics, push, links, camera, audio, video, sensors), Fast Refresh, symbolicated crashes, a signed `.aab` to the Play Store, and a green Appium/Maestro E2E matrix on the local emulator. **Lumen ships on Android.**

---

### Phase 3 — iOS Bring-up to Parity

*Everything authored on Linux in Phases 0–2 now compiles, runs, and signs on a Mac. iOS reuses the entire portable C++ core verbatim and skips all JNI complexity.*

| Milestone | Area | Effort | Deliverable |
|---|---|---|---|
| Project bring-up | iOS | L | `CanopyHost.xcodeproj` + `CanopyHostCore` target; vendor Hermes.xcframework + JSI + Yoga pinned to **0.76.9**; shared C++ by reference minus JNI; guard `BillingModule.cpp` JNI behind `#if defined(__ANDROID__)`. **Mac-gated. Blocks all iOS work.** |
| Boots a blank surface on the simulator | iOS | M | AppDelegate/SceneDelegate/VC stand up Hermes; `installCanopyFabric` + `installCanopyModules`; `globalBlobRegistry()` symbol; eval bundle; `canopyBoot`; Echo registered. First light. |
| Renderer parity | iOS | L | Rewrite `CanopyHostFabric.mm` to `CanopyHost.java` parity: full applyStyle + reset-on-null, leaf measure, `CanopyContainerView`/layoutSubviews, color/percent/auto/edges. |
| Events + text + gestures | iOS | M | host→emit + setEvents; press/longPress; `CanopyGestures.swift` pan/tap; UITextField delegate. Fixes the stubbed event seam (`CanopyHostFabric.mm:104-110`). |
| testID + scroll + image | iOS | M | `testID`→`accessibilityIdentifier`; `CanopyScrollView` (contentSize from Yoga); blob→UIImage + resizeMode. XCUITest can find elements. |
| Layout & styling parity port (M1–M8) | Layout | L | Mirror the ~30 Android keys in `CanopyHostFabric.mm`: CGAffineTransform, layer shadow/border, clipsToBounds, CAGradientLayer, aspectRatio, zPosition, contentMode, NSAttributedString, hitTest pointerEvents. Shared test vectors keep lockstep. |
| Capability modules (non-ML) | iOS | L | `CanopyNativeModule` glue + 7 modules: PHPicker, add-only Photos, UIActivityViewController, Keychain, UNUserNotificationCenter, ImageIO, Lifecycle. Info.plist + entitlements. |
| iOS native module + webcompat backings | Modules + Pkg-Reuse | XL | All Swift/ObjC++ NativeModules (call `ctx.complete` directly — no JNI); StoreKit 2 Billing; port Http/Crypto/KeyValue to `.mm` (NSURLSession/CryptoKit/SQLite) + sync JSI globals into the iOS controller. |
| Before/After compositor | iOS | M | `CanopyBeforeAfterView.swift`: two layers + CALayer mask, pan/double-tap, wipe emits, 60fps zero-JS. |
| Core ML backend | iOS | L | Convert ESPCN ONNX → `restore.mlpackage` via coremltools; `CoreMLRestoreModule.mm` reusing portable `RestoreColorOps`; ANE deviceTier. |
| Animation/gesture iOS driver | Anim | L | `CADisplayLink` driver writing CALayer transform/alpha; UIKit recognizers with native simultaneity / `require(toFail:)`. |
| Lumen runs on iOS | iOS | L | All capabilities wired; rotation/keyboard via layoutSubviews; XCUITest green on device; signing/provisioning + TestFlight build. |
| Device E2E iOS leg + cloud matrix | Testing | XL | `matrix-local.sh` sim sweep; BrowserStack App Automate (iOS); `wdio-image-comparison` baselines; video/trace; flake control via `__canopy_idle`; crash symbolication. Gated to main/rc-*. |
| iOS hardening / DX | iOS + DX | M | red-box UIKit overlay (catch `jsi::JSError`); asset Copy-Bundle-Resources phase; iOS dev-loop reload; snapshot CI on a macOS runner. |

**Effort:** ~58 pw.
**You can now ship:** **Lumen natively on iPhone.** Full render + style + event + animation parity with Android, all 9 capabilities re-backed, Core ML super-resolution on the ANE, StoreKit 2 billing, the Before/After compositor at 60fps, and a green XCUITest/BrowserStack matrix. Canopy Native is now **cross-platform at parity** and ships to both stores.

---

### Phase 4 — Ecosystem Breadth, OTA & Polish

*Close the long tail to genuinely rival Expo's reach.*

| Milestone | Area | Effort | Deliverable |
|---|---|---|---|
| Capability fan-out via codegen | Modules | L | Drive the remaining roadmap capabilities (the 12+ Expo-comparable set) through `gen-capability` on both platforms. |
| `Native.Attributes` parity helpers | Layout | S | Thin `VirtualDom.style` wrappers for the non-css path (transform/boxShadow/border*/overflow/zIndex/aspectRatio/resizeMode/pointerEvents/percent+auto); update `@docs`. |
| `Native.Attributes` parity (modules + iOS port) | Modules | XL | StoreKit2 + all remaining iOS NativeModule backings; port all registrations to the iOS boot. |
| Handle harmonization + hardening cleanup | Pkg-Reuse | M | Single BlobRegistry currency; audit all microtask drains; retain/release contract per module; packageize `webcompat.js`; CI on shim/module changes. |
| OTA (design → implementation) + crash symbolication | DX | L | `CanopyUpdater.java` (signed bundle manifest + atomic swap + rollback, reusing the Phase-0 manifest + HBC); archive `.map` + unstripped `.so`; ndk-stack/addr2line + Hermes source-map symbolication. |
| Device E2E + perf assertion (anim) | Anim | M | `lumen-probe` extension; golden-vector on-device parity (Java/ObjC vs JS integrator); logcat proof of no-JS-per-frame. |
| Horizontal scroll, Modal, list polish; iOS host (Ri finishers) | Render | XL | Remaining component polish; iOS host parity finishers. |
| Cross-device matrix steady-state | Testing | XL | Full Firebase Test Lab + BrowserStack sharded matrix, visual baselines per device, quarantine/flake control, gated to main/rc-*. |

**Effort:** ~50 pw.
**You can now ship:** **a platform that genuinely rivals Expo** — full capability breadth on both platforms, over-the-air updates with rollback, end-to-end crash symbolication, a steady-state cross-device cloud matrix with visual regression, and the developer-experience polish (parity helpers, hardened reuse) that makes Canopy Native a default choice rather than a prototype.

---

## 5. Effort Totals & Honest Timeline

Effort is **rough person-weeks (pw)** for a single engineer, summed from the area-plan milestone sizes (S≈0.75, M≈1.75, L≈3.5, XL≈6.5 pw). These are planning estimates, not commitments.

| Phase | Theme | Effort (pw) |
|---|---|---|
| **Phase 0** | Foundational unblockers (safe/observable/testable) | **~10** |
| **Phase 1** | Android RN-parity (components, styles, transport, billing) | **~38** |
| **Phase 2** | Animation, gestures, release, dev-loop, E2E (Android) | **~50** |
| **Phase 3** | iOS bring-up to parity (incl. Core ML, all iOS capabilities) | **~58** |
| **Phase 4** | Ecosystem breadth, OTA, polish | **~50** |
| | **TOTAL** | **~206 pw** |

**Honest read on timeline:**
- **~206 person-weeks** is **~4 person-years**. With **one** engineer this is unrealistic as a single push; with a **focused team of 3–4** working in parallel along the dependency graph, it is roughly a **12–18 month** effort to full two-platform parity.
- **Phase 0 (~10 pw) is the highest-leverage spend** — about 2 months for one engineer, and it unblocks parallelism for everyone else. Do it first, do it well.
- **A shippable Android app (Phases 0–2, ~98 pw)** is the first real milestone: roughly **6–9 months** with 2–3 engineers. Lumen on Android is reachable well before iOS.
- **iOS (Phase 3) is gated on a Mac** and on a paid Apple Developer account. All Swift/C++/script authoring is done on Linux first so scarce Mac time is pure compile/run/sign — but the **~58 pw** still represents the single largest phase, and it cannot start its run legs until `06-ios-bringup M0` lands.
- **This is a multi-month, multi-engineer build.** The architecture is proven and the path is clear, but there is no version of this that is "a few weeks." Plan it as a quarters-long program.

---

## 6. The 8 Area Plans

| # | Area | Plan file |
|---|---|---|
| 01 | Rendering & Components | [`01-rendering-and-components.md`](/home/quinten/projects/canopy/native/plans/01-rendering-and-components.md) |
| 02 | Layout & Styling | [`02-layout-and-styling.md`](/home/quinten/projects/canopy/native/plans/02-layout-and-styling.md) |
| 03 | Native Modules & HTTP | [`03-native-modules-and-http.md`](/home/quinten/projects/canopy/native/plans/03-native-modules-and-http.md) |
| 04 | Animation & Gestures | [`04-animation-and-gestures.md`](/home/quinten/projects/canopy/native/plans/04-animation-and-gestures.md) |
| 05 | Web Package Reuse & Runtime | [`05-web-package-reuse-and-runtime.md`](/home/quinten/projects/canopy/native/plans/05-web-package-reuse-and-runtime.md) |
| 06 | iOS Bring-up | [`06-ios-bringup.md`](/home/quinten/projects/canopy/native/plans/06-ios-bringup.md) |
| 07 | Production Readiness & DX | [`07-production-readiness-and-dx.md`](/home/quinten/projects/canopy/native/plans/07-production-readiness-and-dx.md) |
| 08 | Testing & Device Matrix | [`08-testing-and-device-matrix.md`](/home/quinten/projects/canopy/native/plans/08-testing-and-device-matrix.md) |

---

## 7. Immediate Next Actions

The first concrete tickets to implement **now** — the cheap, high-leverage ones that unblock everyone else. Ordered for impact; the first four are independent and can run in parallel.

1. **[DX] Red-box the 5 JSI re-entry sites.** Add `host/shared/cpp/CanopyError.h/.cpp` with `guardJsCall`; wrap `canopyBoot` (`CanopyFabric.cpp:117`), `canopyEmitEvent` (`:105`), `canopyResolveCall` (`CanopyModules.cpp:118`), the installFn HostFunctions, and `evaluateJavaScript` (`CanopyHostJni.cpp:223`); add `CanopyRedBox.java` overlay. *Stops the SIGABRT footgun; portable C++ so iOS inherits it.* **(M)**

2. **[Pkg-Reuse] Fix the live `setTimeout` delay bug + splice webcompat.** Fix `Bundle.hs:48` (it ignores `_ms`), add the `webcompat.js` splice in `Build.hs:finishBundle`, ship the pure-JS shims (TextEncoder/URL/Blob/FormData/queueMicrotask/setInterval). *One-line bug breaks `Process.sleep`/`Time.every` today; cheap, unblocks url/encoding/bytes reuse with zero host work.* **(S)**

3. **[Testing] Wire `testID` → native a11y tree (T0).** `CanopyHost.java` applyProps consumes `testID`→content-description + keyed `setTag(R.id.canopy_testid)`; add `res/values/ids.xml`; reset-on-recycle; author the iOS `accessibilityIdentifier` path ready (run blocked). *P0 — every device-test layer is dead until this lands.* **(M)**

4. **[Layout] Land the color foundation (M1) as one atomic commit.** New `views/CanopyColor.java` (#hex 3/4/6/8 + rgb/rgba/hsl/hsla/named/transparent); repoint host color call-sites (`:282,:397,:511`); **remove the bridge 8-hex reorder in the same commit** so existing hex bgs don't flip channels. *Fixes the confirmed invisible-UI bug; unblocks borders/shadow/gradient/transform/text-styling.* **(S)**

5. **[Testing] Un-phantom `Native.Testing`.** New `src/Native/Testing.can` binding the 7 engine fns; expose in `canopy.json`; add `testPropValue`/`_Native_isIdle` exports. *Makes `Test/Native.can` + `Test/NativeCss.can` compile; independent of T0, lands immediately.* **(S)**

6. **[DX] Bundle/asset sync pipeline.** `tool/src/Canopy/Native/Assets.hs`, content-hashed `canopy.manifest.json`, Gradle `syncCanopyAssets` + `preBuild` dep, manifest-driven `MainActivity` loader with sha verify. *Kills the manual `cp`; makes iteration deterministic and catches drift at boot.* **(M)**

> After these six, the next wave is: **[Modules] bytes-blob + structured error taxonomy (M1)** → **[Modules] HTTP re-backing (Net module)** — the pair that unblocks every cloud feature — run in parallel with **[Render] LIS reconciler (R1)** and **[Anim] anim-math core + harness (A1)**.
