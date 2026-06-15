# The Canopy Native Extension ABI (frozen, versioned)

> **Status:** `CANOPY_ABI_VERSION = 1` — Phase 4, Escape-hatch M0.
> Source of truth: [`host/shared/cpp/CanopyAbi.h`](../host/shared/cpp/CanopyAbi.h).

Third-party native components and modules bind against **this surface and nothing else**. It is
deliberately narrow and versioned so the host's internal renderer can evolve without breaking the
ecosystem. Everything else in the host (the `makeView` switch, the Yoga plumbing, the diff
internals) is private and may change between releases.

## Why a frozen ABI

A library author shipping a native view (`BlurView`) or module (`Battery`) must be able to build
once and have it keep working across host releases. The ABI is the contract that makes that safe.
It is also what an over-the-air bundle's `runtimeVersion` (in `canopy.manifest.json`, OTA M0)
gates against: **a bundle built for ABI _N_ must not boot on a host that speaks ABI ≠ _N_**, or the
walker would call render/effect functions the host doesn't implement.

## The frozen JS surface

All names live on the host global (`globalThis`). The walker (`package/external/native.js`) is the
only first-party consumer; third-party render/effect code goes through the higher-level `.can`
APIs, never these directly.

### Render seam — the host implements, the walker calls
| Function | Returns | Meaning |
|---|---|---|
| `__fabric_createView(tag, propsJson)` | `handle` (int) | Mint a native view for `tag` with initial props. |
| `__fabric_updateProps(handle, propsJson)` | — | Apply a (possibly partial, null-encoded) prop diff. |
| `__fabric_insertChild(parent, child, index)` | — | Insert `child` under `parent` at `index`. |
| `__fabric_removeChild(parent, child, index)` | — | Remove `child` from `parent`. |
| `__fabric_setRoot(handle)` | — | Designate the root surface view. |
| `__fabric_setEvents(handle, namesJson)` | — | Declare which events `handle` wants (idempotent). |
| `__fabric_requestFrame(callback)` | — | Run `callback` on the next vsync (drives animation). |

### Effect ABI — the host implements, the walker calls
| Function | Returns | Meaning |
|---|---|---|
| `__canopy_call(module, method, argsJson, callId)` | int | Dispatch a native-module call; `-1` = ModuleNotFound. |
| `__canopy_cancel(callId)` | — | Cancel an in-flight call / live subscription. |

### Effect ABI — the walker installs, the host calls
| Function | Meaning |
|---|---|
| `__canopy_boot(rootTag, flagsJson)` | Start the program against the root surface. |
| `__canopy_resolve(callId, errJson, resultJson)` | Resolve/reject/stream-event a call (`errJson==""` ⇒ success). |
| `__canopy_dispatchEvent(handle, name, payloadJson)` | Deliver a view event into the program. |

### Stamp — the walker installs
| Global | Meaning |
|---|---|
| `__canopy_abi_version` | The integer ABI the bundle was built for (`== CANOPY_ABI_VERSION`). |

> The dev-only `__canopy_sourcemap` / `__canopy_symbolicate` (red-box symbolication) are **not**
> part of the frozen contract and may change or be absent (e.g. in release bundles).

## The frozen C++ surface

`CanopyAbi.h` re-exports the two stable native contracts a native library implements:

- **`canopy::NativeModule`** (from `CanopyModules.h`) — a native module: `name()`, `invoke(CallContext&)`,
  `cancel(callId)`. `complete(errJson, resultJson)` may be called from any thread; the registry
  re-marshals onto the JS thread. This contract is unchanged from C1 and already general.
- **`canopy::CanopyViewFactory`** — a native **component**: `tag()`, `create(handle)`,
  `applyProps(view, propsJson)`, `reset(view, key)` (**mandatory** — clears a dropped prop so a
  recycled view doesn't leak prior state), and an optional `isLeaf()` for custom-measured leaves.
  The host's `makeView` default-case consults a registry of factories before falling back to a
  plain container; built-in tags keep the fast in-switch path.

`CanopyViewRef` is an opaque platform view (Android `jobject` View; iOS `UIView*`); the factory
casts it, the host core never inspects it.

## The survival rule (semantic versioning of the ABI)

- **Minor (backward compatible):** adding a new function, or an optional **trailing** argument to an
  existing one. Old bundles keep working; do **not** bump `CANOPY_ABI_VERSION`.
- **Major (breaking):** removing a function, renaming it, or changing an argument's type/position.
  **Bump `CANOPY_ABI_VERSION`**, move every host (Android + iOS) in lockstep, and bump the bundles'
  `runtimeVersion` so a mismatched pair refuses to boot instead of crashing.

Keep the surface small. Every symbol here is a promise.

## Roadmap (the seams this contract unlocks)

This M0 only **freezes + publishes** the contract. The seams that consume it land next:
`CanopyViewRegistry` + `CanopyHost.registerComponent` (M1), `Native.hostComponent` + the real
`__2_CUSTOM` walker path (M2), app-provided module registration with no boot edits (M3), the
`canopy-native-sdk` package + `gen-library` scaffolder (M4), and a worked out-of-tree sample built
with **zero host edits** plus a CI guard that fails on an ABI break (M5).
