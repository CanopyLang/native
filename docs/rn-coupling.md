# canopy/native — the React-Native coupling contract

**This is the authoritative, grep-pinned list of every place `canopy/native` touches the
React-Native ecosystem.** It is enforced by [`scripts/check-rn-coupling.sh`](../scripts/check-rn-coupling.sh)
(one of the steps in `scripts/ci-test.sh`, the single canonical gate the CI `gate` job runs —
see [`docs/ci.md`](ci.md)), which fails the build if the surface grows outside the allowlist below
or if a forbidden symbol appears.

> **Read this first if you believe the README/architecture/roadmap.** Those docs
> historically said canopy/native "renders through React Native's **Fabric** host." That
> is **false** and has been corrected. canopy/native does **NOT** use RN's Fabric runtime,
> `RCTBridge`, TurboModules, the `MountingManager`, or a `ShadowTree`. The `__fabric_*`
> JSI function names borrow Fabric's *vocabulary* (create/update/insert/remove a view) —
> they are **Canopy's own mount ABI**, not RN's Fabric runtime.

---

## What we actually couple to (the whole list)

| Surface | Symbol(s) | How load-bearing | Where |
|---|---|---|---|
| **JSI** | `jsi::*` (value marshalling) | The JS↔native seam. A small, stable subset only. | `CanopyFabric.cpp`, `CanopyModules.cpp` (+ headers) |
| **Hermes** | `facebook::hermes::makeHermesRuntime()` (default backend) **or** `makeHermesABIRuntimeWrapper(get_hermes_abi_vtable())` (stable C-vtable, RNV-4 `-DCANOPY_HERMES_CABI`) | **Exactly one seam.** Boot the JS engine via `canopy::makeRuntime()`. Both boot sites route through this ONE factory; a Hermes engine swap is a one-file change. | `CanopyHermes.cpp` (the factory); called from `CanopyHostJni.cpp` (Android) + `CanopyHostViewController.mm` (iOS) |
| **Yoga** | `YG*` / `<yoga/Yoga.h>` | Flexbox layout, **iOS host only**. | `CanopyHostFabric.mm` |
| **plain JNI** | `<jni.h>`, `JNIEnv`, `JNIEXPORT`, … | Android JS↔Java boundary. | `CanopyHostJni.cpp:11` |

### What we do NOT couple to — and the guard proves it (zero matches)

`RCTBridge` · `TurboModule` · `RCTSurface` · **`MountingManager`** · **`ShadowTree`** ·
`RCTComponentViewProtocol` · **`facebook::jni` / `fbjni`** · `HybridClass` · `registerNatives`.

Two specific corrections to earlier claims:

1. **There is NO fbjni.** Plans referred to an "fbjni subset" — that is wrong. A grep of
   the non-vendor tree finds **zero** `facebook::jni` / `fbjni` / `HybridClass` /
   `registerNatives`. Android uses **plain JNI (`jni.h`)** only: `JNIEnv*`,
   `JNIEXPORT`/`JNICALL`, `FindClass`, `GetStaticMethodID`, `CallStaticVoidMethod`, etc.
2. **There is NO RN Fabric.** `host/ios/.../Render/CanopyHostFabric.mm` is *named* "Fabric"
   but drives **Yoga directly against `UIView`** — see its own header comment. It does not
   instantiate `RCTSurface`, a `MountingManager`, or a `ShadowTree`.

---

## The JS-visible host ABI (the entire bridge)

The walker (`package/external/native.js`) calls exactly these global functions, installed
from C++ over JSI. **This is the complete JS↔native contract.**

**Mount ABI — 8 `__fabric_*` host functions** (installed in `CanopyFabric.cpp`):

| Function | Site | Purpose |
|---|---|---|
| `__fabric_createView(tag, props) -> handle` | `CanopyFabric.cpp:48` | create a native view |
| `__fabric_updateProps(handle, props)` | `CanopyFabric.cpp:56` | targeted prop update (the §8 fast-path) |
| `__fabric_insertChild(parent, child, index)` | `CanopyFabric.cpp:63` | mount a child |
| `__fabric_removeChild(parent, child, index)` | `CanopyFabric.cpp:70` | unmount a child |
| `__fabric_setRoot(handle)` | `CanopyFabric.cpp:77` | designate the root view |
| `__fabric_setEvents(handle, [names])` | `CanopyFabric.cpp:84` | register which gestures to emit |
| `__fabric_command(handle, name, argsJson)` | `CanopyFabric.cpp:96` | imperative-op seam (async; result via `canopyEmitEvent`) |
| `__fabric_requestFrame(cb)` | `CanopyFabric.cpp:105` | schedule a frame (animation) |

**Control / module ABI — 6 `__canopy_*` globals** (some installed from C++, some looked
up *on* the JS global by C++):

| Global | Direction | Site |
|---|---|---|
| `__canopy_boot(rootTag, flags)` | C++ → JS (looked up & called) | `CanopyFabric.cpp:127` |
| `__canopy_dispatchEvent(handle, name, payloadJson)` | C++ → JS (gesture in) | `CanopyFabric.cpp:117` |
| `__canopy_call(module, method, argsJson, callId)` | JS → C++ (native-module call) | `CanopyModules.cpp:95` |
| `__canopy_cancel(callId)` | JS → C++ (cancel a call) | `CanopyModules.cpp:103` |
| `__canopy_resolve(callId, …)` | C++ → JS (module result) | `CanopyModules.cpp:114` |
| `__canopy_symbolicate(stack)` | C++ → JS (source-map a JS stack) | `CanopyHostJni.cpp:79` |

That is the **entire** surface: 8 + 6 globals. No other RN API is on the JS↔native path.

---

## The JSI primitive subset we use

Both `CanopyFabric.cpp` and `CanopyModules.cpp` do `using namespace facebook::jsi;`
(`CanopyFabric.cpp:13`, `CanopyModules.cpp:16`) and use a deliberately small slice of JSI:

`Runtime&` (param) · `Value` / `Value::undefined` / `Value::null` · `Function::createFromHostFunction`
(`CanopyFabric.cpp:40`, `CanopyModules.cpp:25`) · `PropNameID::forAscii` · `rt.global()` /
`getProperty` / `setProperty` · `getPropertyAsObject` / `getPropertyAsFunction` · `.call(...)` ·
`String::createFromUtf8` · `.getString(rt).utf8(rt)` · `getObject` / `getFunction` ·
`getNumber` / `isNumber` / `isString` / `isObject` / `isFunction` / `isUndefined` / `isNull` ·
`StringBuffer` (boot/eval) · `JSError`. Nothing more.

---

## The allowlist (must stay in sync with `check-rn-coupling.sh`)

Every file below references a coupling symbol (`jsi::` / `facebook::hermes::` / `YG*` /
`yoga/Yoga.h` / `makeHermesRuntime` / `makeHermesABIRuntimeWrapper` / `get_hermes_abi_vtable` /
`hermes_abi/` / `<hermes/hermes.h>`). The guard fails if a coupling symbol appears in **any file
not on this list**, and the parity check (step [3/3] of the guard) fails if any file here is **not
also named in this table**.

> **If you add a file here, you MUST update BOTH the `ALLOWLIST` array in
> `scripts/check-rn-coupling.sh` AND this table.** The guard enforces the parity.

| File (relative to `host/`) | What couples | Notes |
|---|---|---|
| `shared/cpp/CanopyHermes.cpp` | **Hermes (the whole engine seam)** | RNV-4. The ONE place a Hermes engine symbol is named: `facebook::hermes::makeHermesRuntime()` by default, or `makeHermesABIRuntimeWrapper(get_hermes_abi_vtable())` under `-DCANOPY_HERMES_CABI`. Both boot sites call `canopy::makeRuntime()`. |
| `shared/cpp/CanopyHermes.h` | JSI | `#include <jsi/jsi.h>`; declares `canopy::makeRuntime()` returning a `unique_ptr<jsi::Runtime>`. |
| `shared/cpp/CanopyFabric.cpp` | JSI | The only `jsi::Value` marshalling point; installs the 7 `__fabric_*` fns. |
| `shared/cpp/CanopyFabric.h` | JSI | `#include <jsi/jsi.h>`; declares `installCanopyFabric`. |
| `shared/cpp/CanopyModules.cpp` | JSI | Installs `__canopy_call`/`_cancel`; `canopyResolveCall`. |
| `shared/cpp/CanopyModules.h` | JSI | `#include <jsi/jsi.h>`; `ModuleRegistry` holds a `jsi::Runtime*`. |
| `shared/cpp/CanopyImage.h` | (comment) | Only *names* `jsi::Runtime` in a "nothing touches it" comment. |
| `shared/cpp/CanopyJni.h` | (comment) | Only *names* `jsi::Runtime` in a "NEVER touches it" comment. |
| `shared/cpp/EchoModule.h` | (comment) | Only *names* `jsi::Runtime` in a "NEVER touches it" comment. |
| `shared/cpp/RestoreEngineModule.h` | (comment) | Only *names* `jsi::Runtime` in a contract comment. |
| `android/app/src/main/jni/CanopyHostJni.cpp` | Hermes + plain JNI | RNV-4: boots via `canopy::makeRuntime()` (no longer names `makeHermesRuntime`); still includes `<hermes/hermes.h>` for the RNV-2 `HermesRuntime::getBytecodeVersion()` ABI-gate read. `<jni.h>` (`:11`); `__canopy_symbolicate` lookup. |
| `ios/CanopyHostCore/Boot/CanopyHostViewController.h` | JSI | Owns the held Hermes `jsi::Runtime` (declared in `.mm`). |
| `ios/CanopyHostCore/Boot/CanopyHostViewController.mm` | Hermes (ABI-gate read) + JSI | RNV-4: boots via `canopy::makeRuntime()` (no longer names `makeHermesRuntime`); IOS-4/RNV-2: includes `<hermes/hermes.h>` for the `HermesRuntime::getBytecodeVersion()` boot-time ABI-canary read (the iOS twin of `CanopyHostJni.cpp`). Holds the returned `jsi::Runtime`; `evaluateJavaScript`/`StringBuffer`; `JSError`. |
| `ios/CanopyHostCore/Boot/CanopyModuleHost.h` | JSI | Holds/forwards `jsi::Runtime*`. |
| `ios/CanopyHostCore/Boot/CanopyModuleHost.mm` | JSI | Installs the console polyfill via `Function::createFromHostFunction`. |
| `ios/CanopyHostCore/Bridge/CanopyModule.h` | JSI | Forward-declares / names `jsi::Runtime`. |
| `ios/CanopyHostCore/Bridge/CanopyNativeModule.h` | JSI | Forward-declares / names `jsi::Runtime`. |
| `ios/CanopyHostCore/CanopyHostCore-Bridging-Header.h` | JSI | Bridging header pulling in the JSI-touching ObjC++ surface. |
| `ios/CanopyHostCore/Modules/CanopyModuleSupport.mm` | (comment) | Only *names* `jsi::Runtime` in a "touches no jsi::Runtime" comment. |
| `ios/CanopyHostCore/Render/CanopyHostFabric.h` | Yoga (decl) | The render host header; documents it holds **no** `jsi::Runtime*`. |
| `ios/CanopyHostCore/Render/CanopyHostFabric.mm` | **Yoga** | `#import <yoga/Yoga.h>` (`:36`); `YGNodeNew`/`YGNodeCalculateLayout`/`YGNodeInsertChild`/`YGNodeSetMeasureFunc`/… Drives Yoga **directly**, not RN Fabric. |
| `ios/Tests/CanopyHostCoreTests/CanopyEngineTests.mm` | JSI | Engine test exercising the JSI seam. |

**Excluded from the search** (third-party, not our coupling): `host/*/vendor/` and
`host/shared/third_party/` — the vendored Hermes/JSI/Yoga headers. They contain hundreds
of `jsi::`/`YG*` symbols by definition; they are not *our* surface and the guard skips them.

---

## How the guard works (and how to run it)

```sh
bash scripts/check-rn-coupling.sh      # standalone; exit 0 = green
bash scripts/ci-test.sh                # the full canonical gate (this guard is one of its steps)
```

Three checks, all pure grep (no SDK / no device / no compiler):

1. **Forbidden symbols** — `RCTBridge | TurboModule | facebook::jni | fbjni | RCTSurface |
   MountingManager | ShadowTree | …` must match **zero** files. A hit means someone pulled
   in the heavy RN runtime we deliberately avoid.
2. **Coupling confinement** — the set of files containing `jsi::`/`hermes::`/`YG*`/Yoga
   minus the allowlist must be **empty** (no new coupling site), and no allowlist entry may
   go **stale** (a listed file that no longer couples — keeps the doc honest).
3. **Doc/guard parity** — every file in the script's `ALLOWLIST` array must also appear in
   the table above, so the script and this doc cannot silently drift.
