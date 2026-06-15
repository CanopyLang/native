# 09 — Phase 4: Ecosystem, OTA & DX Polish (Closing the Long Tail to Rival Expo)

**Status:** consolidated planning doc · **Date:** 2026-06-14 · **Area:** `phase4-ecosystem`
**Reads:** C0–C9 (the subsystem designs + the dependency-ordered roadmap), plus the eight
Phase-4 workstream plans this document assembles into one sequenced campaign.
**This doc is the map for Phase 4:** the thesis, the workstream dependency graph, the eight
full workstream plans in build order, the consolidated effort roll-up, and the first five
tickets to start.

> **The directive, restated for Phase 4.** Phases 0–3 built the *framework* — the C1 native-module
> ABI, the rendering/layout/styling vocabulary, gestures + animation, the platform capability
> packages Lumen needs, and the Android host that builds and ships. Phase 4 is the **breadth**
> phase: the work that turns "a framework that runs *our* app" into "a framework a *stranger* can
> build *their* app on." That is the ecosystem moat — the native-module library breadth, OTA
> delivery, the Metro-class dev loop, third-party extensibility, navigation, accessibility depth,
> managed cloud build/distribution, and production observability that RN/Expo ship as table stakes
> and Canopy does not yet have.

> **⚠️ The honest framing (read before committing).** This is the **~50-person-week / multi-quarter**
> phase, and the single largest deficit on the board. Graded against RN/Expo, Canopy's **#1 gap is
> the ecosystem/library moat**: ~13 hand-written capabilities (~12% of RN breadth), no out-of-tree
> library story, no OTA, a cold-restart dev loop, and an iOS half that is authored-but-unbuilt. The
> raw sum of every milestone here is **~124 pw across 54 milestones** (§4); the **~50 pw figure** in
> the roadmap is the **Android-first v1 ecosystem cut** — it defers every Mac-gated iOS run-leg to
> the iOS bring-up (plan 06), the heavy media/sensors/camera fan-out and the inspector/CDP stretch
> past the first cut, and the SDK-scaffolder + sample-library fast-follow. §4 reconciles the two
> numbers exactly. Treat the 50 pw as *the slice that makes Canopy a credible Expo competitor on
> Android*, and the 124 pw as *the full both-platforms long tail*.

---

## 1. What Phase 4 is

Phase 4 closes the **long tail** in three bands:

1. **Ecosystem breadth — the moat.** Two workstreams carry this. (a) The capability/native-module
   fan-out behind a `gen-capability` codegen that emits a capability from *one spec* instead of
   five hand-written files — the only realistic route from 12% to Expo-comparable breadth (remote
   push, NetInfo, geolocation, sensors, biometrics, haptics, camera, audio/video, background,
   filesystem, contacts, battery/brightness, deep-links). (b) The third-party escape hatch — a
   HostComponent registry + app-provided module registration + a frozen public ABI + a
   `canopy-native-sdk` package — so a stranger can ship a native view or module *as a package*,
   without forking the host. This is the **#1 graded deficit** and the long-pole moat-closer:
   without an out-of-tree authoring story, every native capability must live in-tree forever.

2. **OTA — the operational advantage RN keeps.** Canopy compiles *one* `.can` bundle that drives
   both platforms, so the majority of app changes are JS-only — exactly the changes OTA can ship
   without a store-review round-trip. A signed, content-hashed, channelized, rollback-safe update
   path (CodePush / EAS-Update equivalent) is the single biggest operational lever Phase 4 adds.

3. **DX polish — making it *feel* like Expo.** The Metro-class dev loop (watch+WS dev server,
   state-preserving Fast Refresh, `.can`-line source maps, an iOS red-box at Android parity, a
   Flipper-class inspector), navigation (a React-Navigation-equivalent library), accessibility
   depth (states/values/announce/focus/actions/dynamic-type/RTL/reduced-motion beyond the shipped
   testID seam), managed cloud build + store submission + a cloud device farm (EAS-equivalent), and
   production observability (symbolicated JS + native crashes, a Sentry/Crashlytics-class uploader,
   analytics, runtime vitals).

### The current baseline (where Phase 4 starts)

- **Android: built and shipping-pipeline-validated.** The C1 effect ABI is done and
  device-validated (`__canopy_call/cancel/resolve`, the worker→JS-thread `postToJs` hop,
  `CanopyModules.{h,cpp}`, three backing patterns). 13 capabilities register at boot. The release
  pipeline is real — signed APK **and** AAB on disk, `signingConfigs.release` + R8 +
  `proguard-rules.pro`, a green CI gate (`gate` / `android-release` / `ios-build`). The red-box
  guard landed and is device-validated (`guardJsCall` → Java sink → `CanopyRedBox` plain-views
  overlay). The `testID`→a11y seam is shipped and queried by the e2e harness. The Animated driver
  (`CanopyAnimDriver`) is the host-owned, zero-JS-per-frame engine transitions will ride.
- **iOS: authored, unbuilt.** A full XcodeGen `project.yml` + Podfile + entitlements +
  `remote-build.sh` SSH-to-a-Mac harness exist, and the host `.mm` files (Http/StorageSecure,
  Fabric, modules) are written — but **nothing has been compiled, run, or signed on a Mac**. There
  is no Xcode-project bring-up, no iOS `postToJs`, no CanopyModules installer. Every iOS leg in this
  plan is authored on Linux first and **strictly gated** on the iOS bring-up (plan 06 M0/M1) + a Mac.
- **The long tail is open.** No `gen-capability` codegen; no out-of-tree library story (the host's
  view `makeView` and module-registration are hardcoded switches); no OTA (the only bundle-swap is
  the dev tmp-override); a cold-restart dev loop (`scripts/dev.sh` does `adb push` + `am force-stop`);
  no source maps in the native path (stacks read `canopy.bundle.js:1:NNNNN`); no navigator library
  (only the model-side `NavStack` value + the raw back-press Sub); a11y stops at testID/label/role;
  no managed/cloud build or device farm; no crash uploader, analytics, or vitals.

### The honest framing, in one line

This is the phase where Canopy stops being "the framework that runs Lumen" and becomes "a framework
others can ship on." It is the longest, the most breadth-bound, and the one where the deficit vs
RN/Expo is widest — and most of it is Android-buildable on the current Linux box *today*, with the
iOS half authored-now / run-on-a-Mac-later.

---

## 2. Dependency & sequencing graph

The eight workstreams are not equal-priority and do not all start cold. Three substrate items
unblock the rest; two workstreams are the moat; one (OTA) waits on a release-pipeline artifact.

### 2.1 The graph

```
  ┌─────────────────────────── PHASE 0–3 BASELINE (done / shipped) ───────────────────────────┐
  │  C1 effect ABI (device-validated) · 3 backings · 13 caps · red-box guard · testID→a11y     │
  │  Animated driver (CanopyAnimDriver) · NavStack value + back-press Sub · signed APK+AAB+CI   │
  └────────────────────────────────────────────────────────────────────────────────────────────┘
        │                         │                              │                    │
        ▼ (shared substrate, start IMMEDIATELY, no cross-deps)    │                    │
  ┌───────────────────────────────────────────────────────────┐ │                    │
  │  SUBSTRATE  (the three things everything downstream rides) │ │                    │
  │   S1  Source-maps end-to-end (preamble-aware shift)        │◀┼── feeds DX red-box, Observability, OTA symbolication
  │   S2  Content-hashed asset manifest + HBC precompile       │◀┼── feeds OTA, Managed-build, Observability buildId
  │   S3  Bytes-blob bridge + structured errors + per-call WS  │◀┘  feeds the whole capability fan-out
  └───────────────────────────────────────────────────────────┘
        │                                   │
        ▼                                   ▼
  ┌───────────────────┐         ┌─────────────────────────────┐
  │  gen-capability    │────────▶│  Capability fan-out          │  ← the breadth engine; codegen UNBLOCKS the fan-out
  │  codegen (Cap M1)  │  one    │  Permissions→Net/Http/WS→     │
  │                    │  spec   │  Haptics/Fs/Battery/Contacts→ │
  └─────────┬──────────┘  not    │  Geo/Bio/Sensors/Links→Push→  │
            │              five  │  Camera/Audio/Video/Background │
            │              files └─────────────────────────────┘
            │ (the module-library half of the SDK reuses this generator)
            ▼
  ┌───────────────────────────────────────────────┐
  │  Third-party escape hatch (the MOAT, long pole)│  ← M0 ABI freeze can start immediately;
  │   ABI freeze → view registry → module reg →    │     M4 SDK scaffolder reuses gen-capability
  │   canopy-native-sdk → gen-library → sample      │     M0 ABI is a prerequisite for OTA-shipping
  └───────────────────────────────────────────────┘     bundles that depend on out-of-tree native code
            ▲
            │ (ABI version = OTA compatibility key)
  ┌─────────┴───────────────────────────────────────────────────┐
  │  OTA + Rollback                                               │  ← M0 (substrate) == S2; the SIGNED MANIFEST
  │   manifest+HBC (=S2) → publish (signed) → CanopyUpdater →     │     comes from the release pipeline; rollback
  │   rollback (reuses the SHIPPED red-box as its trigger)         │     reuses the shipped red-box guard
  └──────────────────────────────────────────────────────────────┘
            ▲
            │ (publish lays out the static-bucket update; managed-build signs/fingerprints it)
  ┌─────────┴───────────────────────────────────────────────────┐
  │  Managed build + distribution + device matrix (EAS-equiv)    │  ← M1 runtimeVersion FINGERPRINT gates OTA;
  │   secrets-signing → build --release (HBC+AAB+map+fingerprint) │     M2 submit + M3 OTA channels build on it
  │   → submit → OTA channels → device farm → visual+flake        │
  └──────────────────────────────────────────────────────────────┘

  ┌──────────────────┐   ┌──────────────────────┐   ┌─────────────────────────┐
  │  DX dev-loop II   │   │  Navigation library  │   │  Accessibility depth     │   ← can run in PARALLEL;
  │  (S1 is its M0)   │   │  (pure-.can M0/M1     │   │  (M0 .can surface starts │     light cross-deps to the
  │                   │   │   start cold)         │   │   cold; reuses streaming) │     substrate / red-box / testID
  └──────────────────┘   └──────────────────────┘   └─────────────────────────┘
            │                      │                            │
            └──────────────────────┴────────────────────────────┘
                                   │ (every iOS run-leg)
                                   ▼
                    ┌──────────────────────────────────────┐
                    │  iOS bring-up (plan 06 M0/M1) + a Mac │  ← HARD BLOCKER for every iOS run-leg in
                    │  Xcode project · installer · postToJs │     EVERY workstream (Cap M8, DX M4, Nav iOS,
                    └──────────────────────────────────────┘     A11y M6, Escape iOS, OTA/Observability/Farm iOS)
```

### 2.2 What starts immediately, in parallel

These have **no Phase-4 cross-dependency** and are all Android/Linux-buildable today — start them
in parallel on day one:

- **S1 — Source-maps end-to-end** (DX M0 / Observability M0 / the shared keystone). Pure-Haskell,
  no device, no Mac. The compiler already emits V3 maps; the only new work is asking for them
  (`--source-map`) and a constant line-offset shift past the preamble. **Immediately makes the
  already-shipped Android red-box symbolicate to `.can` lines.**
- **S2 — Content-hashed asset manifest + HBC precompile** (OTA M0 / Managed-build M1). Kills the
  hand-copied 363 KB `assets/canopy.bundle.js` footgun the roadmap already flags as a Phase-0
  unblocker, and is the substrate OTA + managed-build + observability all key off.
- **S3 — Bytes-blob bridge + structured errors + per-call streaming** (Capability M0). The smallest
  standalone unblocker for Http multipart/streaming, Fs, Camera, Audio — independent of the codegen.
- **Escape-hatch M0 — freeze the public ABI.** Pure extraction + version stamp, platform-neutral.
- **Navigation M0/M1 + A11y M0** — pure-`.can`, zero host changes, green in CI with no emulator.

### 2.3 What unblocks what (the load-bearing edges)

| Edge | Why it is load-bearing |
|---|---|
| **`gen-capability` codegen → capability fan-out** | The codegen is the *spine*. Without it every one of the ~12 missing capabilities is a multi-day hand-build across 3–5 files — which is exactly why breadth stalled at 12%. The fan-out (Permissions → Net/Http/WS → the low-risk five → Geo/Bio/Sensors/Links → Push → media) cannot scale until one spec emits the `.can` + Java + Swift stub + boot registration + mock. |
| **S3 (structured errors) → the codegen** | The `Rejected String` → `Rejected {code,message}` migration is a breaking change across ~6 packages. It **must land before the codegen** so generated capabilities are *born* structured — re-touching every generated one later is wasteful. |
| **Permissions (Cap M2) → device-gated capabilities** | A hard prerequisite for Geolocation/Camera/Audio/Sensors/Push/Contacts. Slippage here cascades into the entire device-gated set. Build it early by generalizing the Photos activity-result plumbing. |
| **Escape-hatch ABI freeze (M0) → OTA** | A stable public ABI is the prerequisite for OTA-shipping bundles that depend on out-of-tree native code — the ABI version *is* the compatibility check. |
| **Managed-build M1 `runtimeVersion` fingerprint → OTA gating** | OTA must hard-refuse a JS bundle whose `runtimeVersion` ≠ the installed binary's, or it bricks every device. The fingerprint (registered module set + `__fabric_*`/`__canopy_*` ABI version) is computed once in managed-build and consumed by OTA's `publish` + the client updater. |
| **Release pipeline signed manifest → OTA** | OTA is pull-only from a static bucket; the *signed* `update.json` + sha-named HBC blob is laid out by `publish`, which reuses the managed-build HBC + signing. OTA depends on that artifact existing. |
| **Shipped red-box guard → OTA rollback** | Rollback is a *branch* on the existing `guardJsCall` fatal sink + a boot watchdog — not new infrastructure. |
| **`gen-capability` codegen → SDK scaffolder (Escape M4)** | The module-library half of `gen-library` reuses `CapabilityCodegen.hs` and its `registrations.inc` include, rather than reinventing it. |
| **testID→a11y seam (shipped) → device farm + inspector** | The cloud-farm e2e runs and the Flipper-class tree-dump both query the testID seam; dead without it (shipped on Android, authored-only on iOS). |
| **iOS bring-up (plan 06) + a Mac → every iOS run-leg** | The single most-shared blocker. Every workstream has an iOS leg authored on Linux and run-gated on the Mac. **Do not let any iOS leg gate its Android-first siblings.** |

### 2.4 What waits

- **The capability fan-out** waits on the codegen (Cap M1) and S3.
- **OTA's `publish`/updater/rollout** waits on S2 (manifest+HBC) and the managed-build fingerprint;
  its rollback waits on nothing (red-box is shipped).
- **The SDK scaffolder + sample library (Escape M4/M5)** wait on the codegen.
- **Every iOS run-leg** waits on plan 06 + a Mac.
- **The heavy media set (Camera/Audio/Video/Background, Cap M7)** waits on the bytes-blob (S3) and
  the rendering workstream's view-manager seam (camera preview / video surface are render-seam
  views, not effect modules).

---

## 3. The workstream plans (in build order)

The order below is the recommended build sequence: substrate-bearing and moat workstreams first
(they unblock the most), then the parallel DX/navigation/a11y tracks, then the
distribution/observability layers that consume the substrate.

---

## Capability Ecosystem & gen-capability Codegen (Phase 4)

> The #1 graded deficit vs RN/Expo is the **native-module library moat**: Canopy ships ~13
> capabilities (~12% of RN breadth), each hand-written across 3-5 files, while Expo ships ~50
> first-party modules behind a uniform authoring system. This workstream fixes the *authoring
> system first* (a `gen-capability` codegen over the verified C1 ABI), then drives the full
> Expo-comparable fan-out through it on both platforms. Everything rides the existing
> `__canopy_call/cancel/resolve` ABI and the three proven backings — we do not redesign the
> seam; we automate and fan it out.

### Current state

The C1 effect ABI is done and device-validated (`CanopyModules.{h,cpp}`, the worker→JS-thread
`postToJs` hop), with three backing patterns: `JniModule` (one-shot Java, `CanopyJni.cpp:132`),
bespoke C++ `NativeModule` (`BillingModule.cpp`), and the generic `StreamingJniModule` for Subs
(`StreamingJniModule.h`). Boot registers 13 capabilities (`CanopyHostJni.cpp:225-249`). Beyond
the stale plan-03 doc, two backings are now **real**: `HttpModule.java` is a real one-shot
`HttpURLConnection` fetch (but `request` only — no streaming/progress/multipart/cancel/WebSocket,
body is a `String`), and `BillingModule.java` is **real Play Billing v6** with a dev fake-store
fallback (`gradle billing:6.2.1`), async-purchase callId parking done. The `Blob` struct already
enumerates a `"bytes"` kind (`CanopyBlobs.h`) but the JNI bridge is **Bitmap-only**
(`CanopyJni.h:153-154` — no `jniBlobPutBytes/GetBytes`). The codegen tool (`tool/src/Canopy/Native/`)
has `Codegen.hs` (render-component manifest, the pure spec→string template) and `Scaffold.hs`, but
**no `Capability.hs`/`CapabilityCodegen.hs`**, and `Main.hs` dispatch wires only `build/codegen/init`.
The error taxonomy is still `Rejected String` smuggling `code:message` (`Native/Module.can:55-59`).
`StreamingJniModule` channels are method-name-keyed — no per-socket channel. The Node harness models
the exact ABI (`harness/mock-native-modules.js`, `run-echo.js`).

### Gap vs RN/Expo

Missing entirely: **remote push** (FCM/APNs — Notify is local-only), NetInfo/connectivity,
geolocation, sensors, biometrics, haptics, camera, audio, video, background tasks, filesystem,
contacts, battery/brightness, deep/universal links. But the decisive gap is the **authoring
system**: without `gen-capability`, each of those is a multi-day hand-build, which is why breadth
stalled at 12%. Expo's Modules API / Sweet codegen makes a new module a spec, not five files —
this workstream gives Canopy the same.

### Milestones

| # | Milestone | Effort | Deliverables |
|---|-----------|--------|--------------|
| M0 | Bytes-blob bridge + structured errors + per-call streaming | **M** | `jniBlobPutBytes/GetBytes`; `Rejected {code,message}` + standard code set (migrate ~6 packages); `StreamingJniModule` per-call (per-socket) channels |
| M1 | `gen-capability` codegen | **L** | `Capability.hs` + `CapabilityCodegen.hs` emit `.can` + Java + Swift stub + `registrations.inc` + test mock from one spec; wire into `Main.hs`; generator unit tests |
| M2 | Permissions + `PermissionRequester` | **M** | `request/status -> granted\|denied\|blocked`; reusable activity-result helper (the dependency for the device-gated set) |
| M3 | NetInfo + HTTP streaming/multipart + WebSocket re-back | **L** | `NetInfo` Sub; OkHttp upgrade (progress/cancel/multipart/Blob bodies); `Net.wsOpen/Send/Close` + `websocket-native.js` + Build.hs FFI override; SSE for free |
| M4 | Haptics + Clipboard + Filesystem + Battery/Brightness + Contacts | **L** | 5 capabilities via codegen; re-back `file`/`storage` over `Fs` |
| M5 | Geolocation + Biometrics + Sensors + Deep/universal links | **XL** | 4 capabilities (3 streaming): FusedLocation, BiometricPrompt, SensorManager, intent-filter/App-Links |
| M6 | Remote push — FCM (Android) + APNs design (iOS) | **L** | `Push` register→token + notifications Sub; FirebaseMessagingService; pairs with local Notify |
| M7 | Camera + Audio + Video + Background | **XL** | CameraX/MediaRecorder/ExoPlayer/WorkManager; preview/surface are render-seam views (coordinate) |
| M8 | iOS port of all backings + `WorkerPool` + server receipt validation | **XL** | **BLOCKED on iOS project + installer + iOS `postToJs`.** Fill all `<Name>Module.swift` stubs; port registrations; shared thread pool; Billing receipt check |

### Approach notes

- **The codegen (M1) is the spine.** `CapabilitySpec { capName, capMethods, capStreams,
  capBacking::Jni|Cpp|Streaming }` with typed arg/result field lists drives one pure generator
  (sibling of `Codegen.hs`) that emits: (1) the `.can` `effect module` — one-shot `Cmd`s via the
  `callCmd` type-erasure pattern, Subs via `callStreaming` with the `onEffects/onSelfMsg` manager
  **copied verbatim from the proven Billing/Lifecycle managers**; (2) the `<Name>Module.java`
  `invoke/cancel` skeleton (the StorageSecure/Notify boilerplate, now structured-error); (3) a
  `<Name>Module.swift` stub; (4) a boot line into `generated/registrations.inc` the boot
  `#include`s (so adding a capability never hand-edits `CanopyHostJni.cpp`); (5) a `mock-native-modules.js`
  entry. A new capability becomes "write the spec + fill the method bodies".
- **Do M0 before M1** so generated capabilities are born structured (the taxonomy widening is a
  breaking change across ~6 packages — re-touching every *generated* one later is wasteful).
- **Permissions (M2) is a hard prerequisite** for Geolocation/Camera/Audio/Sensors/Push/Contacts —
  build it early by generalizing the Photos activity-result plumbing into `PermissionRequester`.
- **Re-back, don't re-write** where the `.can` is device-portable: `Http`/`websocket`/`file`/
  `storage`/`geolocation`/`clipboard` keep their `.can` and get a native FFI twin; `analytics`/
  `error-tracking`/`graphql` come free once HTTP streams. Camera preview and video surface are
  **render-seam views**, not effect modules — the effect modules here do only control.

### Risks

- The generated `.can` streaming manager is the riskiest emit — copy Billing/Lifecycle verbatim
  and unit-test that a generated `.can` *compiles* before the fan-out.
- `postToJs` is the **main Looper**, so high-frequency Subs (sensors 50-100Hz, camera frames) can
  jank the UI — rate-limit/coalesce at the host; the dedicated-JS-thread fix is a host-plan item.
- Structured-error migration touches ~6 packages and **must** precede the codegen.
- Per-call (per-socket) channels need a leak test (`streams_` shrinks on `Process.kill`).
- Remote-push background-data delivery buffers into the Sub on next foreground (headless JS wake is
  deferred); WorkManager bundle re-entry and server receipt validation are explicitly v1-deferred.
- **iOS is blocked end-to-end (M8)**: no project/installer/`postToJs`; all iOS bodies are
  scaffolded but need a Mac — sequence strictly after the iOS bring-up workstream.

### First ticket

**Add the bytes-blob JNI bridge.** In `host/shared/cpp/CanopyJni.{h,cpp}` add
`BlobHandle jniBlobPutBytes(JNIEnv*, jbyteArray)` and `jbyteArray jniBlobGetBytes(JNIEnv*, BlobHandle)`
alongside `jniBlobPutBitmap/GetBitmap` (`CanopyJni.h:153-154`), storing/reading a `Blob{kind:"bytes"}`
in `globalBlobRegistry` (the struct already enumerates `"bytes"` — no struct change). Expose both to
Java via `CanopyHostJni` so any capability moves binary as an int handle, not base64. Add a Node
harness assert that put→get round-trips bytes intact. It is the smallest standalone unblocker for
HTTP multipart/streaming bodies, `Fs`, Camera, and Audio, and is independent of the codegen — start now.

---

## Third-Party Native Component + Module Escape Hatch (HostComponent / canopy-native SDK)

The moat-closer for the library ecosystem: let third parties ship their own native views and native modules as installable Canopy packages — **without forking the host**. Today a native capability must live in-tree and edit the host's hardcoded registries; this workstream opens those seams behind a frozen public ABI and ships the `canopy-native-sdk` package, scaffolder, docs, and a worked sample.

### Current state

Native "components" are not `__2_CUSTOM` nodes at all — they are plain `VirtualDom.node "TagName"` nodes (`package/src/Native.can:103-155`). The tag string flows verbatim through `_Native_createView` (`native.js:71`) → `__fabric_createView` (`CanopyFabric.cpp:48`) into each host's `makeView`, which is a **hardcoded switch**: Android `CanopyHost.java:271-300`, iOS `CanopyHostFabric.mm:1585-1638`. An unknown tag silently falls through to a plain container — a third party cannot add a view class without editing host source. The genuine `__2_CUSTOM` path (Canopy's `VirtualDom.custom` Render/diff escape hatch) is explicitly stubbed to an empty `RCTView` at `native.js:238-241`.

On the module side the ABI is solid and general — `ModuleRegistry::registerModule` + the `__canopy_call/cancel/resolve` dispatcher (`CanopyModules.h`) — but registration is **also hardcoded at boot** (Android `CanopyHostJni.cpp:221-247`, iOS `CanopyModuleHost.mm:142-200`). iOS already has a name-convention registrar precedent (`CanopyNativeModule.mm:124 +registerModuleNamed:`), and `gen-capability`/`CapabilityCodegen.hs` is planned (plan 03 §C.5) but unbuilt. The tool's pure-string codegen discipline (`tool/src/Canopy/Native/{Codegen,Component,Scaffold}.hs`) is the foundation to extend. There is **no `canopy-native-sdk` package and no extension docs**.

### Gap vs RN/Expo

RN/Expo's entire ecosystem rides two escape hatches Canopy lacks: `codegenNativeComponent` + a HostComponent ViewManager registry (a package ships its own native view, autolinking registers it with zero host edits), and `NativeModules`/TurboModule autolinking (same for modules). Canopy can register modules **only by editing the host boot file**, and cannot register a new view class **at all**. Autolinking, a versioned public-ABI contract, and "create-native-library" scaffolding have no equivalent. This is the #1 moat deficit.

### Milestones

| ID | Title | Size | Deliverable |
|---|---|---|---|
| **M0** | Freeze + publish the public extension ABI | **S** | `host/shared/cpp/CanopyAbi.h` (`CANOPY_ABI_VERSION` + `NativeModule`/`CanopyViewFactory`); `globalThis.__canopy_abi_version` in `native.js`; `docs/extension-abi.md`. The contract every later milestone binds against. |
| **M1** | HostComponent registry — Android view-factory hatch | **M** | `CanopyViewRegistry.java` + `CanopyHost.registerComponent(name, factory)`; `makeView` default-case consults the registry before falling to a container; third-party props/reset/testID/style route through the existing seams. |
| **M2** | `Native.hostComponent` + real `__2_CUSTOM` JS path | **M** | `Native.hostComponent` API in `Native.can`; implement `native.js:238` custom render/diff so `VirtualDom.custom` subtrees render instead of empty. Mock-Fabric testable. |
| **M3** | App-provided NativeModule registration (no boot edits) | **M** | `registerExternalModule` + a generated `module-registrations.inc` the boot `#include`s; iOS reuses `+registerModuleNamed:`. The ABI itself is unchanged — only the registration seam opens. |
| **M4** | `canopy-native-sdk` package + `gen-library` scaffolder | **L** | Published SDK package (`Native.HostComponent`/`Native.Module`/`Native.Abi`); `canopy-native gen-library <Name>` emitting `.can` + Android factory/module + iOS stub + registration line + mock. Reuses `CapabilityCodegen.hs`. |
| **M5** | Sample third-party library + docs + CI proof | **M** | An out-of-tree sample (one view + one module, e.g. `BlurView` + `Battery`) built through the SDK with **zero host edits**; `docs/writing-a-native-library.md`; CI builds it against the frozen ABI so an ABI break fails loudly. |

### Approach notes

- **No new vnode kind for the common case.** Native components already flow as plain tags; M1 just makes the host's `default:` consult a registry instead of falling through. `Native.hostComponent` (M2) is a thin `VirtualDom.node tag` wrapper. The `__2_CUSTOM` walker work is the *separate*, advanced escape hatch (fully app-controlled render/diff subtrees) — it closes the literal `native.js:~238` stub.
- **Built-ins keep the fast path.** Known tags stay in the `makeView` switch; only unknown tags hit the registry. Registry-owned views must inherit reset-on-null, testID→a11y, and the event seam by routing through the same `applyProps` path — so the factory contract includes a mandatory `reset(view, key)` and an optional `isLeaf`/`measure` hook for custom-measured leaves.
- **Module side is already 90% there.** The `__canopy_call`/`CallContext`/`complete`-from-any-thread ABI is public and general; M3 only opens the *registration* seam (a generated include + a public `registerExternalModule`), reusing the iOS name-convention registrar that already exists.
- **Platform split / Mac caveat.** Author the iOS `CanopyViewFactory` protocol, the `makeView` registry refactor (`CanopyHostFabric.mm:1585`), and the manifest-include on Linux; compile/run/sign is Mac-gated (06-ios-bringup M0). The iOS module-registration leg is lowest-risk since `+registerModuleNamed:` already ships.

### Risks

- **ABI freeze vs. host churn:** freeze too early and third parties break on every renderer change; too late and there's no ecosystem. Mitigation: version the ABI, keep the surface deliberately narrow, version it independently of internal host churn.
- **Trust/crash boundary:** third-party native code can crash the whole app; the Phase-0 red-box guards JS re-entry but not native crashes inside a factory/JNI call. Document the contract; guard dispatch where cheap.
- **Reset leakage:** a factory that ignores `reset(view, key)` leaks a prior screen's state onto a recycled view — make `reset` mandatory and test it in the sample.
- **Leaf measure coupling:** custom-measured leaves need the leaf-measure seam (`isLeaf`); the factory must declare leaf-ness + a measure fn.
- **Packaging native artifacts (the autolinking-equivalent) is unsolved:** Canopy packages are pure `.can`+JS today; a view/module library needs a Gradle `.aar`/CocoaPod the host build links. M4/M5 must define how a library declares its native artifact — the hardest unscoped piece, flagged explicitly.

### First ticket

**[ABI] Land M0 — extract the frozen extension ABI.** Add `host/shared/cpp/CanopyAbi.h` (`CANOPY_ABI_VERSION` + `NativeModule` re-export + a new `CanopyViewFactory` abstract: `create(handle)`/`applyProps`/`reset`/`isLeaf`/`measure`), declare `globalThis.__canopy_abi_version` in `native.js`, and write `docs/extension-abi.md` stating the frozen JS/C++ surface and the survival rule. Pure extraction + version stamp, no behavior change, platform-neutral so iOS inherits it — the contract every later milestone binds against.

---

## OTA Updates & Rollback (CodePush / EAS-Update equivalent)

Area: **prod-readiness-dx** (roadmap Phase 4). Canopy compiles one `.can` bundle that drives both platforms, so the *majority* of app changes are JS-only — exactly the changes OTA can ship without a store-review round-trip. This is the single biggest operational advantage RN/Expo keep over a from-scratch framework, and the seam to close it already exists: `MainActivity.readBundle()` (`MainActivity.java:130-140`) already prefers a non-asset bundle over the baked one. We harden that dev seam into a *signed, rollback-safe, channelized* update path.

### Current state (file:line evidence)

- **The swap hook exists, dev-only.** `MainActivity.readBundle()` (`MainActivity.java:130`) boots `/data/local/tmp/canopy.bundle.js` over the asset when present — world-readable, unsigned, no rollback, stripped from release. `CanopyHostJni.boot(String bundleJs,…)` takes the bundle as bytes and `evaluateJavaScript`s it (`CanopyHostJni.cpp:259`), so *which* bytes boot is a one-line change.
- **The release pipeline is already built** (contrary to plan 07 §0.5's older snapshot): `build.gradle` has `signingConfigs.release`, `buildTypes.release` with `minifyEnabled`+`shrinkResources`+`proguard-rules.pro`, and CI assembles+verifies a signed APK (`.github/workflows/ci.yml` → `android-release`).
- **The rollback trigger is already wired.** The red-box guard landed: `CanopyHostJni.cpp:258` wraps boot in `guardJsCall(e,"boot",/*fatal=*/true,…)` and routes fatals to a Java sink. OTA rollback is a *branch* on that existing signal, not new infrastructure.
- **Transport + secure storage are shipped C1 modules.** `HttpModule.java` (HttpURLConnection, registered `CanopyHostJni.cpp:234`) downloads; `StorageSecure` (EncryptedSharedPreferences/Keystore AES256-GCM, `:232`) persists the rollback marker, `installId`, and the pinned key.
- **Two prerequisites are still open.** There is **no** content-hashed asset manifest (no `Assets.hs`, no `canopy.manifest.json` — the 363 KB `assets/canopy.bundle.js` is still hand-copied) and **no** Hermes HBC precompile (grep finds no `hermesc`/`.hbc`). OTA's first job is to land these (they are the roadmap's own Phase-0/Phase-2 items).
- **iOS host is authored, unbuilt.** `host/ios/CanopyHostCore/Modules/CanopyHttpModule.mm` + `CanopyStorageSecureModule.mm` exist; build/run/sign is Mac-gated.

### Gap vs RN/Expo

CodePush / EAS Update give a hosted update service, signed manifests bound to `runtimeVersion`, named channels (prod/staging/preview), staged rollout %, automatic client rollback when a boot fails to "notify ready", and a CLI. Canopy has **none** of it — only the dev tmp override. We implement the CodePush *static-bucket* shape (pull-only, no hosted server): signed `update.json` + sha-named gzipped HBC on any CDN, a `CanopyUpdater` that checks-on-boot, and red-box-driven rollback.

### Milestones

| # | Milestone | Effort | Key files |
|---|---|---|---|
| M0 | Content-hashed asset manifest + HBC precompile (shared substrate) | M | `Assets.hs` (new), `Config.hs`, `Build.hs:76`, `MainActivity.java:130`, `Doctor.hs` (hbc check) |
| M1 | `canopy-native publish` + signed Ed25519 update manifest | M | `Publish.hs` (new), `Main.hs:25,88`, `update.json` schema |
| M2 | `CanopyUpdater` (Java) — check/verify/download/atomic swap | L | `CanopyUpdater.java` (new), `MainActivity.java:130` (readOtaOrAsset), `native.js` (`__canopy_notifyReady`), BuildConfig pinned key; `CanopyUpdater.mm` authored (Mac-gated) |
| M3 | Rollback on boot-failure + staged rollout gating | M | error-sink branch on `CanopyHostJni.cpp:258`, boot watchdog in `MainActivity`, `ota-state.json`, install-bucket math |
| M4 | OTA E2E + CI gate + operator docs | S | `tool/e2e/ota.e2e` (new), `ci.yml` (ota job), `host/android/OTA.md` (new) |

### Approach notes

- **Manifest envelope** (`update.json`, signed): `{schema, channel, runtimeVersion, bundleSha256, bundleUrl:'<sha>.hbc.gz', assets:[…], rolloutPercent, createdAt, sig:base64(ed25519(canonical)), keyId}`. The bundle blob is sha-named for CDN immutability; only `update.json` mutates when promoting a rollout.
- **Storage layout** in `filesDir/ota/`: `current/`, `staging/<sha>/`, `previous/`. Promotion is `current→previous`, `staging→current` via POSIX-atomic `rename` within `filesDir`. State (`currentSha/previousSha/pendingSha/lastBootResult/failCount/installId`) lives in StorageSecure so it can't be tampered.
- **Boot flow:** `readOtaOrAsset()` prefers `ota/current` (release) and arms a pending sentinel + `BOOT_DEADLINE_MS` watchdog → JS calls `__canopy_notifyReady()` after the first frame → `markBootSucceeded()` promotes & clears. A fatal (red-box sink) or a missed deadline → `markBootFailed()` restores `previous/`, blacklists the bad sha, relaunches. After N failures, pin the **baked asset** (store-reviewed, known-good) and stop polling.
- **Rollout:** stable bucket `FNV1a(installId) % 100`; accept iff `< rolloutPercent`.
- **Precedence (no collision with hot-reload):** dev tmp override (debug) → OTA `current` (release) → baked asset. OTA is release-only; the tmp override is already debug-only.
- **`runtimeVersion` is the safety contract:** a native change (new module/`.so`/`__fabric_` op) MUST bump `runtimeVersion`; the client hard-refuses a manifest whose `runtimeVersion` ≠ the binary's. Only JS-only changes are OTA-eligible.
- **iOS** inherits the portable manifest format + canonicalization + state machine; only NSURLSession/Keychain/CryptoKit glue is platform-specific. Authored on Linux, run Mac-gated (cross-ref the iOS-bringup plan).

### Risks

1. **HBC ↔ libhermes version coupling** (0.76.9): a mismatch is a silent boot failure → embed the bytecode version in the manifest and refuse before swap; `doctor` pins `hermesc`.
2. **`runtimeVersion` discipline:** an OTA JS bundle referencing a missing native symbol crash-rolls-back every device → gate `publish` on the match and refuse client-side.
3. **Rollback thrash:** both `current` and `previous` bad → a fail-counter pins the baked asset and halts polling until the next store update.
4. **Key management:** a leaked private key pushes malicious JS to everyone → Ed25519 offline-only, public key pinned (a *set*, for rotation), sha-named immutable blobs, fail-closed on signature mismatch.
5. **Atomic swap across process death:** write-new-then-rename; never mutate `current/` in place; a partial `pending` reads as "use current".
6. **iOS parity drift** (unbuilt in CI) → keep canonicalization + state machine portable and unit-test them in the Node mock harness so only the glue is unverified until a Mac is available.

### First ticket

**[M0] Land `Assets.hs` + content-hashed `canopy.manifest.json`; make `assets/` a build output.** Add `AssetEntry/AssetManifest` + `collectAssets` (sha256 the assembled bundle + each `native.config.json` `assets` entry); extend `Config.hs` with `ncAssets`+`ncRuntimeVersion`; rewrite `Build.hs:finishBundle` to write the manifest and copy bundle+assets into `host/android/app/src/main/assets` (skip on matching sha); delete the hand-copied 363 KB blob, gitignore `assets/` with a `.gitkeep`; have `MainActivity.readBundle()` verify the booted bundle's sha against the manifest. Independently useful (kills the manual-`cp` footgun), Linux-buildable, no Mac needed, and the substrate every later OTA milestone consumes.

---

## Managed Build + Distribution + Device Matrix (EAS-equivalent)

**Area:** `managed-build-distribution`
**Goal:** productionize ship-and-verify *at scale* — a managed cloud-build pipeline for signed
APK/AAB/IPA with secrets-managed signing, automated Play + App Store submission of the just-built
artifact, OTA release channels wired into the host bundle loader, and a steady-state cloud device
farm (Firebase Test Lab + BrowserStack) with per-device visual-regression baselines and flake
quarantine. This is the EAS-Build / EAS-Submit / EAS-Update / device-cloud quartet, the last
distribution gap between Canopy Native and Expo.

### Current state (file:line evidence)

The single-machine ship path is **done and verified**; the *managed/scaled* layer is **absent**.

- **Android release build is real.** `host/android/app/build.gradle` already has
  `signingConfigs.release` (gradle-property keystore with a dev-keystore fallback, `:54-61`),
  R8 `minifyEnabled`+`shrinkResources`+`proguard-rules.pro` (`:63-76`), and a signed APK **and
  AAB** exist on disk (`app/build/outputs/{apk,bundle}/release/`). The dev keystore
  `host/android/canopy-release.jks` is committed (validation-only).
- **CI ships an APK, not an AAB, with no secrets.** `.github/workflows/ci.yml` runs `gate`
  (device-free harness), `android-release` (`assembleRelease` + apksigner verify + artifact),
  and a `continue-on-error` `ios-build` on `macos-14`. It does **not** build the `.aab`, submit
  to any store, or source signing from secrets — it uses the committed dev keystore.
- **The build tool can't make store artifacts.** `tool/.../Build.hs` `build --release` only adds
  the compiler's `--optimize` (`:67-69`). No `hermesc`/HBC, no `.aab`/`bundleRelease`, no
  sourcemap archive, no `publish`/`submit`/`channel`; `Config.hs` has no asset/release/channel
  fields.
- **OTA does not exist** (grep for `updater|CanopyUpdater|ota|publish --channel` is empty). The
  host loader `MainActivity.readBundle()` (`:126-140`) already has the *exact* seam — it prefers
  a `/data/local/tmp` dev override, else `readAsset("canopy.bundle.js")` — but no manifest, sha,
  internal-storage OTA path, or rollback.
- **Device farm + visual regression do not exist.** `e2e/` has a working local Appium2+WDIO Lumen
  spec (`run-e2e.mjs`, selecting `~choose` via the testID→a11y-id contract), a Maestro
  `flows/smoke.yaml`, and a serial local-AVD loop (`run-matrix.sh`) — but no FTL/BrowserStack
  wiring, no sharding, no screenshot baselines, no flake quarantine, no symbolication archive.
- **iOS distribution is authored, unbuilt.** `host/ios/` has full XcodeGen `project.yml` + Podfile
  + entitlements + a `remote-build.sh` SSH-to-a-Mac harness, but no `archive`/`exportArchive`/IPA
  path and no TestFlight upload. `versionCode 1`/`versionName 0.1` are hardcoded.

### Gap vs RN/Expo

EAS gives, and Canopy lacks: **(1) EAS Build** — managed cloud build of signed APK/AAB/IPA on
hosted Linux+macOS workers with **EAS-managed credentials** (keystore + Apple certs/profiles auto
generated and stored), driven by `eas.json` build profiles. Canopy builds on one Linux box or an
ad-hoc SSH-to-a-Mac script, with a committed dev keystore. **(2) EAS Submit** — one command uploads
the just-built artifact to Google Play (Play Developer API + service-account) and App Store Connect
(ASC API key), with track/release management. Canopy has none. **(3) EAS Update** — OTA channels
mapped to runtime versions, signed manifests, embedded fallback, automatic rollback. Canopy has no
updater. **(4) Device cloud** — sharded FTL/BrowserStack matrices with video/trace and dashboarded
flake; Canopy's farm is a serial local-AVD bash loop. **(5) Fingerprint/runtime-version gating** so
an OTA bundle only reaches a native binary that can run it; Canopy has no native↔bundle key.

### Milestones

| # | Milestone | Effort | Deliverable |
|---|-----------|--------|-------------|
| M0 | **Secrets + signing-from-CI** | S | CI builds signed APK **and** AAB from a `CANOPY_KEYSTORE_B64` secret (gradle prop fallbacks at `build.gradle:54-61` already accept them); release drops `x86_64`; committed dev keystore stops being load-bearing. |
| M1 | **`build --release` → store-ready artifacts** | M | Tool drives optimized bundle → `hermesc` HBC → signed `.aab` + archived sourcemap; bakes a `canopy.runtimeVersion` fingerprint (module list + `__fabric_*`/`__canopy_*` ABI version) the OTA + submit legs consume. |
| M2 | **Automated store submission (Play + App Store)** | M | `canopy-native submit` + a `release.yml` on `rc-*` tags uploads the AAB to Play (service-account) and the IPA to ASC (`.p8` key, via `remote-build.sh` archive→export→upload). **iOS Mac-gated.** |
| M3 | **OTA release channels (EAS Update equiv)** | L | `canopy-native publish --channel` ships a signed manifest+HBC to a bucket; new `CanopyUpdater` hooks the `MainActivity.readBundle()` seam (`:130`) as `dev → OTA-verified → embedded`, gated by `runtimeVersion`, with rollback-to-embedded on a bad boot. |
| M4 | **Cloud device farm + sharding** | L | The unchanged `run-e2e.mjs` Lumen spec fans across FTL (Android) + BrowserStack (iOS) cells via `e2e/config/matrix.ts` + `run-farm.sh` + `device-matrix.yml`, gated to `main`/`rc-*`. |
| M5 | **Visual baselines + flake quarantine + symbolication** | L | Per-device screenshot diffs (`wdio-image-comparison`, masked safe-area), `@flaky` auto-quarantine driven by `__canopy_idle`, and native+JS crash symbolication from the archived `.so` symbols + `.map`. |

> **Note — overlap with OTA.** This workstream's M3 is the *same* OTA implementation as the OTA &
> Rollback workstream above; they are sequenced together (managed-build M1's `runtimeVersion`
> fingerprint is the OTA gate, and OTA's `publish` reuses managed-build's HBC + signing). The roll-up
> in §4 counts the OTA work **once** (under the OTA workstream) and treats managed-build M3 as the
> distribution-side wiring of it.

### Approach notes

- **Build on plan-07, don't fork it.** M0/M1 extend the *already-on-disk* `build.gradle` release
  + `proguard-rules.pro` work into a credentialed CI pipeline; M3 is the *implementation* of
  plan-07 §9.1's OTA design, reusing its content-hashed manifest, §6.3 HBC, and the red-box as the
  rollback trigger.
- **One fingerprint, three consumers.** M1's `runtimeVersion` (a hash of the registered native
  module set + the `__fabric_*`/`__canopy_*` ABI version) is the EAS-fingerprint analog: M2 stamps
  it on the build, M3 hard-skips an OTA whose `runtimeVersion` the binary can't run. Conservative
  by construction — a JS-only bundle swap, never a native delta.
- **Reuse the loader seam.** OTA needs no new host plumbing beyond `CanopyUpdater`: the
  `readBundle()` precedence (`MainActivity.java:130`) already proves the override pattern; OTA
  slots in as `dev-override → OTA-verified → embedded asset`.
- **The farm spec is already platform-agnostic.** `run-e2e.mjs` selects by `~testID`, so M4 fans
  the *same* file across cells; the only new code is matrix config + the FTL/BrowserStack upload
  shims and a CI `if:` gate.

### Risks

1. **Committed dev keystore is a footgun** — M0 must make store builds secrets-only; the
   `.jks` in the tree is validation-only, never for upload.
2. **Store-API tooling weight** — a lean curl/`altool` uploader vs. fastlane/Gradle-Play-Publisher;
   pick per the tool's dependency-light ethos, accept the brittleness tradeoff.
3. **OTA must not brick** — wrong-`runtimeVersion` delivery or a corrupted-runtime crash; rollback
   must be pure-native (no JS re-entry), mirroring the red-box constraint.
4. **Store OTA policy** — `publish` must structurally refuse anything but a JS bundle swap (no
   native deltas) to stay compliant.
5. **Farm cost/quota** — full matrix gated to `main`/`rc-*`; PRs get the device-free gate + one
   local-emu smoke only.
6. **Visual flake** — status-bar/clock/safe-area diffs need per-device tolerance + masked regions
   or the gate becomes noise.
7. **iOS double-block** — every iOS leg (M2 IPA/submit, M4 BrowserStack, M5 symbolication) needs
   both the iOS bring-up *and* a Mac; authored on Linux, validated only on a Mac runner /
   `remote-build.sh`. Don't size them as done without plan-06.

### First ticket

**[M0] Move release signing to CI secrets and add the AAB to the gate.** In
`.github/workflows/ci.yml` `android-release`: base64-decode a `CANOPY_KEYSTORE_B64` secret to a
runner-local `.jks`, run `./gradlew :app:bundleRelease :app:assembleRelease` passing
`-PCANOPY_STORE_FILE/PASSWORD/KEY_ALIAS/KEY_PASSWORD` (the `findProperty` fallbacks at
`build.gradle:54-61` already accept them — no gradle change to wire them), upload the produced
`.aab` as an artifact alongside the APK, keep `apksigner verify`. In `build.gradle`, move the
`x86_64` abiFilter into the `debug` type so release drops it. This proves the managed-credential
path against the existing green build with zero new infra, and unblocks M2 (submit needs a
secrets-signed AAB).

---

## Dev Loop II — Dev Server, Fast Refresh, iOS Red-Box, Source Maps & Inspector

Area: **prod-readiness-dx** (Phase 4 continuation of plan 07). Phase 0 already killed the SIGABRT footgun: the C++ `guardJsCall` wraps every JS↔host re-entry site and routes errors to the plain-Java `CanopyRedBox` overlay, device-validated. What's left is the rest of the Metro-class loop — a real watch+push dev server, state-preserving Fast Refresh, stacks that point at `.can` lines, an iOS overlay at Android parity, and a Flipper-class inspector. This is the workstream that makes Canopy *feel* like RN/Expo to a developer, not just match it on the framework.

### Current state

- **Red-box (Android): DONE.** `guardJsCall` (`CanopyHostJni.cpp:61`) → `onJsError` (`CanopyHostJni.java:66`) → `CanopyRedBox.java` (plain Android views, survives a walker crash). Device-validated.
- **Hot-reload: a cold-restart shell script.** `scripts/dev.sh` shells `canopy-native build`, `adb push`es to `/data/local/tmp/canopy.bundle.js`, then `am force-stop`+`am start`. `MainActivity.readBundle()` (`MainActivity.java:130`) prefers that override. No socket, no state preservation. `CanopyHostJni.reload()` (`CanopyHostJni.java:74`) is an explicit stub ("until the dev-loop lands").
- **No `run`/`dev` command.** `Main.hs` dispatch (`tool/app/Main.hs:19`) is only `init|build|codegen|doctor|version|help`.
- **No source maps in the native path.** `assembleBundle` (`Bundle.hs:25`) takes no map and prepends a ~55-line preamble that shifts every line; `runCanopyMake` (`Build.hs:68`) omits `--source-map`; the host feeds no map to Hermes → stacks read `canopy.bundle.js:1:NNNNN`. `native.js` only `_Native_safeDraw` (`:747`) catches *draw* errors; init/update/Cmd continuations are uncovered.
- **iOS: log + tint only.** `reportFatal` (`CanopyHostViewController.mm:204`) `os_log_fault`s and tints the surface dark-red — no overlay.
- **No inspector** — but the full Hermes CDP/inspector chrome is already vendored (`host/android/vendor/hermes-include/hermes/inspector/chrome/CDPHandler.h`), `okhttp` is not yet a Gradle dep, and the e2e harness (`e2e/run-e2e.mjs`) already queries the `testID`→accessibility-id seam a tree-dump can reuse.

### Gap vs RN/Expo

Metro gives watch→transform→WS-delta-push, Fast Refresh with state preservation, a symbolication server feeding LogBox, and a Flipper/React-DevTools tree+props+perf inspector. Canopy has a cold-restart script, zero source maps, no devtools, and an iOS host that can only tint on a crash. Canopy's one structural advantage: the vendored Hermes CDP backend (the same protocol RN/Hermes already speak) plus a cheap native tree-dump straight off the third walker.

### Milestones

| # | Milestone | Effort | Key files |
|---|---|---|---|
| M0 | **Source maps end-to-end** (preamble-aware) | M | `Build.hs:68` (`--source-map`), `Bundle.hs:25` (`shiftSourceMap`), `native.js` (`__canopy_symbolicate`), `Spec.hs` (golden map) |
| M1 | **JS error-boundary + rejection coverage** | S | `native.js:728,747` (`_Native_guard`), `CanopyHostJni.cpp` boot (`__canopy_onError`, promise tracker), `Bundle.hs:48` |
| M2 | **`canopy-native run` + Node watch+WS dev server** | L | `Main.hs:19,90`, `Run.hs`+`DevServer.hs` (new), `tool/devserver/canopy-dev-server.js` (new), `src/debug/.../DevClient.java` (new, okhttp), `build.gradle` |
| M3 | **Host reload + state-preserving Fast Refresh** | M | `CanopyHostJni.cpp` `reload`, `CanopyHostJni.java:74`, `native.js` `__canopy_teardown/getState/bootWithState` + Model hash |
| M4 | **iOS red-box overlay (Android parity)** | M | `CanopyRedBox.mm` (new), `CanopyHostViewController.mm:64,204` — **Mac + 06-ios-bringup blocked** |
| M5 | **Inspector: tree + props + perf** | L | `CanopyHostJni.dumpTree()` (debug-only), `native.js:807` (perf counters), `tool/devserver/inspector/` (new); STRETCH: vendored Hermes CDP |

### Approach notes

- **M0 is the keystone and pure-Linux.** The compiler already emits V3 maps with `.can` `sourcesContent`; we just (a) ask for them (`--source-map`), and (b) re-align them past the constant-line preamble. Because `hermesPreamble` carries no mappings, adding its line count to every segment's generated-line is *exact* — no VLQ re-math needed beyond a single offset pass. Ship the shifted `.map` next to the bundle and symbolicate JS-side before the (already-shipped) red-box renders.
- **M2 leans on Node, not Haskell web deps** — Node is already a toolchain dep via `harness/`. The Haskell side just spawns `canopy-dev-server.js` (chokidar+ws); `DevClient` (okhttp) lives in `src/debug` so release strips it. Compile errors push `{type:'error'}` to the red-box — the "edit, see error inline" loop.
- **M3 ships full reload first, state preservation second**, gated behind a Model-type hash so a changed `Model` cleanly re-inits instead of decoding stale state.
- **M4 reuses the portable sink** — the `CanopyRedBox.mm` overlay mirrors the Java plain-views design and calls the same `__canopy_symbolicate`; only the UIKit shell is new, authored on Linux ahead of Mac time.
- **M5 ships the cheap native tree-dump first** (reusing the `testID` seam the e2e harness already drives), with the vendored Hermes CDP backend as an explicit stretch behind it.

### Risks

- The red-box must outlive a corrupted runtime — keep symbolication best-effort; `CanopyRedBox` already accepts a raw-string fallback.
- Fast-Refresh state preservation is best-effort (changed `Model` ⇒ undecodable); ship full reload first, gate the rest on a type hash.
- `--optimize` may break the constant-offset map assumption — dev is unoptimized; treat prod symbolication as a separate archived-map concern.
- `adb reverse` vs Wi-Fi LAN-IP: handle both or "reload does nothing" silently.
- `DevClient`/`dumpTree`/okhttp must be debug-variant-only; a missed keep-rule leaks them into release.
- The Hermes CDP stretch is version-coupled (0.76.9) — keep it behind the simple dump.
- iOS (M4 + iOS reload) is fully Mac- and Xcode-project-blocked; do not let it gate the Android-first M0–M3, M5.

### First ticket

**[DX] M0 step 1 — emit + align the source map.** Add `--source-map` to `runCanopyMake` (`Build.hs:68`) and confirm the iife path writes `<out>.js.map`; add `Bundle.shiftSourceMap :: Int -> Text -> Text` (`Bundle.hs`) that offsets every V3 segment's generated-line by the constant `hermesPreamble` line count; thread it through `finishBundle` (`Build.hs:85`) to write an aligned `canopy.bundle.js.map` + trailing `//# sourceMappingURL=`; lock it with a golden-map test in `tool/test/Spec.hs`. Pure-Linux, immediately makes the already-shipped Android red-box symbolicate to `.can` lines, and unblocks every later milestone.

---

## Navigation Library (React-Navigation equivalent)

A `.can` navigation library — stack/tab/drawer/modal navigators, native header + transitions, screen focus/blur lifecycle, gesture-back (iOS interactive swipe / Android predictive back), and deep-link → route mapping — built **over** the primitives already shipped, not as a new engine. Navigation state stays in the Elm/MVU model; native screen containers exist only where real native chrome (header, tab bar, drawer, a 60fps transition) demands one.

### Current state

The `canopy/navigation` package exists but ships only the *substrate*:

- **`navigation/src/Native/Navigation.can`** — a pure-value, Linux-testable `NavStack route` (non-empty stack) with `push`/`pop`/`popN`/`replace`/`replaceTop`/`reset`/`current`/`depth`/`isRoot`/`map`, plus an **advisory** `Transition (Push | Pop | Replace | None)` tag that "a renderer may read" — but nothing consumes it yet. Unit-tested in `navigation/tests/Test/Navigation.can`.
- **`navigation/src/Native/Lifecycle.can`** — the back-press half: `onBackPressed`/`appState`/`memoryPressure` as streaming `Sub`s and `allowDefaultBack` as a `Cmd`, over the C1 `Native.Module` ABI. The Android back path is real and device-validated: `MainActivity.enableBackInterception()` → `LifecycleModule.onBackPressed()` → `StreamingBridge.emit("Lifecycle","backPressed")`, registered as a streaming module at `CanopyHostJni.cpp:248`.
- **`navigation/src/Native/AppShell.can`** — status-bar style + color-scheme `Sub`.

The host already has the **host-node pattern** this library will reuse: `CanopyHost.java:271 makeView()` switches on the Fabric name, with a working `CanopyModalHost` (always-mounted overlay content, hardware-back→`requestClose`) and a side-effect `CanopyStatusBar` node — `Native.Modal.can`/`Native.StatusBar.can` show the `VirtualDom.node "CanopyXHost"` binding shape. The Android `Native.Animated` driver (`views/CanopyAnimDriver.java`) is the zero-JS-per-frame engine transitions will ride.

**Entirely missing (the React-Navigation surface):** no stack/tab/drawer navigator components, no native header bar, no screen transitions, no screen focus/blur (`useFocusEffect`) lifecycle, no deep-link URL→route parser, no inbound-URL channel (`PlatformModule` only does outbound `openURL`; there is no `getInitialURL`/`onNewIntent`), and no native screen containers (custom nodes still render empty at `native.js:238`).

### Gap vs RN/Expo

React-Navigation gives a batteries-included `createNativeStackNavigator` (native header: back chevron, title, large-title, right buttons; native push/pop transitions; iOS interactive swipe-back / Android predictive back), `createBottomTabNavigator`, `createDrawerNavigator`, nested navigators, `onFocus`/`onBlur`/`useFocusEffect`, and Linking config (`prefixes` + a path→route config tree, `getInitialURL`, `addEventListener`) mapping `myapp://x/42` to a screen + params and rebuilding the back stack. Canopy has only the model-side `NavStack` value and the raw hardware-back `Sub` — an app hand-rolls the entire navigator UI from a `case Nav.current` switch with no header, no animation, no focus lifecycle, and no deep linking.

### Milestones

| ID | Title | Size | Deliverable |
|----|-------|------|-------------|
| M0 | Navigator core in pure `.can` (stack over `NavStack` + transition) | M | `stack : Config route msg -> NavStack route -> Node msg`, header as a plain `Native.view` row, slide via existing `Native.Animated`. Zero host work — proves the whole library shape. |
| M1 | Screen focus/blur lifecycle (pure-MVU) | S | `onFocus`/`onBlur` as model-derived `msg`s; per-screen sub gating (`useFocusEffect` equiv). No native code. |
| M2 | Native header + `CanopyStackHost`/`CanopyScreen` + transitions (Android) | L | Host-owned 60fps slide via `CanopyAnimDriver`, native header bar, real per-route native subtrees. iOS authored only. |
| M3 | Tab + drawer navigators | L | `CanopyTabBarHost` (badges/icons/focus) + `CanopyDrawerHost` (edge-swipe/scrim); nested navigators = composed NavStacks. iOS authored only. |
| M4 | Gesture-back: iOS interactive swipe + Android predictive back | M | Finger-tracked pop at 60fps host-side; commits a `pop` only on release. Android runnable now; iOS authored. |
| M5 | Deep-link → route mapping | M | `getInitialURL` + `onUrl` Sub (host: `onNewIntent`/intent-filter), pure path-pattern parser → route + seeded back stack. |
| M6 | Docs, examples, test vectors, iOS run-parity | M | Stack+tabs+drawer demo, `@docs`, golden parser/focus vectors, iOS leg compiled+run on a Mac. |

### Approach notes

- **Pure-first, native-where-it-must-be.** M0/M1 add real navigator + focus semantics with **zero host changes**, riding the already-built Android primitives — a shippable library on day one. Native chrome (M2/M3) uses **named** `VirtualDom.node "CanopyStackHost"` host nodes (the supported path), so the `__2_CUSTOM`-renders-empty gap (`native.js:238`) is sidestepped, not blocked on.
- **Transitions reuse the Animated driver.** The host owns push/pop/swipe at 60fps via `CanopyAnimDriver.java` (and its clobber-proofing) — screens are kept mounted for the animation window (the Modal always-mounted pattern), then non-top screens unmount once settled.
- **Back is one channel, not a new ABI.** Android predictive-back (M4) upgrades the existing `OnBackPressedCallback` to `handleOnBackProgressed` and forwards progress into the stack host; commit still emits the existing `backPressed` channel.
- **Deep linking is mostly pure.** Only the inbound-URL plumbing is native (`PlatformModule.getInitialURL` + a `urlOpened` streaming channel from `onNewIntent`, registered like Lifecycle); the path→route+stack parser is pure `.can` over `canopy/url`, pinned by shared golden vectors.
- **iOS authored on Linux, run on a Mac.** `CanopyStackHost`/`TabBar`/`Drawer`/edge-swipe/inbound-URL `.swift` are written and compile-reviewed now; compile/run/sign is Mac-gated to M6 and the iOS Xcode bring-up.

### Risks

- Re-implementing native header/transition/interactive-swipe at parity by hand is the biggest effort and most likely to feel subtly off vs UINavigationController — keep M0 (pure, no chrome) as a shippable fallback.
- Multiple mounted screens + all-mounted tabs compete with list virtualization for memory; unmount non-top screens after settle and gate background-tab subs via M1 focus.
- Gesture-back must commit/cancel **host-side**; a cancelled swipe that leaks a `pop` into `update` desyncs the stack from the animation.
- Deep-link back-stack seeding must match React-Navigation's `getStateFromPath` semantics for nested navigators/params — pin with golden vectors.
- iOS UIKit lifecycle/gesture bugs won't surface until the first Mac run (M6).

### First ticket

**[Navigation] Ship M0: `navigation/src/Native/Navigation/Stack.can`.** Define `Config route msg` (a `route -> Screen msg` renderer + header config) and `Screen msg` (header title / leftButton / rightButtons / body); implement `stack : Config route msg -> NavStack route -> Node msg` rendering the top route with a plain-`Native.view` header row (back chevron → `Native.Events.onPress` → a `GoBack` msg), plus `navigate`/`goBack` pure helpers returning a new `NavStack` + `Transition`, with a translateX slide between outgoing/incoming screens through the existing `Native.Animated`. **Zero host changes** — proves the whole library shape on the device-validated Android primitives and pins the public API M1–M6 fill in. Add `navigation/tests/Test/NavigationStack.can` golden tests for `navigate`/`goBack` and the "top is focused" invariant.

---

## Accessibility Depth (beyond testID)

**Area:** `accessibility` · **Phase:** 4 · **Builds on:** Testing T0 (`testID`/label/role), Animation (`CanopyAnimDriver`), AppShell streaming-Sub pattern.

**Goal:** carry Canopy Native from the shipped *identity* seam (testID + label + role + hint) to **full React-Native / Expo a11y depth** — roles+states+values, screen-reader focus management and announcements/live regions, accessibility actions, dynamic type / font scaling, RTL/bidi layout, and reduced-motion honoring in the animation driver — across both hosts from one compiled bundle.

### Current state (file:line evidence)

T0 is done and **symmetric** on both hosts. `Native.Attributes` declares `accessibilityRole/Label/Hint/accessible` + `testID` as plain VDOM attributes (`src/Native/Attributes.can:11`, `:289-322`) that ride the `a__1_ATTR` → `_Native_factsToProps` path with **no walker change**. Android `CanopyHost.applyProps` consumes all five (`CanopyHost.java:454-470`): testID/label → `setContentDescription`, role → an `AccessibilityDelegate` mapping role→className/tooltip (`installAccessibilityDelegate` `:480-490`, `roleToClassName` `:492-502` — only button/image/header/link/checkbox/switch), `accessible` → `setImportantForAccessibility`, each with reset-on-null. iOS mirrors it (`CanopyHostFabric.mm:1817-1856`): testID→`accessibilityIdentifier`, label, hint, `applyA11yRole` (replace-not-OR traits), `isAccessibilityElement`.

**That is the entire surface.** Confirmed absent everywhere in the tree: `accessibilityState` (selected/checked/disabled/busy/expanded), `accessibilityValue`, programmatic **focus**, **announcements / live regions**, **accessibility actions**, **dynamic type** control (SP units scale at `CanopyHost.java:581` but there's no app-readable `fontScale`, no cap, no opt-out), **RTL/bidi** (no `YogaNode.setDirection`, only `YogaEdge.LEFT/RIGHT/HORIZONTAL` at `:529-543`; no start/end keys in `Native.Css`; `textAlign` maps left/right not start/end `:591-597`), and **reduced-motion** (`CanopyAnimDriver.doFrame` `:132` runs timings/springs unconditionally; nothing reads `AccessibilityManager` / `Settings.Global` transition scale). The build-on infrastructure exists: the streaming-Sub `AppShellModule.colorScheme` (`AppShellModule.java:113-139`, `registerComponentCallbacks(onConfigurationChanged)` + `StreamingBridge.emit`) is the exact precedent for a settings-change Sub, the C1 ABI + `Native.Module.callStreaming` (`Module.can:88`) is the precedent for an imperative/query module, and `CanopyAnimDriver` is a single host-owned engine with one `doFrame` chokepoint where reduced-motion is honored centrally.

### Gap vs RN/Expo

RN ships and Canopy lacks: `accessibilityState`/`accessibilityValue` → node state; `AccessibilityInfo.announceForAccessibility` + `accessibilityLiveRegion`; `setAccessibilityFocus`; `accessibilityActions` + `onAccessibilityAction` (custom rotor actions, standard increment/decrement); `AccessibilityInfo.isReduceMotionEnabled/isScreenReaderEnabled` as queries **and** change events with Animated auto-honoring reduce-motion; `PixelRatio.getFontScale` + `maxFontSizeMultiplier`/`allowFontScaling`; and full RTL via `I18nManager` with Yoga direction + start/end edges + `writingDirection`.

### Milestones

| # | Milestone | Effort | Platform |
|---|-----------|--------|----------|
| M0 | `.can` a11y API — states/values/actions/live/focus + `Native.Accessibility` module | S | shared |
| M1 | Android: `accessibilityState`/`Value` + live regions | M | Android |
| M2 | Android: announcements, focus, accessibility actions | M | Android |
| M3 | Android: dynamic type / font scaling controls | S | Android |
| M4 | Android: RTL / bidi layout (Yoga direction + start/end edges) | M | Android |
| M5 | Reduced-motion honoring in the animation driver | S | both (iOS authored) |
| M6 | iOS parity port (states/values/announce/focus/actions/RTL/type) | L | iOS (Mac-gated) |
| M7 | a11y testing depth + audit gate | M | both |

**Ordering rationale:** M0 is the device-free contract every host milestone consumes; it lands today with zero platform dependency. M1→M4 build Android depth on the existing `applyProps` + delegate seam. M5 is a tiny, high-value central change at the one `doFrame` chokepoint. M6 ports the lot to iOS (authored on Linux, run on a Mac). M7 makes it all CI-gated and adds an automated a11y audit.

### Approach notes

- **Serialize structured props as compact JSON strings** (state/value/actions), exactly as `Native.Animated.animations` does (`Animated.can:204-211`), to sidestep the native bundler's higher-order-FFI tree-shake footgun and to get value-diffing for free.
- **One delegate, more node fills.** M1/M2 extend `installAccessibilityDelegate` (`CanopyHost.java:480`) — `setCheckable/Checked/Selected/Enabled`, `setRangeInfo`, `addAction`, and a composed `stateDescription` — rather than adding new view types. Compose the spoken string as label → role → state → value with `testID` kept out of the spoken path when a label exists (resolves plan 08 risk #2).
- **Settings-change Sub** reuses `StreamingJniModule`/`StreamingBridge` (no new transport): one `Accessibility.settingsChanged` channel emits `{fontScale, isRTL, reduceMotion, screenReader}` on `onConfigurationChanged` / `AccessibilityManager` callbacks, priming the current value like `colorScheme` does.
- **Reduced-motion is a single flag** read in the `CanopyHost` ctor and refreshed via the Sub; `CanopyAnimDriver.start` snaps `current=to` and emits start+end immediately when set, **honoring the owned-prop + resting-value contract** so static style is never clobbered (opacity may keep a short cross-fade, matching RN).
- **RTL** sets `YogaNode.setDirection` from `getLayoutDirection()` (verify propagation onto **recycled** subtrees — same reset-on-recycle hazard this codebase has hit for style/events) and adds `start/end` longhands to `Native.Css` + the host. Forced-RTL needs an activity recreate (RN's same caveat — documented, not promised instant).
- **iOS (M6)** extends the existing `applyProps` a11y block (`CanopyHostFabric.mm:1817`) and `applyA11yRole`, plus a `CanopyAccessibilityModule.mm` calling `ctx.complete` directly (no JNI); `UIAccessibility.post(.announcement/.layoutChanged)`, `accessibilityCustomActions`, `UIContentSizeCategory`→fontScale, `semanticContentAttribute` for RTL. Authored on Linux, Mac-gated to run.

### Risks

- `contentDescription` is already double-booked (testID + label); layering `stateDescription` risks confusing/leaky TalkBack output — needs a defined composition order.
- `accessibilityLiveRegion` auto-announces on any content change; with re-render re-applying text, must **diff-gate** announcements or it spams.
- Yoga direction may not reach recycled containers (RTL silently fails on diffed screens) — needs a verified propagation pass.
- Reduced-motion snap must preserve `isOwned`/`cancelMissing` bookkeeping + emit `animationEnd`, or it clobbers static style next re-render.
- Uncapped font scale breaks fixed-height Yoga layouts; the app must opt into re-layout via the fontScale Sub (a behavioral gap, not just API).
- Custom actions must tear down on view recycle (the stale-handler hazard `setEvents` already guards, `:238-242`).
- iOS a11y is unrunnable on the Linux box; M6 ships authored-but-unverified until Mac validation.

### First ticket

**[M0] Extend the `.can` a11y surface (no host code).** In `src/Native/Attributes.can` add `accessibilityState` (`List (String,Bool)` → compact-JSON-string attr, per `Animated.can:204-211`), `accessibilityValue` (record→JSON string), `accessibilityLiveRegion` (`none|polite|assertive`), `accessibilityActions` (`List String`→JSON array); update the exposing list (`:11`) and `@docs` (`:36`). In `src/Native/Events.can` add `onAccessibilityAction : (String -> msg) -> Attribute`. Create `src/Native/Accessibility.can` — a `Native.Module` wrapper (module `"Accessibility"`) with `announce`/`setFocus`/`getFontScale`/`isReduceMotionEnabled`/`isScreenReaderEnabled`/`isRTL` one-shot Tasks + a `settingsChanged` Sub via `callStreaming` (mirror `Native.Platform` + `AppShellModule.colorScheme`). Expose it in `canopy.json`. Prove it device-free by extending `native/harness/run-a11y.js` to assert each new prop lands top-level and resets to `undefined` on recycle — green in CI with no emulator. This is the contract M1–M6 consume, and it lands today with zero platform dependency.

---

## Production Observability — Crash Symbolication, Reporting, Analytics & Perf

Area: **observability**. Today a JS crash is *captured* but unreadable, a native crash is invisible,
and there is no way to know an app even shipped a bad build to a real user. The red-box
(`guardJsCall` → `onJsError` → `CanopyRedBox`) is the foundation; this plan turns it into the
RN/Expo-equivalent of `@sentry/react-native` + `metro-symbolicate` + EAS symbol upload +
Performance vitals.

### Current state (file:line evidence)

- **JS-crash capture works, symbolication does not.** `host/android/app/src/main/jni/CanopyHostJni.cpp:59-73`
  (`guardJsCall`) wraps 5 JS↔host re-entry sites (boot:258, callback:283, event:293, plus
  `__canopy_resolve` in `CanopyModules.cpp`), catches `jsi::JSError`, extracts `.getStack()`, and
  routes via `reportJsError` (cpp:50) → `CanopyHostJni.onJsError` (`.java:66`) → `CanopyRedBox.show`
  (`CanopyRedBox.java:30`), a plain-Android overlay that survives a walker crash. **But** `Bundle.hs`
  emits no `//# sourceMappingURL`, and `Build.hs:finishBundle` (76-87) writes only `canopy.bundle.js`
  — no `.js.map`. Stacks read `canopy.bundle.js:1:NNNNN` (one giant line).
- **No native (.so) symbolication.** `build.gradle:63-76` release has R8 + signing + `proguard-rules.pro`
  but **no** `ndk { debugSymbolLevel }`, no `.so` archiving, and `proguard-rules.pro` keeps
  `Signature, InnerClasses` but **not** `SourceFile,LineNumberTable` (Java release frames are line-stripped).
- **No crash SDK, analytics, or perf.** Grep for Sentry/Crashlytics/analytics/breadcrumb across
  `host/`+`package/`+`tool/` hits only vendored Hermes headers. The C1 ABI
  (`__canopy_call`/`ModuleRegistry`) is the clean seam, unused for this.
- **Async/native gaps.** `guardJsCall` only catches at synchronous C++ catch sites — unhandled promise
  rejections and native signals (SIGSEGV/SIGABRT in C++/JNI/ORT) are uncaught. `_Native_safeDraw`
  (`native.js:747`) swallows draw errors to `console.error` only.
- **Perf seam exists.** A single global `Choreographer.FrameCallback`
  (`views/CanopyAnimDriver.doFrame(frameTimeNanos)`, line 132) already runs every frame; `MainActivity.onCreate:46`/`boot:73`
  is the cold-start seam. Roadmap Phase 4 (`00-roadmap.md:273-274`) scopes exactly this.

### Gap vs RN/Expo

RN/Expo ship Metro live + offline symbolication, Hermes `.hbc` maps, one-line Sentry/Crashlytics/`expo-insights`
that auto-capture the red-box JS error, native NDK tombstones, ANRs, breadcrumbs, release/dist tagging, and
TTID/TTFD vitals with managed dSYM/.so upload in EAS. Canopy has the capture point but **none** of the
symbolication, reporting, analytics, or vitals.

### Milestones

| # | Milestone | Effort | Key files |
|---|---|---|---|
| M0 | Source-map generation + archiving | S | `Build.hs:66,76`, `Bundle.hs` (`shiftSourceMap`), `tool/test/Spec.hs` |
| M1 | JS symbolication → red-box (dev) + `canopy-native symbolicate` (prod) | M | `native.js` (`__canopy_symbolicate`), `CanopyHostJni.cpp:50`/`.java:66`, `Main.hs:19` |
| M2 | Native `.so` symbolication: archive unstripped libs + ndk-stack | S | `build.gradle` (`debugSymbolLevel`), `proguard-rules.pro` (+`SourceFile,LineNumberTable`), `Main.hs` (`ndk-stack`) |
| M3 | Native-signal + unhandled-rejection capture | M | `host/shared/cpp/CanopySignal.cpp/.h` (new), `CanopyHostJni.cpp` boot, `native.js`, `MainActivity.onCreate` |
| M4 | Observability module (C1 ABI): crash upload + analytics + breadcrumbs | L | `modules/ObservabilityModule.java` (new), `package/src/Observability.can`+`external/observability-native.js` (new) |
| M5 | Runtime vitals (frame drops, JS-thread time, cold-start) | M | `views/CanopyAnimDriver.java:132`, `CanopyHostJni.cpp:283,293`, `CanopyVitals.java` (new), `MainActivity.onCreate` |
| M6 | CI symbol-archive + release tagging + doctor checks | S | `.github/workflows/ci.yml`, `Doctor.hs` |

> **Note — shared source-map keystone.** This workstream's M0/M1 are the *same* source-map work as
> the DX dev-loop M0/M1 (the `shiftSourceMap` + `__canopy_symbolicate` pair). They are one
> deliverable wearing two hats — DX consumes it for the live red-box, observability for offline prod
> symbolication. §4 counts the source-map keystone **once** (under DX) and treats this workstream's
> M0/M1 as the archiving + offline-CLI extension of it.

### Approach notes

- **One build-id, everywhere.** M0 computes `buildId = sha256(bundle)`; M2's `.so` archive, M4's
  Sentry `release`/`dist`, and the OTA manifest all key off it so any prod crash (JS *or* native)
  resolves to the exact `.map` + unstripped `.so` that shipped.
- **Reuse, don't re-back.** Symbolication reuses the compiler's existing V3 `SourceMap.hs`; the only
  new tool code is the constant line-offset shim (the preamble carries no mappings). The crash/analytics
  transport reuses the Net/HTTP module's OkHttp — no second HTTP stack.
- **The C1 ABI is the API surface.** Analytics/`captureException`/`addBreadcrumb` are just methods on a
  registered `ObservabilityModule`, reached by `.can` code through an effect-module twin, exactly like
  Echo/Streaming. Prod-fatal `onJsError` calls `captureException` before the branded error screen.
- **Vitals ride the loop that already exists.** Frame jank is computed inside the one global
  `CanopyAnimDriver.doFrame` (allocation-free, as that file requires); JS-thread time brackets the
  `guardJsCall` dispatch sites; cold-start is two `elapsedRealtime` stamps. This *measures* the
  no-JS-per-frame property rather than adding overhead to it.

### Risks

- **Async-signal-safety** in M3's native handler: only `write`/`unwind`/`dladdr`, pre-allocated buffers,
  persist-then-upload-next-boot, chain the prior handler. No malloc/JNI/locks in-handler.
- **Optimized-build maps**: the compiler's `--optimize` path may not emit a usable map; prod may need a
  dedicated map-archiving build even though shipped JS strips `sourceMappingURL`.
- **R8 name obfuscation**: keep `LineNumberTable` *and* archive `mapping.txt` per release, or Java
  frames stay unreadable.
- **Privacy/offline**: uploader must queue offline, never block boot, scrub PII, honor a kill-switch.
- **HBC coupling**: if release ships `.hbc`, the map must come from the same hermesc pass.
- **iOS** halves (sigaction, `ObservabilityModule.mm`, CADisplayLink vitals, dSYM archive) are authored
  portable but parked behind the Mac bring-up.

### First ticket

**M0 — emit a bundle-aligned source map.** Add `--source-map` to `runCanopyMake` (`Build.hs:66`),
confirm the iife path writes `app.iife.js.map`, add `shiftSourceMap :: Int -> Text -> Text` to
`Bundle.hs` offsetting every segment by `length (T.lines hermesPreamble)`, and in `finishBundle`
write `canopy.bundle.js.map` + a `//# sourceMappingURL` trailer + `buildId = sha256(bundle)`. Golden
test in `tool/test/Spec.hs`. Pure Haskell, no device, no Mac — unblocks every downstream piece.

> **Sequencing note:** because Observability M0/M1 == DX M0/M1, do the source-map keystone **once**,
> first, then let *both* workstreams' downstream milestones consume it.

---

## 4. Consolidated effort roll-up

Sizing per the standard bands: **S ≈ 0.75 pw · M ≈ 1.75 pw · L ≈ 3.5 pw · XL ≈ 6.5 pw.**

### 4.1 Raw roll-up (every milestone counted as written)

| Workstream | Milestones | Size breakdown | pw |
|---|---|---|---|
| Capability ecosystem + `gen-capability` codegen | 9 | 2M · 4L · 3XL | **37.00** |
| Navigation library | 7 | 1S · 4M · 2L | **14.75** |
| Managed build + distribution + device matrix | 6 | 1S · 2M · 3L | **14.75** |
| Dev Loop II (dev server / Fast Refresh / iOS red-box / source maps / inspector) | 6 | 1S · 3M · 2L | **13.00** |
| Accessibility depth | 8 | 3S · 4M · 1L | **12.75** |
| Third-party native escape hatch (HostComponent / SDK) | 6 | 1S · 4M · 1L | **11.25** |
| Production observability (crash / reporting / analytics / perf) | 7 | 3S · 3M · 1L | **11.00** |
| OTA updates + rollback | 5 | 1S · 3M · 1L | **9.50** |
| **Raw total** | **54** | — | **≈ 124 pw** |

### 4.2 Reconciling against the roadmap's ~50 pw

The raw 124 pw is the **full, both-platforms, complete-fan-out** long tail. The roadmap's
**~50 pw** Phase-4 figure is the **Android-first v1 ecosystem cut** — the slice that makes Canopy a
credible Expo competitor on the platform that *builds today*, with the rest sequenced as fast-follow.
Three structural sources of the delta, each subtracted to get from 124 → ~50:

| Delta source | What it removes | pw removed |
|---|---|---|
| **iOS run-legs collapse onto one Mac-gated pass** | Every workstream carries an iOS port (Cap M8 XL, A11y M6 L, Nav iOS legs ~L, DX M4 M, Escape iOS legs ~M, Managed/Observability iOS legs ~M). These are *authored on Linux now* but cannot **run** until the iOS bring-up (plan 06) + a Mac — out of this Android-first cut's delivery scope; they collapse into the single iOS-bring-up effort, not eight separate ports. | **≈ 19** |
| **Heavy fan-out + stretch deferred past the first cut** | The capability long-pole XLs (M5 Geo/Bio/Sensors/Links, M7 Camera/Audio/Video/Background) and the inspector/CDP stretch (DX M5), tab/drawer/deep-link/gesture-back (Nav M3–M5), the device farm + visual-regression (Managed M4/M5), and the analytics-module + vitals (Observability M4/M5) are fast-follow, not v1. | **≈ 40** |
| **Shared substrate + codegen counted once** | Source-maps+HBC+asset-manifest appears framed in 4 workstreams (DX M0, OTA M0, Managed M1, Observability M0/M1) but is **one** build-out; the SDK scaffolder (Escape M4) reuses `gen-capability`; the OTA work is double-listed under OTA *and* Managed-build M3. De-duplicating these recovers the duplicate framings. | **≈ 15** |

Net Android-first v1 cut (substrate-bearing + moat + the parallel DX/nav/a11y/observability tracks,
iOS run-legs and the heaviest fan-out deferred):

| v1-cut workstream slice | Milestones kept | pw |
|---|---|---|
| Capability: M0–M3 (bytes-blob + codegen + Permissions + Net/Http/WS) | 4 | 10.50 |
| OTA: M0–M3 (manifest+HBC + publish + updater + rollback) | 4 | 8.75 |
| Dev Loop II: M0–M3 (source-maps + error boundary + dev server + Fast Refresh) | 4 | 7.75 |
| Escape hatch: M0–M3 (ABI freeze + view registry + `hostComponent` + module reg) | 4 | 6.00 |
| Navigation: M0–M2 (pure stack + focus + native header/transition) | 3 | 6.00 |
| Accessibility: M0–M3 + M5 (the `.can` surface + Android depth + reduced-motion) | 5 | 5.75 |
| Managed build: M0–M2 (secrets-signing + release artifacts + submit) | 3 | 4.25 |
| Observability: M0–M3 (map archive + symbolicate + ndk-stack + signal capture) | 4 | 5.00 |
| **v1 ecosystem cut total** | **31** | **≈ 54 pw** |

**That ≈ 54 pw lands on the roadmap's ~50 pw within rounding** (the small over is the codegen `L`,
which is genuinely load-bearing and pulled into v1 because it gates all breadth). The honest reading:

- **~50 pw** = the Android-first slice that closes the Expo gap on the buildable platform.
- **~124 pw** = the complete long tail across **both** platforms with the full capability fan-out,
  the media/sensors set, the device farm, the inspector, and every iOS run-leg — i.e. the genuine
  multi-quarter total this phase is named for.

The delta is **not** double-counted work that vanishes; it is **deferred or iOS-gated** work that is
real but sequenced after the v1 cut. State both numbers to whoever holds the timeline: Phase 4's
*minimum credible* is ~50 pw, its *complete* is ~124 pw, and the difference is iOS-on-a-Mac + the
breadth fan-out.

---

## 5. Start here — the first five tickets

The highest-leverage first tickets across the eight workstreams, ordered by how much they unblock.
The first three are the substrate every downstream milestone rides; tickets 4–5 are the moat-openers
that can start in parallel on day one. All five are **Android/Linux-buildable today — no Mac required.**

### 1. Source-maps end-to-end (DX M0 / Observability M0 — the shared keystone)

Add `--source-map` to `runCanopyMake` (`tool/src/Canopy/Native/Build.hs:66-69`) and confirm the iife
path writes `<out>.js.map` (the compiler's V3 writer already exists in
`Generate/JavaScript/SourceMap.hs`). Add `Bundle.shiftSourceMap :: Int -> Text -> Text` that offsets
every V3 segment's generated-line by the constant `hermesPreamble` line count (the preamble carries
no mappings, so the offset is exact), thread it through `finishBundle` (`Build.hs:85`) to write a
`canopy.bundle.js.map` + a `//# sourceMappingURL` trailer + `buildId = sha256(bundle)`, and lock it
with a golden-map test in `tool/test/Spec.hs`. **Why first:** pure-Haskell, no device, no Mac; it
*immediately* makes the already-shipped Android red-box symbolicate to `.can` lines, and it is the
prerequisite for the DX red-box, the iOS red-box, the inspector, and all of observability. One
deliverable, two workstreams.

### 2. Content-hashed asset manifest + HBC substrate (OTA M0 / Managed-build M1)

Land `tool/src/Canopy/Native/Assets.hs` (`AssetEntry`/`AssetManifest` + `collectAssets` sha256'ing
the assembled bundle + each `native.config.json` asset), extend `Config.hs` with `ncAssets` +
`ncRuntimeVersion`, and rewrite `Build.hs:finishBundle` to write `canopy.manifest.json` and copy
bundle+assets into `host/android/app/src/main/assets` (skipping on matching sha). Delete the
hand-copied 363 KB `assets/canopy.bundle.js`, gitignore `assets/` with a `.gitkeep`, and have
`MainActivity.readBundle()` verify the booted bundle's sha against the manifest. **Why second:** kills
the manual-`cp` footgun the roadmap flags as a Phase-0 unblocker, and is the shared substrate OTA,
managed-build, and observability's buildId all consume. Pure-Linux.

### 3. Bytes-blob JNI bridge (Capability M0 — the capability-fan-out substrate)

In `host/shared/cpp/CanopyJni.{h,cpp}` add `BlobHandle jniBlobPutBytes(JNIEnv*, jbyteArray)` and
`jbyteArray jniBlobGetBytes(JNIEnv*, BlobHandle)` alongside `jniBlobPutBitmap/GetBitmap`
(`CanopyJni.h:153-154`), storing/reading a `Blob{kind:"bytes"}` in `globalBlobRegistry` (the struct
already enumerates `"bytes"` — no struct change), and expose both to Java via `CanopyHostJni`. Add a
Node-harness assert that put→get round-trips bytes intact. **Why third:** the smallest standalone
unblocker for HTTP multipart/streaming bodies, `Fs`, Camera, and Audio — and it is independent of the
codegen, so it can land in parallel with tickets 1–2 while the structured-error migration (the other
half of Cap M0) proceeds.

### 4. Freeze the public extension ABI (Escape-hatch M0 — the moat contract)

Add `host/shared/cpp/CanopyAbi.h` (a `CANOPY_ABI_VERSION` macro + the `NativeModule` re-export + a new
`CanopyViewFactory` abstract: `create(handle)`/`applyProps`/`reset`/`isLeaf`/`measure`), declare
`globalThis.__canopy_abi_version` in `native.js` next to the `__2_*` tag constants, and write
`docs/extension-abi.md` stating the frozen JS/C++ surface and the survival rule. **Why fourth:** pure
extraction + version stamp, no behavior change, platform-neutral so iOS inherits it. It is the contract
the *entire* third-party ecosystem (the #1 moat deficit) binds against, *and* the ABI version is the
OTA compatibility key — so freezing it early unblocks both the escape-hatch and OTA's `runtimeVersion`
gate. Can start day one, in parallel.

### 5. Ship the pure-`.can` navigator core (Navigation M0)

Add `navigation/src/Native/Navigation/Stack.can`: a `Config route msg` (a `route -> Screen msg`
renderer + header config) and `Screen msg` record, a `stack : Config route msg -> NavStack route ->
Node msg` rendering the top route with a plain-`Native.view` header row (back chevron →
`Native.Events.onPress` → a `GoBack` msg), `navigate`/`goBack` pure helpers returning a new `NavStack`
+ `Transition`, and a translateX slide between outgoing/incoming screens via the existing
`Native.Animated`. Add `navigation/tests/Test/NavigationStack.can` golden tests. **Why fifth:** zero
host changes — it proves the entire React-Navigation-equivalent library shape on the already-shipped,
device-validated Android primitives and pins the public API the rest of the navigation milestones fill
in. A shippable navigation library on day one, in parallel with everything above.

> **The through-line of all five:** every first ticket is Linux/Android-buildable, independently
> useful the day it lands, and unblocks a disproportionate share of what follows — the source-map
> keystone (two workstreams), the asset+HBC substrate (three), the bytes-blob (the whole capability
> fan-out), the ABI freeze (the moat + OTA gate), and the navigator core (the nav library). None
> waits on the Mac. Start them in parallel; the iOS run-legs sequence strictly after the iOS bring-up.
