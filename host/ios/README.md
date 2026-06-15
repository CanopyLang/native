# Canopy iOS Host — Build & Structure

The native iOS host for **canopy/native**: a real UIKit app that runs a compiled Canopy program
(ultimately Lumen) on iPhone/iPad through the same `__fabric_*` render seam and `__canopy_*`
effect ABI as the Android host — **no React Native runtime, no WebView**. JS binds only to a tiny
stable surface; everything platform-specific lives behind two C++ interfaces (`CanopyHost`,
`NativeModule`) implemented here in Objective-C++ / Swift.

This README is the build entry point (SHARED CONTRACT §2, Author A). It covers the project
shape, the dependency strategy, the exact bootstrap commands, and what compiles where.

---

## TL;DR — bootstrap on a Mac

```sh
cd host/ios

# 1. Project deps (one RN release => ABI-matched Hermes + JSI + Yoga; Risk #1)
npm install react-native@0.76.9       # Podfile reads node_modules/react-native/...

# 2. Generate the .xcodeproj from project.yml (the source of truth)
brew install xcodegen                  # once
xcodegen generate

# 3. Integrate the pods (writes CanopyHost.xcworkspace)
pod install

# 4. Build the program bundle and drop it where the copy phase finds it
canopy-native build                    # produces canopy.bundle.js
cp <out>/canopy.bundle.js CanopyHostApp/Resources/canopy.bundle.js

# 5. Open the WORKSPACE (not the .xcodeproj) and run on a simulator
open CanopyHost.xcworkspace
```

> The `.xcodeproj` is **generated** — never hand-edit it, never treat it as the truth. Edit
> `project.yml` and re-run `xcodegen generate`. This keeps the project text-diffable and
> authorable without a Mac.

---

## Project shape

```
host/ios/
├── project.yml          XcodeGen spec — THE project source of truth (targets, sources, settings)
├── Podfile              Hermes + JSI + Yoga, pinned to RN 0.76.9 (primary dep path)
├── Package.swift        OPTIONAL Yoga-via-SPM fallback (use only if the Yoga pod misbehaves)
├── README-ios.md        this file
│
├── CanopyHostApp/                       the UIApplication shell (target: CanopyHostApp)
│   ├── AppDelegate.swift                UIApplication entry
│   ├── SceneDelegate.swift              window → CanopyHostViewController() as root
│   ├── Info.plist                       capability usage strings, scene manifest, orientations
│   ├── CanopyHost.entitlements          keychain / in-app-purchase / aps-environment
│   └── Resources/
│       ├── LaunchScreen.storyboard      black launch surface (no flash before first frame)
│       ├── canopy.bundle.js             the compiled program (placeholder until built)
│       └── models/restore.mlpackage     Core ML model (Author F converts; copy phase ships it)
│
├── CanopyHostCore/                      the host engine (target: CanopyHostCore, static lib)
│   ├── CanopyHostCore-Bridging-Header.h Swift↔ObjC++ interop (Author A owns; see "Bridging")
│   ├── Boot/        Hermes runtime, registry, postToJs, install*, registerAll, console polyfill
│   ├── Render/      CanopyHost impl: UIView+Yoga, container/scroll/modal, color, applyProps/Style
│   ├── Events/      gestures, text-input delegate, switch
│   ├── Views/       BeforeAfter wipe compositor
│   ├── Bridge/      the ObjC↔C++ NativeModule bridge, blob registry, CanopyModule protocol
│   ├── Modules/     the 9 Swift capability modules + the stream module
│   └── ML/          Core ML restore module (+ tools/convert_restore.py, NOT compiled in)
│
├── Tests/                               XCTest (renderer + bridge) + XCUITest E2E
├── Frameworks/                          vendored-deps fallback layout (see VENDOR-LAYOUT.md)
└── CanopyHost/                          ⚠ LEGACY pre-contract stubs — NOT in any target (see below)
```

### Targets (defined in `project.yml`)

| Target | Type | What it is |
|---|---|---|
| **CanopyHostCore** | static library | The whole host engine: the `.mm`/`.swift` under `CanopyHostCore/` **plus the portable shared C++** (`../shared/cpp/*.cpp`) added by reference. |
| **CanopyHostApp** | application | The UIKit shell. Depends on (links) `CanopyHostCore`. A build phase copies `canopy.bundle.js` + `restore.mlpackage` into the `.app`. |
| **CanopyHostCoreTests** | unit-test bundle | ObjC++ XCTest: scripted `createView`/`insertChild`, assert Yoga frames; module dispatch round-trip. |
| **CanopyHostUITests** | UI-test bundle | XCUITest E2E driven by `testID → accessibilityIdentifier`. |

---

## Dependency strategy — Hermes + JSI + Yoga, no React Native

The host links exactly **three** third-party things, all consumed as **public C/C++ API only**:

- **Hermes** — `facebook::hermes::makeHermesRuntime()` (the JS engine).
- **JSI** (headers only) — `<jsi/jsi.h>` `Value`/`Runtime`, marshalled behind `CanopyHost`.
- **Yoga** — `<yoga/Yoga.h>` C API (`YGNodeNew`, `YGNodeStyleSet*`, `YGNodeCalculateLayout`).

**The version pin is load-bearing.** All three come from **one React Native 0.76.9 release** so
the JSI ABI matches the linked Hermes binary (SHARED CONTRACT Risk #1 — a `Value`/`Runtime`
mismatch is a *silent* crash). Android pins `hermes-android 0.76.9`
(`host/android/app/src/main/cpp/CMakeLists.txt:5`); iOS pins the RN release whose iOS
`hermes-engine` pod is that same Hermes. **Move both platforms together** on any bump.

- **Primary: CocoaPods.** `pod 'hermes-engine'` + `pod 'Yoga'` from RN 0.76.9 (the `Podfile`).
  Hermes vends `libhermes` **and** its `jsi/` headers from one pod, so the JSI ABI is
  guaranteed matched. We pull **only** these two pods — no `RCTBridge`, no Fabric component
  views, no RN native-module infrastructure.
- **Fallback: SPM for Yoga** (`Package.swift`). Yoga is a clean dependency-free C/C++ library SPM
  can vend alone; use this only if the Yoga *pod* misbehaves on a given toolchain. Hermes is
  **not** consumed via SPM (not first-class) — it always comes from the pod or a vendored
  `hermes.xcframework`.
- **Offline / air-gapped:** see `Frameworks/VENDOR-LAYOUT.md` for vendoring the prebuilts.

> **One JSI header set, not two.** The repo vendors `host/shared/third_party/jsi/jsi/jsi.h`
> (which `project.yml` puts on the header search path). It must be the **same version** as the
> linked Hermes. If the hermes-engine pod ships its own `jsi/` headers, prefer those and drop the
> `third_party/jsi` path to avoid a two-version mix.

---

## What compiles where (the portable-vs-platform split)

The architecture splits **portable C++** (binds only to `<jsi/jsi.h>`) from **per-platform
mount/runtime**. iOS **reuses the portable half verbatim** and re-backs the platform half in
ObjC++/Swift.

### Portable shared C++ — added to `CanopyHostCore` by reference (compiles on iOS)

Listed file-by-file in `project.yml` (NOT a glob, so the never-compile set can't sneak in):

- `CanopyFabric.cpp` — the `__fabric_*` render seam installer.
- `CanopyModules.cpp` — the `__canopy_*` effect ABI + `ModuleRegistry`.
- `CanopyBlobs.cpp` — the opaque binary-handle registry.
- `EchoModule.cpp` — the C1 reference capability.
- `CanopyImage.cpp` — `imageCompositeOver` / `imageWipeColumns` over RGBA blobs.
- `BillingModule.cpp` — the streaming entitlement module (its JNI bits are `#if defined(__ANDROID__)`-guarded by Author E, §0.4; the stream half is portable).
- *(future)* `RestoreColorOps.cpp` — if Author F extracts the YCbCr/resize/blend pipeline into a portable TU shared by the ORT (Android) and Core ML (iOS) backends. Commented in `project.yml` until it lands.

### NEVER compiled on iOS (Android-only — JNI / ORT; SHARED CONTRACT §0.5)

`CanopyJni.cpp`, `CanopyHostJni.cpp`, `StreamingJniModule.cpp`, `RestoreEngineModule.cpp`. These
speak `<jni.h>` / `<android/bitmap.h>` / ONNX Runtime and are replaced on iOS by ObjC++
NativeModules + the Core ML restore module. They are simply not in `project.yml`.

### The single forced edit to shared C++

`../shared/cpp/BillingModule.cpp` unconditionally `#include <jni.h>` and exports a JNI symbol.
**Author E** wraps those in `#if defined(__ANDROID__) … #endif` (§0.4). That is the **only** edit
any author makes to `host/shared/cpp/`. After the guard, the file compiles cleanly on iOS.

---

## Bridging header — Swift ↔ ObjC++

`CanopyHostCore/CanopyHostCore-Bridging-Header.h` (Author A owns) exposes to Swift **only the
Swift-safe ObjC headers** — those with no `<jsi/jsi.h>`, Yoga, or raw C++ (`std::function`,
templates). Today that is:

- `Bridge/CanopyModule.h` — the pure-ObjC `@protocol CanopyModule` every Swift capability adopts.
- `Boot/CanopyHostViewController.h` — the `UIViewController` SceneDelegate instantiates.

**Deliberately NOT imported** (they would drag the Hermes ABI into Swift — Risk #1):
`Boot/CanopyModuleHost.h`, `Bridge/CanopyNativeModule.h`, `Bridge/CanopyBlobRegistryHost.h`.
Those use `facebook::jsi::Runtime*` / `canopy::ModuleRegistry*` and are reached from ObjC++ (`.mm`)
only. Swift modules speak **JSON strings + the `CanopyComplete` block**, never JSI.

> Need a new ObjC header visible to Swift? Ask **Author A** to add the `#import` line here
> (single-owner, so the bridging header never merge-conflicts — §2.4).

---

## Threading model (identical to Android)

**The JS thread IS the main thread.** Every `__fabric_*` mount call touches UIKit (main-only), so
the Hermes runtime is created + evaluated on the main run loop, and `postToJs =
dispatch_async(dispatch_get_main_queue())`. Heavy module work (Core ML, image decode, StoreKit,
PHPicker callbacks) runs on its own queue and hops completions back via `ctx.complete → postToJs →
__canopy_resolve` before touching the runtime. iOS dp scaling: **UIKit + Yoga both work in
points**, so there is **no density multiply** (the one deliberate divergence from Android's
`dp(v)=v*density`).

---

## ⚠ The legacy `CanopyHost/` directory

`CanopyHost/CanopyHost{Fabric,ViewController}.mm` + `CanopyHost/modules/*` are the **pre-contract
integration stubs**. They define an old single-arg `CanopyHostMake(UIView*)` and an old boot VC
that **collide** with the contract design (the new `CanopyHostCore/Boot/CanopyHostViewController`
and the `CanopyHostMake(UIView*, CanopyEmitFn)` factory in §6.2). They are **not a member of any
target** — `project.yml` sources are only `CanopyHostCore/`, `CanopyHostApp/`, and `Tests/`. Treat
the directory as reference history; delete it once the `CanopyHostCore/Render` rewrite lands. Do
**not** add it to the build (you'd get duplicate-symbol link errors on `CanopyHostMake`).

---

## What needs a Mac vs. what doesn't

**Authorable on Linux (now):** every `.mm`/`.swift` source, `project.yml`/`Podfile`/`Package.swift`,
`Info.plist`/entitlements, the shared-C++ portability guard, the portable `RestoreColorOps`
refactor, the Core ML conversion script (`coremltools` runs on Linux), the Node mock-fabric tests.

**Requires a Mac (Xcode + iOS SDK):** `xcodegen generate` → `pod install` → **compile** (UIKit /
Hermes / Yoga headers are macOS-SDK-only), Simulator/device runs, signing/provisioning, final
Core ML compile (`.mlpackage → .mlmodelc`), and XCUITest/snapshot CI on a macOS runner.

---

## Cross-file contract (who owns what the build references)

`project.yml` references files owned by the per-area authors; the build is coherent against the
SHARED CONTRACT §1 ownership:

- **A (this):** `project.yml`, `Podfile`, `Package.swift`, `Info.plist`, entitlements, bridging
  header, LaunchScreen, the copy phase, the test targets.
- **B:** `CanopyHostCore/Boot/*` — Hermes runtime, registry, `postToJs`, `registerAll`, console polyfill.
- **C:** `CanopyHostCore/Render/*` — the `CanopyHost` impl (`CanopyHostMake(surface, emit)`), views, color, layout.
- **D:** `CanopyHostCore/Events/*`, `CanopyHostCore/Views/*` — gestures, text input, switch, before/after.
- **E:** `CanopyHostCore/Bridge/*`, `CanopyHostCore/Modules/*` — the ObjC↔C++ bridge, blob registry, 9 capabilities; the §0.4 JNI guard.
- **F:** `CanopyHostCore/ML/*` — the Core ML restore module + `tools/convert_restore.py`.

Every cross-file symbol (the `CanopyHostMake(UIView*, CanopyEmitFn)` factory, `CanopyEmitFn` /
`PostToJsFn` typedefs, `globalBlobRegistry()`, the `CanopyModule` protocol, capability
`moduleName` strings, event-name strings) is named in SHARED CONTRACT §6. An author building
against §6 in isolation against stubs integrates without renaming.
