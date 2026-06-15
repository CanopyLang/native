# Canopy iOS Host — BUILD AND VALIDATE

**Companion to the SHARED INTERFACE CONTRACT v1.0.** This document is the operational runbook:
how to vendor the version-matched Hermes/Yoga, generate the Xcode project, wire the portable
`shared/cpp`, embed the JS bundle, build + run on the iOS Simulator, and the validation checklist
mirroring the Android gates.

Root for all paths below: `/home/quinten/projects/canopy/native/host/ios/`
Portable shared C++: `/home/quinten/projects/canopy/native/host/shared/cpp/`

---

## LEGEND — where each step runs

Every step is tagged:

- **[LINUX-DONE]** — authored on Linux already; no Mac required (checked into the repo).
- **[LINUX-OK]** — can be performed/re-run on Linux (text generation, model conversion, bundle build).
- **[MAC-REQUIRED]** — needs macOS + Xcode toolchain (xcodebuild, CocoaPods install of binary pods,
  Simulator, code signing). **None of these can be validated on the Linux authoring box.**

The hard rule: **all compilation, simulator boot, and behavioral validation is [MAC-REQUIRED].**
Linux produces sources, specs, the JS bundle, and the Core ML model artifact; it can never link
Hermes/Yoga or boot a Simulator. Treat every "build" / "run" / "tap" / "assert frame" gate as
Mac-only.

---

## PART 1 — VENDOR HERMES + YOGA (version-matched to Android 0.76.9)

The single hardest correctness constraint (Risk #1 in the contract): the JSI `Value`/`Runtime`
ABI used by the host MUST match the Hermes that produced it. Android pins React Native **0.76.9**
(`native/host/android/.../CMakeLists.txt:5`). iOS must consume the **same** Hermes release so a
`jsi::Value` constructed by the bundle and a `jsi::Value` read by the host share one ABI. Mixing a
vendored `jsi.h` against a differently-versioned Hermes is undefined behavior (silent corruption).

### 1.1 Pin the RN version — [LINUX-DONE]

`Podfile` is already authored to pin `hermes-engine` and `Yoga` to the RN **0.76.9** release.
JSI headers are taken from the **same** Hermes pod — we do **not** mix the vendored
`shared/third_party/jsi/jsi.h` with a different Hermes. The header search path in `project.yml`
points at `shared/third_party/jsi` ONLY for the portable code that includes `<jsi/jsi.h>`; on a
real Mac build the Hermes pod's `jsi.h` is the one that must win. (Resolution detail in §1.4.)

Verify the pin on Linux:

```bash
grep -nE "hermes|Yoga|0\.76\.9" /home/quinten/projects/canopy/native/host/ios/Podfile
```

### 1.2 Two supported ways to get Hermes.xcframework

**Path A — CocoaPods (primary).** [MAC-REQUIRED for `pod install`]
`pod install` pulls `hermes-engine` for RN 0.76.9. The pod resolves to a prebuilt
`hermes.xcframework` (the React Native release ships a notarized binary; for a custom build the pod
can build from source, which also needs a Mac). This is the path `Podfile` is written for.

```bash
# on the Mac, in host/ios/
sudo gem install cocoapods            # if not present
pod install                           # downloads hermes-engine 0.76.9 + Yoga
open CanopyHost.xcworkspace           # NOTE: workspace, not .xcodeproj, after pods
```

**Path B — vendored xcframework (offline / pinned).** [obtain on Linux via download — LINUX-OK;
the framework itself is [MAC-REQUIRED] to link/build]
Pre-place a prebuilt `hermes.xcframework` into `host/ios/Frameworks/` and reference it from
`project.yml` instead of the pod. Obtain the exact 0.76.9 artifact one of:

1. From the RN 0.76.9 npm tarball: `react-native@0.76.9` ships
   `sdks/hermes-engine/...` / a `hermes-engine` podspec that points at the prebuilt tarball URL.
   Download the `hermes-ios-*.tar.gz` referenced by that release's `sdks/.hermesversion` and unpack
   `destroot/Library/Frameworks/universal/hermes.xcframework`.
2. From an existing Mac build cache: `~/Library/Caches/CocoaPods` or a Pods/hermes-engine checkout.

Downloading the tarball is fine on Linux; unpacking gives you `hermes.xcframework` (a directory of
`.framework` slices for `ios-arm64`, `ios-arm64_x86_64-simulator`). Drop it at:

```
host/ios/Frameworks/hermes.xcframework
```

The `Frameworks/` directory already exists in the repo for this purpose.

> **Why version-match matters (do not skip):** the host creates its Hermes-backed runtime through
> the RNV-4 seam `canopy::makeRuntime()` (host/shared/cpp/CanopyHermes.cpp — which calls
> `facebook::hermes::makeHermesRuntime()` by default, or `makeHermesABIRuntimeWrapper(get_hermes_abi_vtable())`
> under `-DCANOPY_HERMES_CABI`) and holds the returned `jsi::Runtime` (contract §3.2). Every
> `jsi::Value` crossing the `__fabric_*` / `__canopy_*` seam must be laid out identically on both
> sides. A 0.77 Hermes against 0.76.9 JSI headers compiles and then corrupts at runtime.
>
> **RNV-4 note for the Mac build:** add `host/shared/cpp/CanopyHermes.cpp` to the CanopyHostCore
> target's compile sources alongside the other `host/shared/cpp/*.cpp` files (it is already in the
> Android CMake list). The default backend links the hermes-engine pod's `makeHermesRuntime()` —
> exactly the symbol this pod already exports — so nothing else changes. The stable C-vtable backend
> (`-DCANOPY_HERMES_CABI`) is for when a standalone Hermes that exports `get_hermes_abi_vtable` is
> adopted (RNV-6); the hermes-engine pod does NOT export it today (the Android probe
> scripts/check-hermes-cabi.sh confirms the same for the vendored .so).

### 1.2b The boot-time ABI canary the xcframework must satisfy (IOS-4 / RNV-2) — [LINUX-DONE wiring · MAC-VERIFIED at runtime]

A version-match pin is necessary but not sufficient — a *partial* re-vendor (an `hermes.xcframework`
whose `libhermes` drifts from the `jsi/` headers, a hand-swapped slice, a stale cache) keeps the
SAME version string yet ships a DIFFERENT ABI, which boots fine in the Simulator and corrupts on a
real device (Risk #1). `CanopyHostViewController.mm` now closes this on iOS exactly as Android does:

- At boot, right after `canopy::makeRuntime()`, it reads the LIVE
  `facebook::hermes::HermesRuntime::getBytecodeVersion()` off the engine and runs
  `canopy::checkHermesAbi` (host/shared/cpp/CanopyAbiGate.h) against the baked pin
  `kCanopyExpectedHermesBytecodeVersion` (= **96** for RN 0.76.9), BEFORE installing the ABI or
  evaluating any JS. A mismatch is fail-LOUD (the `reportFatal` red-box + `os_log_fault`) and boot
  ABORTS — a mismatched engine never runs user JS. This is the iOS twin of `CanopyHostJni.cpp`'s
  `enforceHermesAbiGate`. (The `.hbc` bundle is separately gated by `checkBundleBytecode`, RNV-7.)
- The canary requires `<hermes/hermes.h>` (the hermes-engine pod ships it). The MAC build needs no
  extra setup beyond linking the pod — the same header the Android NDK build already uses.

**Verify the vendored xcframework actually speaks bytecode version 96 (on a Mac):** the headless
`scripts/check-abi.sh` reads this number out of the Android `.so` (Linux has no Apple slice). On a
Mac, read the same `getBytecodeVersion()` leaf out of the xcframework's device slice and confirm it
is `0x60` (== 96) before shipping — the recipe is in `Frameworks/VENDOR-LAYOUT.md` ("Verify a
freshly-vendored hermes.xcframework"). If you maintain a Mac CI lane, wire that assertion in so the
iOS binary half is gated as `check-abi.sh` gates the Android half; until then the boot-time canary
is the device-side net.

### 1.3 Yoga — [MAC-REQUIRED to build]

Yoga is consumed as the **public C API only** (`YGNode*`, `YGNodeStyleSet*`, `YGNodeCalculateLayout`),
matching the renderer's usage (contract §5.4). Two sources, mirroring Hermes:

- **Primary:** the `Yoga` pod from the same RN 0.76.9 release (`Podfile`).
- **Fallback:** `Package.swift` exists ONLY as a Yoga-via-SPM fallback if the pod is troublesome
  (contract §2.3). CocoaPods is primary; do not use both at once.

iOS Yoga runs in **points** and there is **no density multiply anywhere** (contract §0.3). This is
the deliberate divergence from Android's `dp(v)=v*density`. Pan/translation come straight from
UIKit points.

### 1.4 jsi.h resolution rule — [LINUX-DONE in spec, MAC-REQUIRED to verify at link]

`HEADER_SEARCH_PATHS` (project.yml) includes both `shared/third_party/jsi` and the Hermes pod
headers. On the Mac, ensure the **Hermes pod's `jsi/jsi.h`** is found first (or that the vendored
copy is byte-identical to the 0.76.9 one). The portable `shared/cpp` only ever does
`#include <jsi/jsi.h>`; it never hard-codes a path. If you vendored via Path B, copy the matching
`jsi/` headers out of the same hermes artifact into `shared/third_party/jsi` so the two never drift.

---

## PART 2 — GENERATE THE XCODE PROJECT (XcodeGen) + ADD shared/cpp

### 2.1 The project source of truth is `project.yml` — [LINUX-DONE]

We do **not** hand-write or check in a `.xcodeproj`. `project.yml` (XcodeGen spec, contract §2.1)
is text-diffable and regenerable. It already declares two targets:

- `CanopyHostApp` (application) → depends on `CanopyHostCore`; sources `CanopyHostApp/`;
  `INFOPLIST_FILE` + `CODE_SIGN_ENTITLEMENTS`; "Copy Canopy Bundle" build phase.
- `CanopyHostCore` (static library) → sources `CanopyHostCore/` **plus the shared `.cpp`** by
  relative path to `../shared/cpp/`.

Verify on Linux that the spec is well-formed and lists the expected shared sources:

```bash
grep -nE "CanopyFabric\.cpp|CanopyModules\.cpp|CanopyBlobs\.cpp|EchoModule\.cpp|CanopyImage\.cpp|BillingModule\.cpp|HEADER_SEARCH_PATHS|c\+\+17|IPHONEOS_DEPLOYMENT_TARGET" \
  /home/quinten/projects/canopy/native/host/ios/project.yml
```

### 2.2 Which shared `.cpp` compile on iOS — [LINUX-DONE in spec]

Added to `CanopyHostCore` **by reference** (contract §2 / §1 trailer), these compile on iOS:

```
CanopyFabric.cpp
CanopyModules.cpp
CanopyBlobs.cpp
EchoModule.cpp
CanopyImage.cpp
BillingModule.cpp          (ONLY after Author E's §0.4 #if defined(__ANDROID__) guard)
RestoreColorOps.{h,cpp}    (only if Author F extracts it)
```

**NEVER compiled on iOS** (must NOT be in the target — contract §0.5):

```
CanopyJni.cpp   StreamingJniModule.cpp   CanopyHostJni.cpp   RestoreEngineModule.cpp
```

`RestoreEngineModule.cpp` is replaced by the Core ML module (`CoreMLRestoreModule.mm`, Author F).
`CanopyJni.cpp` is where Android defines `globalBlobRegistry()`; on iOS the **single** definition
moves to `CanopyBlobRegistryHost.mm` (Author E, contract §4.5/§6.3).

### 2.3 The one forced edit to shared C++ — [LINUX-DONE, owner Author E]

`shared/cpp/BillingModule.cpp` unconditionally `#include <jni.h>` and exports a
`Java_...nativeEmit`. Author E wraps the `#include <jni.h>` AND the `extern "C"` JNI export in
`#if defined(__ANDROID__) ... #endif`. Confirm the guard before adding the file to the iOS target:

```bash
grep -nE "__ANDROID__|jni\.h|extern \"C\"" /home/quinten/projects/canopy/native/host/shared/cpp/BillingModule.cpp
```

No other file under `shared/cpp/` is edited by anyone for iOS.

### 2.4 Header search paths + standard — [LINUX-DONE in spec]

Both targets set (contract §2.2): `CLANG_CXX_LANGUAGE_STANDARD = c++17`,
`CLANG_CXX_LIBRARY = libc++`, `IPHONEOS_DEPLOYMENT_TARGET = 15.0`,
`SWIFT_OBJC_BRIDGING_HEADER = CanopyHostCore/CanopyHostCore-Bridging-Header.h`,
`DEFINES_MODULE = YES`, and `HEADER_SEARCH_PATHS` += `$(SRCROOT)/../shared/cpp`,
`$(SRCROOT)/../shared/third_party/jsi`, Hermes headers, Yoga headers.

### 2.5 Generate the `.xcodeproj` — [MAC-REQUIRED]

XcodeGen runs on macOS (it shells to the Xcode project model). On the Mac:

```bash
brew install xcodegen          # one-time
cd host/ios
xcodegen generate              # reads project.yml -> CanopyHost.xcodeproj
pod install                    # if using Path A pods -> produces CanopyHost.xcworkspace
```

> If `pod install` was run, ALWAYS open the **`.xcworkspace`**, never the bare `.xcodeproj`,
> or the Hermes/Yoga pods won't be linked.

### 2.6 Bridging header ownership — [LINUX-DONE, owner Author A]

`CanopyHostCore-Bridging-Header.h` exposes to Swift: `CanopyModule.h`, `CanopyNativeModule.h`,
`CanopyBlobRegistryHost.h`, `CanopyHostViewController.h` (contract §2.4). Authors needing a new
ObjC header exposed to Swift request Author A add the `#import` (single-owner, avoids merge
conflicts). Verify:

```bash
grep -nE "CanopyModule\.h|CanopyNativeModule\.h|CanopyBlobRegistryHost\.h|CanopyHostViewController\.h" \
  /home/quinten/projects/canopy/native/host/ios/CanopyHostCore/CanopyHostCore-Bridging-Header.h
```

---

## PART 3 — BUILD canopy.bundle.js AND EMBED IT

### 3.1 Build the JS bundle — [LINUX-OK]

The Canopy/Lumen JS bundle is produced by the existing JS toolchain on Linux (the same artifact the
Android host ships). Produce a single `canopy.bundle.js` (Hermes evaluates plain JS via
`evaluateJavaScript`; no bytecode precompile is required for first-light, and Hermes bytecode
compilation would itself be a Mac/host-tool step). Place the built bundle at:

```
host/ios/CanopyHostApp/Resources/canopy.bundle.js
```

A placeholder is already checked in (contract §1: "placeholder ok") so the build phase wiring is
testable before the real bundle lands.

### 3.2 The "Copy Canopy Bundle" build phase — [LINUX-DONE in spec, MAC-REQUIRED to run]

`project.yml` defines a `CanopyHostApp` build phase "Copy Canopy Bundle" (contract §2.1) that copies
into the app bundle:

- `Resources/canopy.bundle.js`
- `Resources/models/restore.mlpackage`  (Author F's Core ML model; Author A wires the copy)

At runtime, Author B's boot sequence evaluates the bundle (contract §3.2 step 7):
`evaluateJavaScript(...)` with `sourceURL "canopy.bundle.js"`, guarded so a `jsi::JSError` becomes a
logged red-box surface, not `SIGABRT`. The Core ML model path is handed to the restore module by
`registerAll` before first use (contract §3.3 model-bytes handoff).

### 3.3 The Core ML model — [LINUX-OK to convert, MAC-REQUIRED to run inference]

Author F's `CanopyHostCore/ML/tools/convert_restore.py` uses `coremltools` to convert ONNX →
`restore.mlpackage`. coremltools runs on **Linux**, so the artifact is producible off-Mac:

```bash
python3 host/ios/CanopyHostCore/ML/tools/convert_restore.py \
  --onnx <restore.onnx> --out host/ios/CanopyHostApp/Resources/models/restore.mlpackage
```

Loading + running that model through `CoreMLRestoreModule` (`name()=="RestoreEngine"`) is
[MAC-REQUIRED] — Core ML only executes on Apple platforms.

---

## PART 4 — BUILD + RUN ON THE iOS SIMULATOR — [MAC-REQUIRED]

Nothing in this part is possible on Linux. Hermes/Yoga link, code signing, and the Simulator runtime
are all Apple-only.

### 4.0 Driving a remote Mac over SSH — `remote-build.sh` (the automated path)

When the Mac is a remote build host (no local Xcode), use **`host/ios/remote-build.sh`** — it runs
this entire part (and Part 2/3 bootstrap) over SSH from the Linux dev box, and pulls the build log,
a screenshot, and the `os_log` back to `host/ios/remote-artifacts/` so the fix loop is driveable from
Linux:

```bash
cp host/ios/.remote-build.env.example host/ios/.remote-build.env   # set MAC_SSH, REMOTE_DIR
./host/ios/remote-build.sh doctor      # verify Xcode + xcodegen + cocoapods + node on the Mac
./host/ios/remote-build.sh all         # sync → bootstrap(npm RN) → gen → build → run
# iterate after a fix on Linux:
./host/ios/remote-build.sh sync && ./host/ios/remote-build.sh build   # errors land in remote-artifacts/build.log
```

`bootstrap` does the `npm i react-native@0.76.9` from §1.1; `gen` does the `xcodegen generate` +
`pod install` from §2.5; `build`/`run`/`test` are §4.1–4.2 below. The manual commands in the rest of
this part are the underlying steps the harness automates (use them when SSHed into the Mac directly).

### 4.1 Build from the command line

```bash
cd host/ios
xcodebuild \
  -workspace CanopyHost.xcworkspace \          # or -project CanopyHost.xcodeproj if no pods
  -scheme CanopyHostApp \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 15,OS=latest' \
  build
```

### 4.2 Boot the simulator + install + launch

```bash
xcrun simctl boot "iPhone 15"
xcrun simctl install booted \
  "$(xcodebuild -workspace CanopyHost.xcworkspace -scheme CanopyHostApp -showBuildSettings \
      | awk '/ BUILT_PRODUCTS_DIR /{d=$3}/ FULL_PRODUCT_NAME /{p=$3}END{print d"/"p}')"
xcrun simctl launch --console booted com.canopy.host   # bundle id per Info.plist
```

`--console` streams the host's stdout/stderr — the console polyfill (Author B,
`installConsolePolyfill`) routes JS `console.*` here, and guarded boot errors surface as red-box logs
rather than crashes.

### 4.3 What "first light" looks like

On launch, Author B's `CanopyHostViewController.bootCanopy` (contract §3.2) runs entirely on the main
queue: makes the Hermes runtime, builds the emit closure, calls `CanopyHostMake(self.view, emit)`
(Author C), installs fabric + modules + console polyfill, `registerAll`, evaluates the bundle,
creates the `RCTRootView` root, and calls `canopyBoot`. A rendered Native UI in the Simulator is the
first gate below.

---

## PART 5 — VALIDATION CHECKLIST (mirrors the Android gates) — [MAC-REQUIRED]

Every gate here requires a booted Simulator (or device) and is therefore Mac-only. These mirror the
Android device-validated ledger. Drive them via the `CanopyHostUITests` XCUITest target (Author A,
testID-driven E2E) and the ObjC++ XCTest targets (`CanopyRendererTests.mm` Author C,
`CanopyBridgeTests.mm` Author E).

Run the unit/UI suites:

```bash
xcodebuild test \
  -workspace CanopyHost.xcworkspace \
  -scheme CanopyHostApp \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 15,OS=latest'
```

### 5.1 Render gates

- [ ] **App boots, renders a Native app.** Hermes runtime comes up; bundle evaluates with no red-box;
      a `CanopyContainerView` root pinned full-size to `surface_` shows the app's first screen.
      (`CanopyRendererTests.mm`: scripted `createView`/`insertChild`, assert non-zero frames.)
- [ ] **Boot-time ABI canary passes (IOS-4 / RNV-2).** The boot log shows
      `CanopyAbiGate: Hermes ABI OK: bytecode version 96 …` from `-enforceHermesAbiGate`
      (`CanopyHostViewController.mm`) — the LIVE `getBytecodeVersion()` matched the baked pin, so the
      vendored `hermes.xcframework` is the right ABI. A red-box reading `HERMES/JSI ABI MISMATCH` here
      means the xcframework drifted from its JSI headers (re-vendor; do NOT ship). The pure verdict
      logic is pinned device-free by `CanopyEngineTests.mm` (`testHermesAbiGate*`) and the headless
      `scripts/check-abi.sh`; this gate confirms the LIVE-engine read on a real boot.
- [ ] **Yoga layout is correct in points.** Flex rows/columns, padding/margin, width/height (`%`,
      `auto`, points) lay out with **no density multiply** (contract §0.3). Assert
      `YGNodeLayoutGetLeft/Top/Width/Height` → UIView frames.
- [ ] **Rotation + safe-area + keyboard reflow.** `CanopyContainerView.layoutSubviews` recomputes
      from `self.bounds` for any root (real root + ScrollView/Modal content roots). Strategy (B) is
      the production target and MUST be in before Lumen (contract §5.4 migration note).
- [ ] **Color parsing** (`CanopyColor`): `#rgb/#rgba/#rrggbb/#rrggbbaa` (CSS `#RRGGBBAA` order),
      `rgb()/rgba()`, `hsl()/hsla()`, named, `transparent`.
- [ ] **Styling**: backgroundColor, borderRadius (uniform + 4-corner + per-corner `maskedCorners`),
      borderWidth/borderColor/`border` shorthand, opacity, overflow→`masksToBounds`,
      shadow/elevation, transform (translate/scale/rotate), text color/size/weight/align.
- [ ] **Diff-null discipline**: a removed prop arrives as JSON `null` → `[NSNull null]` resets to the
      explicit default (`resetStyleKey`), never coerced to `0`/`""` (contract §5.6/§5.7).

### 5.2 Event gates

- [ ] **Tap / press events fire.** `press` (exact token, NOT a substring of longPress/pressIn/
      pressOut) installs a tap recognizer via `CanopyGestures`; emits through `emit_` →
      `canopyEmitEvent` on main (contract §6.9).
- [ ] **Gestures**: `pan` (payload `{"dx","dy","vx","vy"}` straight from UIKit points, no `/density`),
      `tap`, `doubleTap`, `longPress`, `pressIn`/`pressOut`.
- [ ] **setEvents idempotency**: a reused view that lost an event loses its recognizer (contract
      §5.10). Verify a recycled cell does not double-fire.

### 5.3 Component gates

- [ ] **ScrollView**: `CanopyScrollView` with a SEPARATE Yoga content root; `contentSize` from the
      content node's computed size; `horizontal` flips content `flexDirection` to ROW;
      `scroll`/`refresh` events; `refreshControl`/`refreshing`.
- [ ] **TextInput**: `UITextField` via `CanopyTextInputDelegate` →
      `changeText`/`submitEditing`/`focus`/`blur`; props `value`/`placeholder`/`editable`/
      `keyboardType`/`secureTextEntry`/`multiline` (payload `{"text":...}`).
- [ ] **Image — declarative** `RCTImageView`: async `source` load, `resizeMode`→`contentMode`,
      recycle-checked (`lastSource` de-dup so a recycled view drops a stale late load);
      `load`/`loadEnd`/`error` events.
- [ ] **Image — blob** `CanopyBitmap`: `bitmapHandle` → `blobGetUIImage(handle)` from the single
      `globalBlobRegistry()`; leaf measure returns blob `width/height`.
- [ ] **Switch**: `CanopySwitch` → `valueChange`; `value`/`disabled`.
- [ ] **Modal**: `CanopyModalHost` with its own content root presented in an overlay/VC;
      `transparent`/`animationType`/`visible` (visible applied LAST); the modal's inline node
      measures 0×0.
- [ ] **BeforeAfter**: `CanopyBeforeAfterView` CALayer-mask wipe; `beforeHandle`/`afterHandle`
      (blobs)/`wipeFraction`; `wipeStart`/`wipeCommit` (payload `{"fraction":f}`). Deliberately NOT a
      Yoga leaf — always explicitly sized.

### 5.4 Animation gate

- [ ] **Animations** drive via `requestFrame` (single shared `CADisplayLink`, fire-once-then-pause;
      `dispatch_async(main)` acceptable first-light placeholder). Static `opacity`/`transform` are
      cached (`baseOpacity`/`baseTransform`) and restored on clear; an animation owner suppresses the
      static `view.alpha`/`applyTransform` write.
- [ ] **Remove-during-animation safety**: `removeChild` cancels animations for the child handle so a
      frame callback never hits a dead view (contract §5.9).

### 5.5 Capability (C1 effect ABI) gates

Each capability routes through `__canopy_call(module, method, argsJson, callId)` → the ObjC bridge
(`CanopyNativeModuleBridge`, Author E) → Swift module → `complete(err,res)` → (registry `postToJs`
to main) → `canopyResolveCall`. `CanopyBridgeTests.mm` covers the round-trip; on-device the live
capability is the real gate. Verify each `moduleName` (exact strings, contract §6.5):

- [ ] **`Echo`** — round-trips an arg (shared C++ `EchoModule`); the bridge smoke test.
- [ ] **`RestoreEngine`** (Author F, Core ML) — `restore.mlpackage` loads from the bundle (path
      handed by `registerAll`); inference returns a blob handle. [Core ML = Apple-only]
- [ ] **`Photos`** — PHPicker presents, returns a blob handle (callback hops to main via `postToJs`).
- [ ] **`Album`** — saves an image to the photo library.
- [ ] **`ShareImage`** — share sheet with a blob image.
- [ ] **`StorageSecure`** — Keychain put/get round-trip.
- [ ] **`Notify`** — local notification permission + schedule.
- [ ] **`Image`** — decode/encode through the shared `CanopyImage` + blob registry.
- [ ] **`Billing`** — StoreKit 2 products/purchase (the §0.4-guarded `BillingModule.cpp` links; the
      iOS Swift `BillingModule` drives StoreKit).
- [ ] **`Lifecycle`** (`CanopyLifecycleModule`, streaming) — `appState` emits
      `{"state":"foreground"|"background"}` on `UIApplicationDidBecomeActive/DidEnterBackground`;
      `memoryPressure` emits `{"level":"critical"}` on the memory-warning notification (iOS has a
      single level); `backPressed` never emits on iOS (no global back event); `allowDefaultBack`
      resolves `null`. Wire shape matches `LifecycleModule.java`.
- [ ] **`AppShell`** (`CanopyAppShellModule`, streaming) — `setStatusBarStyle {"style":"light"|"dark"}`
      drives the host VC via `-setHostStatusBarStyle:` (→ `preferredStatusBarStyle`); `colorScheme`
      emits `{"scheme":"light"|"dark"}`, primed on subscribe and re-emitted when the VC's
      `-traitCollectionDidChange:` re-broadcasts `CanopyHostColorSchemeDidChangeNotification`.
- [ ] **`Platform`** (`CanopyPlatformModule`, one-shot) — `openURL {url}` via `UIApplication`,
      `setClipboard {text}` / `getClipboard {} -> {text}` via `UIPasteboard`. Matches `PlatformModule.java`.

- [ ] **Streaming**: a subscribe `callId` receives repeated `complete(nil, event)` calls; a final
      `complete(nil, "{\"$done\":true}")` tears the listener down (contract §4.4); `CanopyStreamModule`
      `emit(channel,json)` maps a channel to those repeated completions.

### 5.6 Link-time invariant (catch before runtime)

- [ ] **Exactly ONE `globalBlobRegistry()`** definition links (Risk #8). It lives only in
      `CanopyBlobRegistryHost.mm`. `CanopyJni.cpp`/`RestoreEngineModule.cpp` are excluded from the iOS
      target (contract §0.5), so there is no duplicate symbol and renderer/Core ML/Image/Album/Share
      all share one registry → handles agree. A duplicate-symbol linker error here means a
      never-compile file leaked into the target.

### 5.7 Threading invariant (audit, not a runtime toggle)

- [ ] **`jsi::Runtime` touched only on main.** The held runtime (Author B) is the sole reference.
      Every host→JS call and every `__fabric_*` callback runs on `dispatch_get_main_queue()`. Worker
      queues (Core ML, decode, StoreKit, PHPicker) hop back via the registry's `postToJs`
      (= `dispatch_async(main)`) before touching the runtime (contract §0.2). No author calls
      `canopyEmitEvent`/`canopyResolveCall` directly except B's emit closure / the portable registry
      (contract §6.9).

---

## SUMMARY — Linux vs Mac split

**Already authored / re-runnable on Linux (no Mac):**
- `project.yml`, `Podfile`, `Package.swift`, bridging header, all `.swift`/`.mm`/`.h` sources.
- The §0.4 `BillingModule.cpp` `__ANDROID__` guard.
- Building `canopy.bundle.js`.
- Converting the Core ML model with `convert_restore.py` (coremltools on Linux).
- Downloading the pinned `hermes.xcframework` tarball (Path B obtain step).

**Requires a Mac (cannot be validated on Linux):**
- `pod install` of the binary Hermes/Yoga pods (Path A).
- `xcodegen generate`, `xcodebuild`, code signing.
- Booting the Simulator, installing, launching.
- **Every** validation gate in Part 5 (render, events, ScrollView, TextInput, Image, Modal,
  animations, each capability, streaming) — all need a running Simulator/device.
- Linking against Hermes/Yoga and the single-`globalBlobRegistry()` link check.
- Core ML inference (`RestoreEngine`) — Apple platforms only.

The deliberate iOS divergences to keep in mind during validation: **no density multiply** (points
everywhere, contract §0.3) and **direct ObjC dispatch** replacing JNI reflection (contract §4).

---

## Linux reconciliation pass (done — `[reconciled-on-linux]`)

The parallel authors diverged on file layout; this was reconciled into ONE clean structure
(everything under `CanopyHostCore/`, which `project.yml` already sources):

- **Capability modules moved into the build target:** `CanopyHost/modules/*.mm` →
  `CanopyHostCore/Modules/` (10 files). They were previously outside any target = never compiled.
- **Blob registry implementation written:** `CanopyHostCore/Bridge/CanopyBlobRegistryHost.mm`
  (the single `globalBlobRegistry()` + `blobPutUIImage`/`blobGetUIImage` via CoreGraphics) — it
  was missing entirely (header-only), so nothing would have linked.
- **Legacy `CanopyHost/` directory deleted** (emptied pre-contract signposts + the duplicate
  `CanopyModule.h` stub — none were in the build target).
- **`Http` capability registered** in `CanopyModuleHost.mm` (the module existed but wasn't in the
  registration list). `RestoreEngine` is registered via the weak Core ML factory.
- **Shared `BillingModule.cpp` JNI-guarded** (`#if defined(__ANDROID__)`) so it compiles on iOS —
  verified Android-safe (Android still builds + runs green).

### Remaining — REQUIRES A MAC (cannot be done/validated on Linux):
1. `brew install xcodegen`; vendor Hermes.xcframework + Yoga per `Frameworks/VENDOR-LAYOUT.md`
   (pinned to RN 0.76.9 = the Android vendor); `pod install`; `xcodegen generate`.
2. `xcodebuild` — fix any compiler-surfaced issues (the one class of thing Linux can't catch:
   JSI/UIKit API signatures, ARC/ObjC++ interop, the premultiplied-alpha `[MAC-VALIDATE]` note in
   the blob bridge, Swift↔ObjC++ bridging). The structure + symbol contract (§6) are consistent.
3. Add an iOS `CanopyPlatformModule.mm` (Linking/Clipboard) to match the Android `Platform` module
   added after the iOS authoring run.
4. Write the unit tests (`Tests/CanopyRendererTests.mm`, `Tests/CanopyBridgeTests.mm` — only the
   `CanopyHostUITests/` dir exists) and run the validation checklist on the simulator.
5. Copy a real `canopy-native build` bundle into `CanopyHostApp/Resources/canopy.bundle.js`
   (a 999-byte no-op placeholder is there now so the project builds).
