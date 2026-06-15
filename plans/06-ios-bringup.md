# 06 — iOS Bring-Up to Android-Host Parity

**Area:** `ios-bringup`
**Goal:** Stand up a real, buildable iOS host that reaches feature parity with the Android host (`host/android/...`), so a `Native.element` Canopy program — ultimately Lumen — runs natively on iPhone/iPad with the same `__fabric_*` render seam, the same `__canopy_*` effect ABI, the same shared C++ blob/ORT/image core, and the same capability set (picker, save, share, notify, storage, billing, lifecycle, before/after wipe, ML restore).

> **This is the single largest gap in Canopy Native.** RN is iOS-first; today iOS is **two loose `.mm` files, 272 lines total, with no Xcode project, no event path, no native modules, no ML backend, and `testID`/`accessibilityIdentifier` ignored.** Android is a validated prototype; iOS has never compiled.

---

## 0. Orientation — what already exists, with evidence

### 0.1 The portable contract iOS must satisfy (already done, shared)

The architecture deliberately splits **portable C++** (binds only to `<jsi/jsi.h>`) from **per-platform mount/runtime**. iOS reuses the portable half verbatim; it only re-backs the platform half. The portable surfaces:

- **Render seam** `__fabric_*` — `host/shared/cpp/CanopyFabric.h:32-58` defines the abstract `CanopyHost` (createView / updateProps / insertChild / removeChild / setRoot / setEvents / requestFrame). `CanopyFabric.cpp:46-99` installs the 7 globals via `JSON.stringify`/`parse` marshalling; `canopyEmitEvent` (`:101-110`) and `canopyBoot` (`:112-119`) are the event-in and boot calls. **This file compiles on iOS unchanged.**
- **Effect ABI** `__canopy_*` — `host/shared/cpp/CanopyModules.h:44-100` (`CallContext`, `NativeModule`, `ModuleRegistry`) + `CanopyModules.cpp:35-121`. One dispatcher `__canopy_call(module,method,argsJson,callId)`, `__canopy_cancel`, host-calls-`__canopy_resolve`. The registry holds `rt_` + a host-set `postToJs` hop (`CanopyModules.h:79-80`). **Compiles on iOS unchanged.**
- **Blob registry** — `CanopyBlobs.{h,cpp}` — opaque `int → Blob{kind,width,height,bytes}`. `RestoreEngineModule.cpp:17-19` forward-declares `globalBlobRegistry()`; on Android that symbol lives in `CanopyJni.cpp:173-176`. **On iOS we must provide that one definition** (it is the only `globalBlobRegistry()` Android-side definition that is JNI-coupled).
- **Image ops** — `CanopyImage.{h,cpp}` — `imageCompositeOver`, `imageWipeColumns` over RGBA blobs. Portable; **iOS reuses verbatim** (`CanopyImage.h:9` "iOS can reuse it verbatim").
- **ORT inference** — `RestoreEngineModule.{h,cpp}` — `RestoreEngineModule.h:36-37` already states "Android wires the AAsset read … iOS wires the NSBundle read — both just call setModelBytes()." The C++ body is portable; **the plan mandates Core ML over ORT on iOS** (see §6), so the iOS variant is a re-back of `RestoreEngineModule`, not a reuse.

### 0.2 The Android host pieces iOS must mirror (the reference)

| Android file | Lines | iOS analog (this plan) |
|---|---|---|
| `CanopyHost.java` | 513 | `CanopyHostFabric.mm` (full rewrite; current stub is 191 lines) |
| `views/BeforeAfterView.java` | 258 | `CanopyBeforeAfterView.swift` (Core Animation) |
| `views/CanopyGestures.java` | 168 | `CanopyGestures.swift` (UIGestureRecognizers) |
| `jni/CanopyHostJni.cpp` (boot+postToJs+console+emit) | 268 | `CanopyHostViewController.mm` (boot) + `CanopyModuleHost.mm` (registry/postToJs) |
| `MainActivity.java` (picker launchers, model bytes, back) | 144 | `AppDelegate.swift` + `SceneDelegate.swift` + VC |
| `CanopyJni.cpp` (blob bridge, JniModule, resolveModule) | 321 | `CanopyBlobRegistryHost.mm` (`globalBlobRegistry` + UIImage↔Blob) — **no JNI; Obj-C++ NativeModules call `ctx.complete` directly** |
| `modules/PhotosModule.java` | 203 | `PhotosModule.swift` (PHPickerViewController) |
| `modules/AlbumModule.java` | 161 | `AlbumModule.swift` (PHPhotoLibrary add-only) |
| `modules/ShareImageModule.java` | 198 | `ShareImageModule.swift` (UIActivityViewController) |
| `modules/StorageSecureModule.java` | 166 | `StorageSecureModule.swift` (Keychain / UserDefaults) |
| `modules/NotifyModule.java` | 149 | `NotifyModule.swift` (UNUserNotificationCenter) |
| `modules/ImageModule.java` | 270 | `ImageModule.swift` (UIImage/ImageIO decode/resize/encode; composite via shared C++) |
| `modules/BillingModule.java` (fake) + `BillingModule.cpp` (stream) | 216+122 | `BillingModule.swift` (StoreKit 2) re-backing the **portable** `BillingModule.cpp` stream half |
| `modules/LifecycleModule.java` + `AppShellModule.java` + `StreamingBridge.java` + `StreamingJniModule.cpp` | 202+161+36+147 | `LifecycleModule.swift` + `AppShellModule.swift` over a small iOS `CanopyStreamModule` (UIKit notifications) |

### 0.3 The crucial detail iOS gets to skip: no JNI

On Android the worker→JS hop goes worker → C++ `postToJs` → `CanopyHostJni.scheduleOnJs(long)` Looper → `runJsCallback` → `__canopy_resolve` (`CanopyHostJni.cpp:60-69`, `:233-246`). Every Java capability is reached through `callJavaModule` JNI reflection (`CanopyJni.cpp:87-126`) and resolves through `resolveModule` JNI (`CanopyJni.cpp:308-319`).

**iOS has none of this.** Obj-C++ can hold the `jsi::Runtime*` and the registry directly. A capability is an Obj-C++ class wrapping a `canopy::NativeModule` subclass; `ctx.complete(err,result)` is called directly (it already hops via the registry's `postToJs`, which on iOS is `dispatch_async(main)` — `CanopyHostViewController.mm:59-61`). So iOS modules are **simpler** than Android's two-language (C++ JniModule ↔ Java) bounce. The shared C++ `JniModule`, `StreamingJniModule`, and the Android `BillingModule.cpp` JNI export are **NOT compiled on iOS**.

### 0.4 Current iOS gaps (file:line)

- `CanopyHostFabric.mm:104-110` — `setEvents` only stores the names string; the comment literally says "TODO: wire to your runtime pointer + UITapGestureRecognizer". **No event ever fires.** `canopyEmitEvent` is never called.
- `CanopyHostFabric.mm:130-162` — `applyProps`/`applyStyle` handle ~12 keys (width/height/flex/padding/margin/flexDirection/bg/color/fontSize/borderRadius). The Android host handles ~60 (`CanopyHost.java:226-379`), including the reset-on-null discipline (`:324-379`) that the diff path in `native.js:500-510` depends on. iOS drops density scaling, percent/auto dims, all the margin/padding edges, position, justify/align, fontWeight, textAlign, opacity, gap, flexWrap, min/max.
- `CanopyHostFabric.mm:118-128` — `makeView` has no `BeforeAfter`, no `CanopyBitmap`, no `testID`→`accessibilityIdentifier`, no `bitmapHandle` rendering.
- `CanopyHostViewController.mm:66` — only `EchoModule` is registered. No Photos/Album/Share/Storage/Notify/Image/Billing/Lifecycle/AppShell/RestoreEngine. No model-bytes handoff.
- **No Xcode project / Swift Package** anywhere under `host/ios/`. `host/ios/CanopyHost/` holds only the two `.mm` files. No `Info.plist`, no entitlements, no signing, no `Hermes.xcframework`, no Yoga.
- `relayout()` (`CanopyHostFabric.mm:164-179`) runs on every `insertChild`/`updateProps` synchronously and re-lays the whole tree from `surface_.bounds` — fine for first light, but it ignores `requestRelayout` coalescing and never re-runs on rotation/keyboard.

---

## 1. Target design (RN-parity iOS host)

### 1.1 Project shape — an Xcode app target + an SPM/CocoaPods core

```
host/ios/
├── CanopyHost.xcodeproj/                # the app target (created on a Mac, checked in)
├── CanopyHostApp/
│   ├── AppDelegate.swift                # UIApplication entry; PHPicker/back hooks live on the active scene
│   ├── SceneDelegate.swift              # window → CanopyHostViewController as root
│   ├── Info.plist                       # NSPhotoLibraryAddUsageDescription, UIBackgroundModes, etc.
│   ├── CanopyHost.entitlements          # keychain-access-groups, in-app-purchase (StoreKit)
│   └── Resources/
│       ├── canopy.bundle.js             # the compiled bundle (build phase copies it)
│       └── models/restore.mlpackage     # Core ML model (converted from the ONNX, §6)
├── CanopyHostCore/                      # the host engine (static lib / SPM target)
│   ├── CanopyHostViewController.mm      # boot: Hermes → installCanopyFabric → installCanopyModules → eval → boot
│   ├── CanopyHostFabric.mm              # CanopyHost impl: UIView + Yoga (the §2 rewrite)
│   ├── CanopyModuleHost.mm/.h           # ModuleRegistry owner + postToJs + registerAll(); console polyfill
│   ├── CanopyBlobRegistryHost.mm        # globalBlobRegistry() def + UIImage↔Blob bridge (the §0.1 missing symbol)
│   ├── Views/
│   │   ├── CanopyBeforeAfterView.swift  # Core Animation wipe compositor (§4)
│   │   ├── CanopyScrollDelegate.swift   # UIScrollView contentSize from Yoga (§2.5)
│   │   └── CanopyTextInputDelegate.swift# UITextFieldDelegate → changeText/submit/focus/blur (§3.3)
│   ├── Gestures/CanopyGestures.swift    # UIGestureRecognizers → event ABI (§3)
│   ├── ML/CoreMLRestoreModule.{h,mm}    # Core ML NativeModule (replaces ORT on iOS, §6)
│   └── Modules/
│       ├── PhotosModule.swift  AlbumModule.swift  ShareImageModule.swift
│       ├── StorageSecureModule.swift  NotifyModule.swift  ImageModule.swift
│       ├── BillingModule.swift  LifecycleModule.swift  AppShellModule.swift
│       └── CanopyNativeModule.{h,mm}    # the Obj-C++↔C++ NativeModule glue base (§5.1)
├── Frameworks/
│   ├── hermes.xcframework               # vendored (matches Android's 0.76.9 hermes), or built
│   ├── jsi  (headers)                   # from the same RN release
│   └── Yoga  (xcframework or SPM)       # facebook/yoga, public C API only
└── Podfile / Package.swift              # whichever dependency story we pick (§1.2)
```

The **shared C++** is added by reference to `CanopyHostCore` (same files Android's CMake lists, minus the JNI-only ones):

- **Compile on iOS:** `CanopyFabric.cpp`, `CanopyModules.cpp`, `CanopyBlobs.cpp`, `EchoModule.cpp`, `CanopyImage.cpp`, `BillingModule.cpp` (stream half — but its **JNI export at `:111-122` must be `#if !TARGET_OS_*`-guarded or moved**; see §5.4).
- **Do NOT compile on iOS:** `CanopyJni.cpp` (JNI), `StreamingJniModule.cpp` (JNI), `CanopyHostJni.cpp` (Android boot). `RestoreEngineModule.cpp` is replaced by the Core ML module (§6); we keep ORT off iOS to honor the plan's "Core ML over ORT" mandate.

### 1.2 Dependency strategy — Hermes + JSI + Yoga without React Native

Three things must be on the link line. The survival rule (`README.md:42-52`) says bind only to UIKit + Yoga's stable public C API; we extend it to Hermes' stable `makeHermesRuntime` + JSI.

1. **Hermes** — `CanopyHostViewController.mm:14,44` already `#import <hermes/hermes.h>` and calls `facebook::hermes::makeHermesRuntime()`. We vendor **`hermes.xcframework`** at the SAME version Android uses (0.76.9; see Android CMake `host/android/app/src/main/cpp/CMakeLists.txt:5` "0.76.9 hermes-android"). Two sources: (a) the `hermes-engine` pod from that RN release (the `.xcframework` ships in the npm tarball / pod), or (b) build Hermes from source on the Mac (`hermes/utils/build-ios-framework.sh`). Vendoring the prebuilt is faster and keeps JSI ABI-matched.
2. **JSI** — header-only on the consumer side; `jsi.h`/`jsi-inl.h` come from `host/shared/third_party/jsi` (already vendored, `host/shared/third_party/jsi/jsi/jsi.h`) OR from the Hermes xcframework's headers. Use the same set so `Value`/`Runtime` ABI matches the linked Hermes.
3. **Yoga** — `CanopyHostFabric.mm:20` `#import <yoga/Yoga.h>`. Options: (a) the `Yoga` pod from the same RN release, (b) `facebook/yoga` SPM package (it has a `Package.swift`), or (c) build `Yoga.xcframework` from source. We use the **public C API only** (`YGNodeNew`, `YGNodeStyleSet*`, `YGNodeCalculateLayout`), which is identical to the calls the current stub already makes — so the stub's Yoga usage is a correct foundation.

**Decision: CocoaPods + a `canopy-native` podspec for the core + vendored xcframeworks.** Rationale: Hermes ships as a pod (`hermes-engine`) and Yoga ships as a pod, both pinned to an RN version; CocoaPods resolves the matched trio cleanly. SPM is viable for Yoga but Hermes-as-SPM is not first-class. (Re-evaluate once we pick the exact RN release to mirror Android's 0.76.9.)

### 1.3 Threading model (identical posture to Android)

`CanopyHostViewController.mm:52-61` already documents it: the **JS thread IS the main thread** (every `__fabric_*` call touches UIKit, which is main-thread-only), so the Hermes runtime is created + evaluated on the main run loop, and `postToJs = dispatch_async(dispatch_get_main_queue())`. Heavy module work (Core ML, decode, StoreKit) runs on its own queue and hops completions back via `ctx.complete → postToJs → __canopy_resolve`. This matches `CanopyModules.cpp:62-70` exactly and needs **no change** — the iOS lambda at `CanopyHostViewController.mm:59-61` is already correct.

`requestFrame` (`CanopyFabric.cpp:91-98`) on iOS should be backed by a **CADisplayLink** for the animator coalescing (`native.js:668-693`), not a plain `dispatch_async`. The current stub uses `dispatch_async(main)` (`CanopyHostFabric.mm:112-115`), which works but ties frame cadence to run-loop drain rather than vsync. CADisplayLink is the §2.6 refinement.

---

## 2. The iOS host renderer — `CanopyHostFabric.mm` (full rewrite)

This is the analog of `CanopyHost.java`. The current `CanopyHostFabric.mm` is a faithful but minimal scaffold; the rewrite brings it to `CanopyHost.java` parity. Keep the `CanopyView{ UIView*, YGNodeRef, fabricName }` struct (`:29-33`), extend it to carry the same per-node state Android's `CView` does (`CanopyHost.java:53-61`: textColor, bgColor, borderRadius, isLeaf).

### 2.1 `makeView` — the component table (mirror `CanopyHost.java:172-188`)

```objc
UIView* makeView(const std::string& name) {
  if (name=="RCTText"||name=="RCTRawText") { UILabel* l=[UILabel new]; l.numberOfLines=0; return l; }
  if (name=="RCTImageView")               return [UIImageView new];
  if (name=="CanopyBitmap")               return [UIImageView new];        // canopy/image blob render
  if (name=="RCTSinglelineTextInputView") return [UITextField new];
  if (name=="RCTScrollView")              return [CanopyScrollView new];   // UIScrollView + Yoga contentSize
  if (name=="BeforeAfter")                return [CanopyBeforeAfterView new];
  return [CanopyContainerView new];                                        // RCTView / RCTRootView
}
```

`isLeaf` (Yoga measure function attached) mirrors `CanopyHost.java:162-170`: `RCTText`, `RCTRawText`, `RCTImageView`, `RCTSinglelineTextInputView`, `CanopyBitmap` are leaves; `BeforeAfter` is NOT (always explicitly sized — the same on-device bug note as Android `:164-167`).

### 2.2 The Yoga-driven container — the iOS analog of `YogaViewGroup`

**This is the single most important rewrite decision.** Android uses a custom `YogaViewGroup extends ViewGroup` that runs `calculateLayout()` in `onMeasure` and positions children in `onLayout` (`CanopyHost.java:416-459`). iOS has no measure/layout protocol on `UIView` the same way — `layoutSubviews` is the hook.

Two valid iOS strategies:

- **(A) Push frames after a single `YGNodeCalculateLayout` from the root** (what the current stub does, `CanopyHostFabric.mm:164-179`). One `relayout()` computes the whole tree from `surface_.bounds`, then `applyFrames` recursively sets `view.frame`. Simple, correct for static surfaces. **Adopt this for first light.**
- **(B) A `CanopyContainerView : UIView` whose `layoutSubviews` reads its Yoga node** and lays out direct children, with the ROOT running `calculateLayout` from its `bounds`. This mirrors Android's measure pass exactly and is **the correct production choice** because it re-runs on every real layout trigger (rotation, keyboard avoidance, safe-area change, parent resize) without the host manually calling `relayout()`. Frame source: `YGNodeLayoutGetLeft/Top/Width/Height`.

**Decision: ship (A) for the "blank surface" and "counter" milestones; migrate to (B) before Lumen** because Lumen has rotation + keyboard. The leaf measure function (§2.3) is identical in both.

Root sizing: the root `CanopyContainerView` overrides `layoutSubviews` to `YGNodeCalculateLayout(rootYoga, bounds.width, bounds.height, YGDirectionLTR)` then position children — replacing the stub's `relayout()` driven off `surface_.bounds` (`:166-167`). On rotation/safe-area, UIKit calls `layoutSubviews` automatically.

### 2.3 Leaf measure (mirror `CanopyHost.java:406-414`)

Yoga leaf measure for `UILabel`/`UITextField`/`UIImageView`/`CanopyBitmap`: implement `YGMeasureFunc` that calls `[view sizeThatFits:CGSizeMake(width, height)]` (UILabel intrinsic text sizing), translating Yoga's `YGMeasureMode` (Exactly/AtMost/Undefined) to a constraining size. For `UIImageView` return the image's point size; for `CanopyBitmap` return the blob's `width/height` in points. Density: iOS frames are in **points** and Yoga computes in points, so — unlike Android (`CanopyHost.java:470` `dp(v)=v*density`) — **no density scaling is applied** (Canopy style dims are already dp-ish ≈ points). This is a key iOS-vs-Android difference: the Android `dp()` multiply is absent on iOS.

### 2.4 `applyStyle` — bring to `CanopyHost.java:226-379` parity

Port the full switch, key-for-key, with the reset-on-null discipline (`CanopyHost.java:232` "null → reset to default", driven by `native.js:500-510`). The Yoga keys are platform-identical (same `YGNodeStyleSet*` C calls). The view-side keys map to UIKit:

| Style key | UIKit / CALayer |
|---|---|
| width/height/min/max, flex*, padding*, margin*, top/right/bottom/left, position, flexDirection, justifyContent, alignItems, alignSelf, gap, flexWrap | Yoga C API (1:1 with Android) |
| backgroundColor | `view.backgroundColor` (+ a `CAShapeLayer`/`maskedCorners` for borderRadius+bg, like Android's `GradientDrawable`, `CanopyHost.java:391-402`) |
| borderRadius | `view.layer.cornerRadius`, `layer.masksToBounds=YES` |
| **borderWidth/borderColor** | `layer.borderWidth`/`layer.borderColor` — **gap on BOTH hosts today**; add here |
| opacity | `view.alpha` |
| color / fontSize / fontWeight / textAlign | `UILabel.textColor` / `font:[UIFont systemFontOfSize:]` / `fontWeightTrait` / `textAlignment` |
| **transform** (translate/scale/rotate) | `view.layer.transform` (CATransform3D) — **dropped on both hosts; add** |
| **shadow** | `layer.shadowColor/Opacity/Radius/Offset` — **dropped on both; add** |
| **overflow: hidden** | `layer.masksToBounds` / scroll clipping — **dropped on both; add** |
| **resizeMode** (image) | `UIImageView.contentMode` (cover→ScaleAspectFill, contain→ScaleAspectFit) |

Note: the mission's "styling drops transform/shadow/border/overflow/gradient/resizeMode at the host switch" applies to BOTH hosts. The iOS rewrite is the natural place to add them first (CALayer makes shadow/transform trivial), then back-port to Android. Color parsing: replace the stub's `#rrggbb`-only parser (`CanopyHostFabric.mm:43-53`) with one that also handles `#rrggbbaa`, `rgba()`, and named colors — match `Color.parseColor` coverage (`CanopyHost.java:510-512`).

### 2.5 ScrollView (mirror the Android stub status, then fix)

Android `RCTScrollView` is currently a non-scrolling `YogaViewGroup` (`CanopyHost.java:185-187` "scroll deferred"). On iOS, `RCTScrollView` → `CanopyScrollView : UIScrollView`. Yoga lays out the content normally; after layout, set `scrollView.contentSize` to the Yoga node's computed `(width,height)` of its single content child. Children are added as subviews of the scroll view; their Yoga node is the scroll node's child. `onScroll` events ride the same `scroll` event name (`native.js:53`). This is **iOS-ahead-of-Android** — UIScrollView gives real scrolling for free, so iOS can land working scroll before the Android stub is fixed.

### 2.6 requestFrame → CADisplayLink

`requestFrame` (`CanopyHostFabric.mm:112-115`) currently `dispatch_async(main)`. Replace with a CADisplayLink that fires the queued callback once on the next vsync, satisfying the animator's coalescing contract (`native.js:668-693`). Keep a single shared display link; enqueue callbacks; fire and pause.

### 2.7 testID → accessibilityIdentifier (the device-test enabler)

`testID` arrives as a plain prop (`Native/Attributes.can:292-294`, flows through `native.js:178-184` plain-prop passthrough). **Both hosts ignore it today** — the headline DX/testing gap. In `applyProps`, when `props["testID"]` is present: `view.accessibilityIdentifier = testID; view.isAccessibilityElement = YES`. (Android counterpart: `view.setTag(R.id..., testID)` / content-description — add symmetrically.) This is what lets XCUITest (`app.buttons["restore"]`) and Appium find elements — **prerequisite for all device E2E (§7.2)**.

---

## 3. Event + gesture layer — `CanopyGestures.swift` (+ the press path)

Today `canopyEmitEvent` is **never called on iOS** (`CanopyHostFabric.mm:104-110` is a no-op store). The host needs the `jsi::Runtime*` to call `canopyEmitEvent(*runtime, handle, name, payloadJson)` (`CanopyFabric.cpp:101-110`). Wire it: `CanopyHostIOS` holds a `facebook::jsi::Runtime*` set by the view controller right after `makeHermesRuntime` (the controller already owns it, `CanopyHostViewController.mm:29,47`). All emits go `host->emit(handle, name, payload)` → `canopyEmitEvent`.

### 3.1 `setEvents` — the dispatch (mirror `CanopyHost.java:135-158`)

`setEvents(handle, namesJson)` parses the names array and installs/tears down recognizers, idempotently (Android's "reused view that lost its handler must stop being clickable", `:142-147`):

- `"press"` → a `UITapGestureRecognizer` whose action calls `emit(h,"press","{}")`. Also handle `pressIn`/`pressOut`/`longPress` — for `pressIn`/`pressOut` use a `UILongPressGestureRecognizer` with `minimumPressDuration=0` (began→pressIn, ended/cancelled→pressOut), which is the standard RN `Pressable` trick; `longPress` is the same recognizer with a real duration.
- `"pan"`/`"panStart"`/`"panEnd"` → `UIPanGestureRecognizer` (§3.2).
- `"tap"`/`"doubleTap"` → `UITapGestureRecognizer` (numberOfTapsRequired 1/2), with the doubleTap-fails-single dependency.
- Text events (`change`/`changeText`/`submitEditing`/`focus`/`blur`) are NOT recognizers — they ride the `UITextFieldDelegate` (§3.3).

`setEvents` is re-invoked on diffs via the `__events` prop (`CanopyHost.java:218-222`, `native.js:531-551`) — so `applyProps` must call `setEvents` when `props["__events"]` is present, exactly like Android `:222`.

### 3.2 Pan — `CanopyGestures.swift` (mirror `CanopyGestures.java`)

`UIPanGestureRecognizer` produces the same wire shape `{"dx","dy","vx","vy"}` (`CanopyGestures.java:21-23`, read by `Native.Events.panDecoder`). Map:

- `.began`/first `.changed` past slop → `panStart` (cumulative translation from origin).
- `.changed` → `pan` with `translationInView` (dx/dy in points — iOS points ≈ Android dp, so **no density divide**, unlike `CanopyGestures.java:105` `/density`).
- `.ended`/`.cancelled` → `panEnd` with `velocityInView` as vx/vy.
- Axis bias / parent-steal: UIKit handles this via `gestureRecognizer:shouldRecognizeSimultaneouslyWithGestureRecognizer:` and pan direction; the "claim the dominant axis" logic (`CanopyGestures.java:125-133`) maps to a `UIPanGestureRecognizer` subclass that fails itself if the first movement is off-axis, so a parent `UIScrollView` keeps vertical scrolls.

### 3.3 Text input — `CanopyTextInputDelegate.swift`

`UITextField` is **inert today** (the stub creates it, `CanopyHostFabric.mm:126`, but wires no delegate). Add a delegate per input view:

- `textField(_:shouldChangeCharactersIn:replacementString:)` or a `.editingChanged` target → `emit(h,"changeText",{"text":<new value>})` and `change` (RN sends both; `native.js:52`).
- `textFieldShouldReturn` → `submitEditing` `{"text":...}`.
- `textFieldDidBeginEditing`/`DidEndEditing` → `focus`/`blur`.
- Props `value`/`placeholder`/`editable` (`Native/Attributes.can:11`) map to `.text`/`.placeholder`/`.enabled` in `applyProps`. This is at-parity-with-RN behavior the Android host also needs (Android `EditText` is similarly inert today — iOS can lead).

---

## 4. BeforeAfter compositor — `CanopyBeforeAfterView.swift` (Core Animation)

Mirror `BeforeAfterView.java` (258 lines). The whole point is **zero JS per frame** (`BeforeAfterView.java:9-22`): a native pan moves `wipeFraction` and redraws locally; only two semantic edges emit (`wipeStart` `{}`, `wipeCommit` `{"fraction":f}`).

iOS implementation (cleaner than Canvas clipping):

- Two `UIImageView` layers (before underneath, after on top), both `contentMode = .scaleAspectFill` (matches Android `drawCover` center-crop, `:145-154`).
- The after layer is clipped by a **`CALayer` mask** (a rectangle `0..wipe*width`); moving the seam updates `maskLayer.frame` inside a `CATransaction` with actions disabled (no implicit animation) → 60fps with no JS.
- Props `beforeHandle`/`afterHandle` resolve via the blob→UIImage bridge (§5.2); `wipeFraction` honored unless mid-drag (`BeforeAfterView.java:111-118`).
- A `UIPanGestureRecognizer` drives `wipe` from the finger x; a `UITapGestureRecognizer(numberOfTaps:2)` snaps to the opposite end with a `CABasicAnimation`/`UIViewPropertyAnimator` (260ms decelerate, `BeforeAfterView.java:229-245`), emitting one `wipeCommit` at completion.
- It needs the view handle to target emits (`BeforeAfterView.java:53,95`); the host sets it at create (mirror `CanopyHost.java:84-86`), and emits via the same `host->emit` path as gestures.

The portable `imageWipeColumns` (`CanopyImage.h:30-34`) is the all-native server-free alternative, available verbatim, but the two-layer CALayer mask is the live-drag path.

---

## 5. Capabilities — each Android module re-implemented as an iOS NativeModule

### 5.1 The glue: `CanopyNativeModule` (Obj-C++ ↔ C++)

Define a small C++ `NativeModule` subclass that forwards `invoke(CallContext&)` to a registered Obj-C block table, and an Obj-C++ base that Swift modules subclass. Pattern: each Swift module exposes `methods: [String: (argsJson, callId, complete) -> Void]`; the C++ side routes `(module,method)` and hands the Swift block a `complete(errJson, resultJson)` closure that wraps `ctx.complete`. Because `ctx.complete` already hops via `postToJs` (`CanopyModules.cpp:65-70`), a Swift module may call `complete` from any GCD queue — exactly the Android worker-thread discipline (`PhotosModule.java:16-18`), minus JNI. **No `JniModule`, no `resolveModule`, no `scheduleOnJs`.** This is the biggest simplification iOS gets.

Registration replaces `CanopyHostJni.cpp:196-218`: in `CanopyModuleHost`, after `installCanopyModules`, register `EchoModule`, `CoreMLRestoreModule`, and the 9 Swift-backed modules, then call `setModelBytes` from `[NSBundle ... pathForResource:@"restore" ofType:@"mlpackage"]` (the iOS analog of `MainActivity.java:76`).

### 5.2 Blob bridge — `CanopyBlobRegistryHost.mm`

Provide the **one missing symbol** `canopy::globalBlobRegistry()` (Android's lives in `CanopyJni.cpp:173-176`; ORT/Core ML and the renderer all share it, `CanopyHostJni.cpp:191`). Plus the UIImage↔Blob pair (analog of `jniBlobPutBitmap`/`jniBlobGetBitmap`, `CanopyJni.cpp:182-269`):

- `BlobHandle blobPutUIImage(UIImage*)` — draw into a `CGBitmapContext` (RGBA8888, premultiplied-last → straight per the blob convention) and `put` a tight-stride `Blob{kind:"rgba8"}`.
- `UIImage* blobGetUIImage(BlobHandle)` — build a `CGImage` from the blob bytes via `CGDataProvider`+`CGBitmapContext`.

These back `CanopyBitmap`/`BeforeAfter`/`ImageModule`/`Album`/`Share` exactly as the Android Bitmap bridge does.

### 5.3 The 9 capability modules — iOS backings

| Module (wire contract — must match the `.js`/`.can`) | Android ref | iOS backing |
|---|---|---|
| **Photos** `pick {} -> {image,width,height}` / `release {image} -> null` (`PhotosModule.java` header) | PHPicker via Activity launcher | **PHPickerViewController** presented from the active scene's VC; on `didFinishPicking`, load the `NSItemProvider` → `UIImage`, downsample to the same ~4MP budget (`PhotosModule.java:51`), `blobPutUIImage`, complete. Dismiss → `{code:"cancelled"}` (`:99-103`). |
| **Album** `save {image,format} -> {uri}` (`AlbumModule.java`) | MediaStore | **PHPhotoLibrary** add-only: `performChanges` with `PHAssetCreationRequest.forAsset().addResource(.photo, data:)`. Requires **`NSPhotoLibraryAddUsageDescription`** + add-only authorization (no full-library read needed). Return the created asset's `localIdentifier` as the uri. |
| **ShareImage** `image {image} -> {outcome:"presented"\|"dismissed"}` (`ShareImageModule.java`) | UIActivityViewController | Bake the blob to a temp JPEG (or pass `UIImage` directly), present **`UIActivityViewController`**; `completionWithItemsHandler` → `presented`/`dismissed`. On iPad set `popoverPresentationController.sourceView`. |
| **StorageSecure** `get/set/remove {ns,key[,value]}` (`StorageSecureModule.java`) | Encrypted/SharedPrefs | ns `"secure"` → **Keychain** (`SecItemAdd`/`Copy`/`Delete`, `kSecAttrAccessibleAfterFirstUnlock`); ns `"local"` → **UserDefaults**. `get` absent key → `{value:null}` (`:82-90`). |
| **Notify** `show {title,body} -> {posted}` (`NotifyModule.java`) | NotificationManager | **UNUserNotificationCenter**: `requestAuthorization(.alert/.sound)` (report `posted:false` if denied, matching `:15-16`), then `add(UNNotificationRequest)` with `UNMutableNotificationContent`. |
| **Image** `decode/dimensions/resize/encodeToFile/composite/release` (`ImageModule.java`) | BitmapFactory + shared C++ | **ImageIO/UIImage**: `decode {uri}` via `CGImageSourceCreateThumbnailAtIndex` (downsample budget), `resize` via `UIGraphicsImageRenderer`, `encodeToFile` via `UIImage.jpegData/pngData` to `NSTemporaryDirectory`, `composite` calls the **portable `imageCompositeOver`** (`CanopyImage.h:27`), `release` → registry. |
| **Billing** `getProducts/purchase/restore` + `entitlementChanges` stream (`BillingModule.java` fake, `BillingModule.cpp` stream) | fake store | **StoreKit 2**: `Product.products(for:)`, `product.purchase()`, `Transaction.currentEntitlements`. Re-back the **portable `BillingModule.cpp` stream half** by calling its `emit(entitlementJson)` (`BillingModule.cpp:79-93`) from a `Transaction.updates` listener (replaces the JNI `nativeEmit` at `:111-122`, which is `#if`-guarded off on iOS). The one-shots call `ctx.complete` directly instead of bouncing to Java. |
| **Lifecycle** `appState/memoryPressure/backPressed` streams + one-shots (`LifecycleModule.java`) | StreamingJniModule | A small iOS `CanopyStreamModule` (the `StreamingJniModule.h` posture, but NativeModule-direct): subscribe to `UIApplication.didBecomeActive/willResignActive/didReceiveMemoryWarning` notifications and emit on the matching channel. iOS has **no hardware back button**, so `backPressed` is inert (an interactive-pop-gesture hook is the optional analog). |
| **AppShell** `setStatusBarStyle` one-shot + `colorScheme` stream (`AppShellModule.java`) | StreamingJniModule | `setStatusBarStyle` → drive the VC's `preferredStatusBarStyle` + `setNeedsStatusBarAppearanceUpdate`. `colorScheme` → `traitCollectionDidChange` (`userInterfaceStyle`) emits `{"scheme":"light"\|"dark"}`, primed on subscribe. |

The streaming modules reuse the **same `emit(channel,json)` semantics** as `StreamingJniModule::emit` (`StreamingJniModule.h:74-76`) but implemented as a tiny iOS-only NativeModule (no JNI bridge). The `StreamingJniModule.h:42-44` header already anticipates this: "iOS would implement equivalent NativeModules directly against UIKit … and never include this file."

### 5.4 One shared-C++ portability fix required

`BillingModule.cpp:111-122` exports `Java_com_canopyhost_modules_BillingModule_nativeEmit` unconditionally and `#include <jni.h>` at `:13`. To compile on iOS, **guard the JNI bits**: wrap the `#include <jni.h>` and the `extern "C"` export in `#if defined(__ANDROID__)`. The stream class itself (`emit`/`invoke`/`cancel`) is portable and stays. (Alternatively split `BillingModule.cpp` into `BillingModule.cpp` portable + `BillingModuleJni.cpp` Android-only — cleaner, and symmetric with how `CanopyJni.cpp` already isolates JNI.) This is the **only edit to existing shared C++** the iOS bring-up forces.

---

## 6. ML backend — Core ML (mandated over ORT)

Android runs the ESPCN super-res ONNX via ORT on a worker thread (`RestoreEngineModule.cpp`), reading RGBA from a blob, YCbCr split, Y→model→recombine, `put` result (`:255-419`). iOS must produce the **identical wire contract** (module `RestoreEngine`: `process {image,options} -> {image,width,height}`, `release`, `deviceTier`, `RestoreEngineModule.h:9-12`) but via **Core ML**.

- **Model conversion (Mac, offline):** convert `super-resolution-10.onnx` → `restore.mlpackage` with `coremltools` (`ct.convert(onnx_model, ...)` or via the ONNX→Core ML path; for ESPCN, an `mlprogram` with FP16 weights). Bundle the `.mlpackage` as an app resource. The fixed 224×224 single-channel Y input / 672×672 output (`RestoreEngineModule.h:22-26`) maps to an `MLMultiArray` `[1,1,224,224]`.
- **`CoreMLRestoreModule.mm`** — a C++ `NativeModule` named `"RestoreEngine"` (so the same `.can`/`native-module.js` routing hits it). `invoke("process")` spawns a background `dispatch_queue`, reads the input blob (`globalBlobRegistry().get`), does the **same** RGBA→YCbCr→resize→recombine math (lift it from `RestoreEngineModule.cpp:286-411` — that math is portable; only the model `Run` differs), runs the model via `MLModel.prediction(from:)`, blends by `strength`, `put`s the output blob, `ctx.complete`. `cancel` flips a per-callId atomic the queue polls between steps (mirror `RestoreEngineModule.cpp:171-187`).
- **`deviceTier`** can report `"ane"`/`"gpu"`/`"cpu"` from `MLModelConfiguration.computeUnits` instead of the Android `"cpu"` stub (`RestoreEngineModule.cpp:221-224`) — a genuine iOS win (Apple Neural Engine).
- **Reuse opportunity:** factor the YCbCr/resize/blend helpers (`sampleBilinear`, `resizePlane`, the YCbCr loops, `RestoreEngineModule.cpp:100-138,286-411`) into a portable `RestoreColorOps.{h,cpp}` that BOTH the ORT (Android) and Core ML (iOS) modules call. This avoids duplicating the 120-line pixel pipeline. (Refactor Android to use it too.)

---

## 7. Testing strategy

### 7.1 Mock-fabric unit tests (no device, runs today)

The render walker is platform-agnostic JS (`native.js`); the test harness already drives the REAL walker against an in-memory mock (`native.js:792-923`, `harness/mock-fabric.js`, `harness/mock-native-modules.js`). **These tests are iOS-independent and already validate the seam** (create-count, update-count, text-after-update, style-value — `native.js:882-923`). They prove the JS the iOS host receives is correct, so an iOS host bug is isolated to the `.mm`/Swift, not the walker. No new mock work needed; iOS bring-up does not change the JS contract.

### 7.2 Device E2E — XCUITest (Mac + simulator/device)

Unlocked by §2.7 (testID → accessibilityIdentifier). An XCUITest target drives the booted app: `app.buttons["restore"].tap()`, assert `app.staticTexts[...]`, drive the PHPicker, assert the before/after view. This is the iOS analog of an Appium/Espresso driver and **cannot exist until testID is wired** — making §2.7 a hard prerequisite, not a nice-to-have. Lumen's screens already emit testIDs (e.g. the compiled bundle shows `testID(id)` on every button, evidence: `canopy.bundle.js:82897`).

### 7.3 Host-level C++ smoke (Mac or Linux)

The portable `host/shared/CMakeLists.txt:31-36` already type-checks the shared C++ with the host toolchain. Add a tiny **Obj-C++ unit test** (XCTest) that instantiates `CanopyHostIOS`, feeds it a scripted `createView`/`insertChild`/`updateProps` sequence, and asserts the resulting `UIView` tree + Yoga frames — a focused renderer test without booting Hermes. Mirrors what a `CanopyHost.java` instrumentation test would do.

### 7.4 Snapshot / golden frames

`iOSSnapshotTestCase`-style golden images of representative screens (counter, before/after at wipe=0.5, a styled card) catch the style-mapping regressions (transform/shadow/border) that unit tests miss. Run on a fixed simulator model in CI (§8 "what needs a Mac").

---

## 8. Mac requirement — what is blocked vs. what is not

**Can be written / cross-checked WITHOUT a Mac (do it now, on this Linux box):**
- All Swift/Obj-C++ source for the renderer, gestures, modules, Core ML module (compile-checked later, but reviewable and structurally complete now).
- The shared-C++ portability fix (§5.4) — guard `BillingModule.cpp`'s JNI; verify the rest compiles with the host toolchain via `host/shared/CMakeLists.txt`.
- The portable `RestoreColorOps` refactor (§6) — pure C++, builds on Linux.
- The mock-fabric / native-module unit tests (§7.1) — already run on Linux (Node harness).
- The Core ML model conversion script (`coremltools`) authoring (running it needs macOS for full validation, but the script is portable Python; conversion itself can run on Linux with `coremltools`).
- Podspec/`Package.swift`, `Info.plist`, entitlements, the project file's *intent* (targets, build phases, signing config) authored as text.

**REQUIRES a Mac (Xcode + iOS SDK):**
- Creating/opening the `.xcodeproj`, linking `Hermes.xcframework` + Yoga, and the actual **compile** (UIKit/Hermes/Yoga headers are macOS-SDK-only; `CanopyHostFabric.mm:15-17` "cannot be built on this Linux box").
- Running on the **iOS Simulator** and on a **device** (device needs a paid Apple Developer account + provisioning profile; simulator needs only Xcode).
- **Signing/provisioning:** simulator runs unsigned; device needs a Development cert + a provisioning profile (free personal team works for dev install, App Store needs a paid team). StoreKit 2 testing uses a local `.storekit` config file (no account) on the simulator; sandbox purchases need a paid account.
- Final **Core ML compilation** (`coremltools` produces the `.mlpackage`; Xcode compiles it to `.mlmodelc` at build — that step is Mac-only) and ANE/GPU validation.
- XCUITest / snapshot runs and CI on a macOS runner.

---

## 9. Milestones (ordered, with effort)

Effort: S ≤ 1 day, M ≈ 2-4 days, L ≈ 1-2 weeks, XL ≈ 2-4 weeks. Mac-gated items flagged ⌘.

| # | Milestone | Deliverable | Effort |
|---|---|---|---|
| **M0** | Project bring-up ⌘ | `CanopyHost.xcodeproj` + `CanopyHostCore` target on a Mac; vendor `Hermes.xcframework` + JSI + Yoga (pinned to Android's 0.76.9); add shared C++ by reference minus JNI files; guard `BillingModule.cpp` JNI (§5.4); compiles. | L |
| **M1** | Boots a blank surface on the simulator ⌘ | `AppDelegate`/`SceneDelegate`/VC stand up Hermes, `installCanopyFabric` + `installCanopyModules`, provide `globalBlobRegistry()` (§5.2), eval `canopy.bundle.js`, `canopyBoot` against a black root view. Echo module registered. **First light: a Hermes-driven UIView surface.** | M |
| **M2** | Renderer parity | Rewrite `CanopyHostFabric.mm` to `CanopyHost.java` parity: full `applyStyle` switch with reset-on-null (§2.4), leaf measure (§2.3), the `CanopyContainerView`/`layoutSubviews` model (§2.2), color/percent/auto/edges. **A static styled screen renders correctly.** | L |
| **M3** | Events + text + gestures | Wire `host->emit` + `setEvents` (§3.1); press/pressIn/pressOut/longPress; `CanopyGestures.swift` pan/tap/doubleTap (§3.2); `UITextField` delegate change/submit/focus/blur (§3.3). **The counter + a form react to taps and typing.** | M |
| **M4** | testID + scroll + image | testID→accessibilityIdentifier (§2.7); `CanopyScrollView` contentSize (§2.5); `CanopyBitmap`/`RCTImageView` via the blob→UIImage bridge + resizeMode. **A scrolling list of blob images works; XCUITest can find elements.** | M |
| **M5** | Capability modules (non-ML) | `CanopyNativeModule` glue (§5.1) + the 7 non-ML modules: Photos, Album, Share, Storage, Notify, Image, Lifecycle/AppShell. Info.plist usage strings + entitlements. **Pick → decode → render → save → share round-trips.** | L |
| **M6** | Before/After compositor | `CanopyBeforeAfterView.swift` (§4): two layers + CALayer mask, pan drag, double-tap snap, wipeStart/wipeCommit emits. **The marketing interaction runs at 60fps, zero JS/frame.** | M |
| **M7** | Core ML ML backend ⌘ | Convert ESPCN → `restore.mlpackage`; `CoreMLRestoreModule.mm` (§6) reusing the portable `RestoreColorOps`; model-bytes/asset handoff; ANE deviceTier. **A real super-res restore runs on-device.** | L |
| **M8** | Billing (StoreKit 2) ⌘ | `BillingModule.swift` re-backing the portable stream half; `.storekit` config for simulator; products/purchase/restore + `entitlementChanges` from `Transaction.updates`. **The paywall unlocks and persists.** | M |
| **M9** | Lumen runs on iOS ⌘ | End-to-end: all capabilities wired, rotation/keyboard via `layoutSubviews` model (B), XCUITest E2E green on a device, signing/provisioning for a TestFlight build. **Lumen ships natively on iPhone.** | L |
| **M10** | Hardening / DX ⌘ | CADisplayLink animator (§2.6); red-box for JS exceptions (catch `jsi::JSError` instead of SIGABRT); transform/shadow/overflow style back-port; snapshot CI on a macOS runner. | M |

Critical path: M0→M1→M2→M3 unblock everything; M5/M6/M7/M8 are parallelizable once the renderer + module glue exist. M9 is the integration gate.

---

## 10. Risks & open questions

1. **Hermes/JSI ABI match (high).** The vendored `Hermes.xcframework` and the JSI headers must be the SAME version (Android pins 0.76.9). A JSI `Value`/`Runtime` ABI mismatch is a silent crash. Mitigation: take both from one RN release's pods; do not mix a vendored `jsi.h` with a differently-versioned Hermes. **Open: which exact RN release ships an iOS `hermes-engine` pod matching Android's `hermes-android` 0.76.9?**
2. **Yoga source parity (medium).** The current stub uses Yoga's C API. If we take Yoga from the RN pod vs. `facebook/yoga` SPM vs. a from-source xcframework, the `YGNode*` ABI/behavior must match what `native.js` style facts assume (RN flexbox defaults: `flexDirection:column`, `alignItems:stretch` — already reset-defaulted in `CanopyHost.java:352-355`). Pick one Yoga and pin it.
3. **Layout strategy (medium).** Strategy (A) (push frames from root) is simple but does not auto-react to keyboard/rotation; strategy (B) (`layoutSubviews`) does but is more code and must avoid layout loops (calling `YGNodeCalculateLayout` inside `layoutSubviews` then setting child frames is safe; mutating Yoga during layout is not). **Decision pending device testing of (B).**
4. **Core ML conversion fidelity (medium).** The ONNX→Core ML conversion of ESPCN may shift numerics (FP16, op support). The stand-in model is already a fidelity stand-in (`RestoreEngineModule.h:22-26`), so exactness is not required, but the pipeline must produce a plausible image. **Open: does `coremltools` convert this specific ESPCN cleanly, or do we need an `mlprogram` rebuild?**
5. **StoreKit 2 vs. the fake store contract (low-medium).** The wire shapes are fixed by `Billing.can`/`billing.js` (`BillingModule.java:42-48`). StoreKit 2's `Product`/`Transaction` must map onto `{products}/{productId,transactionId,entitlement}/{isActive,productId}`. Sandbox vs. local `.storekit` behaviors differ; entitlement persistence offline (the secure-store cache, `StorageSecureModule.java:20-21`) must be honored.
6. **No hardware back button (low).** `Lifecycle.backPressed` (`LifecycleModule.java`) and `navigation`'s back interception (`MainActivity.java:110-122`) have no iOS analog. Map to the interactive-pop gesture or leave inert; ensure the navigation package degrades gracefully on iOS.
7. **Mac availability is the schedule gate (high, logistical).** Everything M0/M1 onward needs a Mac to compile and run. The auto-memory notes "env can't build on-device". Sequence all Linux-authorable work (Swift sources, the C++ fix, the color-ops refactor, model-conversion script, unit tests) FIRST so the Mac time is pure compile/run/sign, not authoring.
8. **`globalBlobRegistry()` single-definition (low but sharp).** Android defines it in `CanopyJni.cpp:173`; `RestoreEngineModule.cpp:17-19` forward-declares it. On iOS exactly ONE TU must define it (`CanopyBlobRegistryHost.mm`) or the link fails / two registries diverge (the renderer would see different handles than ORT/Core ML). Verify single-definition at link.
9. **Style back-port symmetry (low).** Adding transform/shadow/overflow/border on iOS first (CALayer-easy) creates an iOS-ahead-of-Android divergence; track these as a shared style-contract gap so Android catches up, keeping the two hosts pixel-comparable for snapshot tests.
