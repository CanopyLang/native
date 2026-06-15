# C1 — The native-module effect ABI (implemented)

This document records the **C1 foundation** of the Canopy-native build-out (plan
`lumen/plan/canopy/C1`): the one mechanism by which a Canopy package exposes a native
platform capability (ML inference, photo picker, billing, file I/O, share) as a
first-class TEA `Cmd`/`Sub`, with results flowing back into `update` exactly the way
`Http` and `Storage` do on the browser. **Every other capability (C2–C8) is a consumer of
this ABI.** C1 has no dependencies — it is the base of the pyramid.

It is the effect-system sibling of the existing render wedge: `external/native.js` swaps
the *render* seam (VirtualDom → Fabric); C1 swaps the *effect* seam (a `Cmd` that would
reach a Web API instead reaches a JSI host function the C++ host installs).

> **Thesis preserved.** `compiler/`, `core/` (incl. `core/external/runtime.js`),
> `virtual-dom/`, and the kernel walker `native.js` are **untouched**. C1 is purely
> additive: a new Canopy support package + its FFI, new portable C++ host code, and host
> boot wiring.

---

## The ABI (one generic dispatcher, three globals)

Every native module is registered into a single C++ `ModuleRegistry` and invoked through
exactly three JSI globals — never one global per method:

| Global | Direction | Meaning |
|---|---|---|
| `__canopy_call(module, method, argsJson, callId)` | JS → host | dispatch `(module, method)`; returns `0` accepted / `-1` not found |
| `__canopy_cancel(callId)` | JS → host | cancel an in-flight call (best-effort) |
| `__canopy_resolve(callId, errJson, resultJson)` | host → JS | deliver a completion/stream event (JS **self-installs** this; the host *calls* it on the JS thread) |

- **Marshalling:** JSON strings + ints, identical to the `__fabric_*` surface. Args go
  out as one `argsJson`; results come back as one `resultJson` and are decoded by the
  caller's `Json.Decode.Decoder` in JS.
- **Binary stays native:** decoded bitmaps / model tensors / picked bytes are **never**
  JSON — they live in a `BlobRegistry` keyed by an opaque `int32` handle (a 12 MP scan is a
  handle, not a base64 string). See `CanopyBlobs.h`.
- **Threading:** heavy work runs on a native worker thread and calls `ctx.complete()` from
  there; the registry hops that completion onto the JS thread (`postToJs`) before touching
  the single-threaded Hermes runtime. This is the one invariant the ABI rests on.

Full lifecycle:

```
update → Echo.send (Cmd) → Native.Module.call → __canopy_call("Echo","send",argsJson,callId)
  → registry.dispatch → module.invoke → [worker thread does the work]
  → ctx.complete("", resultJson) → postToJs → __canopy_resolve(callId, null, resultJson)
  → caller's decoder → sendToApp → update  (re-renders via one targeted updateProps)
```

---

## What was implemented

### Canopy + JS (the binding template — the only place `__canopy_call` is touched)
- `package/src/Native/Module.can` — the `Native.Module` support module: `call`,
  `callStreaming`, `cancel`, `Error(..)`. Capability packages import this; they never touch
  the ABI directly. (Added to `package/canopy.json` `exposed-modules`.)
- `package/external/native-module.js` — the FFI binding: mints `callId`s, drives
  `__canopy_call`, self-installs `__canopy_resolve` (lazily, from the bound entry points —
  the compiler drops bare top-level statements), maps results/errors back into the TEA loop.
  Modeled byte-for-byte on `storage.js`/`http.js`.

### Portable C++ host (compiles against real JSI; no platform headers)
- `host/shared/cpp/CanopyModules.{h,cpp}` — `CallContext`, `NativeModule`, `ModuleRegistry`
  (the dispatcher + the worker→JS hop), `installCanopyModules`, `canopyResolveCall`.
- `host/shared/cpp/CanopyBlobs.{h,cpp}` — the opaque binary-handle registry (refcounted).
- `host/shared/cpp/EchoModule.{h,cpp}` — the **C1 reference capability**: `send` (one-shot,
  on a worker thread), `ticks` (streaming), `cancel`. The executable proof of the threading
  invariant — the worker never touches the runtime; only `ctx.complete` (→ `postToJs`) does.
- `host/shared/CMakeLists.txt` + vendored JSI headers (`third_party/jsi`) — a reproducible
  build of the whole portable host (host type-check **and** Android NDK arm64).
- `host/shared/cpp/CanopyFabric.cpp` — dropped an unused `#include <jsi/JSIDynamic.h>` (it
  pulled in folly but is never used; marshalling is via the runtime's own JSON).

### Host boot wiring (integration templates — the iOS/Android preconditions)
- `host/ios/CanopyHost/CanopyHostViewController.mm` — creates the registry, **wires
  `_runtime.get()`** into it (the iOS `jsi::Runtime*` precondition, C1 §3.4), sets
  `postToJs = dispatch_async(main)`, installs the module ABI, registers `EchoModule`.
- `host/android/.../jni/CanopyHostJni.cpp` — adds the registry + a real **`postToJs`
  Looper hop** (replacing the inline `requestFrame`, C1 §3.5), installs the ABI, registers
  `EchoModule`.
- `host/android/.../java/com/canopyhost/CanopyHostJni.java` — `scheduleOnJs`/`runJsCallback`
  posting onto the main Looper (the JS thread for the direct-views host, matching iOS).

### Reference app + proof harness
- `examples/echo/` — the C1 first-light app: tap **Ping** → `Echo.send` → async reply lands
  in `update`. (Mirrors `examples/counter`, which proves the *render* path.)
- `harness/mock-native-modules.js` — an in-memory `ModuleRegistry` that models the
  worker→JS hop with an explicit drainable queue.
- `harness/run-echo.js` — drives the **real compiled bundle** (real runtime + real ABI)
  end-to-end.

---

## Verification status (what is proven, and where)

| Proof | How | Result |
|---|---|---|
| Echo round-trip through the **real** runtime: success, genuine async ordering (pending-before-hop), module-not-found, native rejection, decode mismatch, single targeted `updateProps`, handle identity preserved | `cd native/harness && node run-echo.js` | **22/22 PASS** |
| Render wedge still green (counter, source + compiled) | `npm test` in `harness/` | 17/17 + 14/14 PASS |
| Portable C++ host (CanopyFabric + **CanopyModules + CanopyBlobs + EchoModule**) compiles to real object code against the **actual Facebook JSI API**, `-Wall -Wextra` | `cmake -S host/shared -B build-host && cmake --build build-host` | **builds `libcanopyhost_shared.a`** |
| Same C++ retargeted to the Android **arm64-v8a** ABI with the NDK | `cmake … -DANDROID_ABI=arm64-v8a` | builds arm64 `libcanopyhost_shared.a` |
| **C1 round-trip GREEN on a real Android runtime** (the gate): Echo app on an accelerated emulator — tap Ping → `dispatch module=Echo method=send` → worker thread → `postToJs` (main Looper) → `resolve result="ping"` in logcat | `host/android` Gradle app on the KVM emulator (see runbook) | **PROVEN on-device** |

**Run everything:**
```bash
cd native/examples/echo && canopy-native build      # compile + assemble the bundle
cd ../../harness && npm test                          # 53 assertions: render + effect ABI
cd ../host/shared && cmake -S . -B build-host && cmake --build build-host   # C++ vs JSI
```

**What is NOT proven here (needs a device — plan C1 §6):** the C++ thread hop itself, the
iOS `dispatch_async(main)` / Android Looper post on real hardware, and Hermes booting the
bundle on a real device. The mock harness models the hop deterministically; only a device
closes that gap. This is the Path-A go/no-go gate.

---

## Device-build runbook

The host code is **integration templates** — they compile inside a real iOS/Android app
target, not on a bare dev box. To take C1 to first light on a device:

### Android — PROVEN on this Linux box (no Mac, no React Native)

A complete, runnable Gradle app already exists at **`native/host/android/`** and has been
driven to C1 first light on an accelerated emulator. The key decision: a **bare
Hermes + JSI + Yoga host, no React Native**, using version-matched prebuilt `.so` vendored
under `host/android/vendor/` (from the **0.76.9** AARs — pinned because the JSI ABI must match
Hermes exactly):

- `libhermes.so` + `hermes/*.h` ← `com.facebook.react:hermes-android:0.76.9`
- `libjsi.so` + `jsi/*.h` ← `com.facebook.react:react-android:0.76.9` *(`libhermes.so` has
  `DT_NEEDED libjsi.so`; the `jsi::*` symbols are **not** in `libhermes.so`)*
- `libfbjni.so` ← `com.facebook.fbjni:fbjni:0.7.0` *(and its Java AAR must be a dependency, or
  fbjni's `JNI_OnLoad` throws `ClassNotFound: com.facebook.jni.HybridData$Destructor`)*
- Yoga: the `com.facebook.yoga:yoga:3.2.1` AAR (Java bindings + `libyoga.so`).

Steps:
1. Install JDK 17 + Android SDK (cmdline-tools, `platform-tools`, `platforms;android-34`,
   `build-tools;34.0.0`, `cmake;3.22.1`, `emulator`, `system-images;android-34;google_apis;x86_64`)
   + an NDK. (`ndk;26.3.11579264` / r26d works.)
2. `cd native/examples/echo && canopy-native build` → copy `build/canopy.bundle.js` to
   `host/android/app/src/main/assets/`.
3. `cd native/host/android && gradle :app:assembleDebug` → `app-debug.apk` (ABIs
   `arm64-v8a` + `x86_64`; the vendored + Yoga/fbjni `.so` are packaged automatically).
4. Create an AVD + boot it headless+accelerated (this box has `/dev/kvm`):
   `emulator -avd <name> -no-window -gpu swiftshader_indirect -no-snapshot`.
5. `adb install -r app-debug.apk` → launch → tap Ping. The round-trip is visible in logcat:
   `adb logcat -s CanopyABI` → `dispatch module=Echo method=send …` then `resolve result="ping"`.
   That is **C1 green on a real Android runtime** — the gate that unblocks C2–C8.

> Known gap: the direct-views Android host (`CanopyHost.java`) has rough style/layout fidelity
> (the Echo reply label isn't visibly laid out yet) — a **C2** host-rendering concern, not C1.
> The effect round-trip itself is proven (press → dispatch → worker → resolve → update).

Compile-check the portable C++ for arm64 without an app:
```bash
cmake -S host/shared -B build-android \
  -DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-24
cmake --build build-android      # builds libcanopyhost_shared.a for arm64-v8a
```

### iOS (needs a macOS runner)
1. Xcode app target; add `host/shared/cpp/*` + `host/ios/CanopyHost/*`; link Hermes + Yoga.
2. Make `CanopyHostViewController` the root; bundle `canopy.bundle.js` as a resource.
3. Build + run on a device → tap **Ping**. (iOS first light needs the macOS runner; the
   `jsi::Runtime*` wiring is already done in the view controller.)

---

## How a real capability is added (the payoff)

Adding ML inference, billing, a photo picker, etc. is now mechanical:
1. **Canopy side** (~40 lines): a module that calls `Native.Module.call "X" "method" args
   decoder` (one-shot) or `callStreaming` (progress), exactly like `Echo`. A capability that
   needs its own `subscription` graduates to an `effect module` in a `canopy/*` package.
2. **Native side:** a `NativeModule` subclass whose `invoke` does the real work on a worker
   thread and calls `ctx.complete`. It self-registers in host boot — **zero** shared-C++
   edits (a Swift StoreKit / Kotlin Play-Billing module registers the same way).
3. Binary in/out crosses as a `BlobRegistry` handle; JSON metadata travels as strings.

No new JSI globals, no kernel edits, no new marshalling layer — that is the whole point of
the generic dispatcher.
