# canopy/native — The Reliability Guarantee (precise scope, with the asterisks first)

canopy/native's headline is **correctness-by-construction**. This document states *exactly* what
that does and does **not** guarantee, and cites the live file that enforces each claim. It is the
spec every reliability claim in this repo is measured against.

**Read the asterisks first.** "No errors" is a precise engineering claim about a specific class of
bug, not a promise that an app can never crash. Anyone who reproduces a crash after reading an
unqualified "cannot crash" is right to lose trust — so we never write that. The honest one-liner is:

> **In *Canopy* code you cannot hit `null`/`undefined`, an unhandled `case`, or
> "undefined is not a function"; effects only happen through the managed `Cmd`/`Sub` runtime; and a
> JavaScript-level error becomes a recoverable red-box, not a process abort. Five things are still
> outside that fence — read §2.**

---

## 1. What IS guaranteed (and what enforces it)

Each guarantee is enforced by the type system of the pinned Canopy compiler, by the compiled output,
or by the host runtime guard. The file cited is the live enforcement point (CI fails if a cited file
is deleted — see §4).

| Guarantee | Why it holds | Enforced / proven by |
|---|---|---|
| **No `null` / `undefined` in Canopy values.** There is no `null` in the language; absence is `Maybe`. | Type system — there is no `null` literal and no implicit nullability. | The pinned compiler (`scripts/compiler-pin.env`) + the typed API surface (`package/src/Native.can`). |
| **No unhandled `case` / non-exhaustive match.** Every `case` covers every variant or fails to compile. | Compiler exhaustiveness check. | `scripts/compiler-pin.env` (the pinned compiler enforces it at build time). |
| **No `"undefined is not a function"` / no free identifiers in the shipped bundle.** | The IIFE tree-shaker keeps every reachable runtime/kernel identifier; the build gate evaluates + boots the real bundle and fails on any `ReferenceError`. | `scripts/verify-iife-no-f7.js`, driven by `scripts/build-app-bundle.sh` (the F7 acceptance gate, also run in CI via `scripts/build-compiler-from-pin.sh`). |
| **Effects only via the managed runtime.** I/O, time, randomness, native capabilities happen only through `Cmd`/`Sub` handed to the runtime — never as hidden side effects inside `view`/`update`. | The Elm-architecture runtime + the typed effect surface (the TEA scheduler ships in the sibling `canopy/core` package). | `package/src/Native.can` (the typed effect surface). |
| **A draw error is caught, not propagated.** If rendering a frame throws, the walker catches it instead of tearing down the process. | `_Native_safeDraw` wraps every draw. | `package/external/native.js` (`_Native_safeDraw`, ~line 1126). |
| **A JavaScript-level error at the JS↔host boundary becomes a red-box, not a `SIGABRT`.** A thrown `jsi::JSError` (or a C++ `std::exception` crossing the boundary) is reported to a plain-views overlay; the app survives where the fault is recoverable. | `guardJsCall` wraps every re-entry (boot, event, callback, uiBatch, reload). | `host/android/app/src/main/jni/CanopyHostJni.cpp` (`guardJsCall`) → `host/android/app/src/main/java/com/canopyhost/CanopyRedBox.java`; iOS twin in `host/ios/CanopyHostCore/Boot/CanopyHostViewController.mm`. |
| **A failed hot-reload does not strand the app.** A new bundle that throws on eval/boot/first-render keeps the prior good tree up and recovers last-known-good state. | The DEV-11 recovery seam. | `package/external/native.js` (`__canopy_recoverLastGood` / `__canopy_hasLastGood`), proven by `harness/run-reload-recovery.js`. |
| **The reconciler never crashes / never corrupts the tree.** Keyed reconciliation + LIS reorder hold across fuzzed depth/breadth/reorder. | A seeded-PRNG 6-invariant fuzzer is a hard per-commit gate. | `harness/run-stress.js` (CI gate, `scripts/ci-test.sh`). |
| **A release build cannot load an unsigned / tampered bundle.** The dev `/data/local/tmp` override is `BuildConfig.DEBUG`-gated and integrity fails closed in release. | The release-load safety gate. | `scripts/check-release-bundle-security.sh` (CI gate). |
| **A Hermes/JSI ABI mismatch is a loud, detected error — never silent corruption.** | Boot-time bytecode-version canary + a headless CI assert against the vendor lock. | `scripts/check-abi.sh` + `host/vendor.lock.json`. |

These are continuously proven device-free in `scripts/ci-test.sh` (the canonical gate) and, on iOS,
by the green `ios-build` XCTest/XCUITest job.

---

## 2. What is NOT guaranteed — the five asterisks

These are the ways an app *can* still fail. Each is a deliberate, documented boundary of the
guarantee, not an oversight. Marketing/README/A2UI surfaces must carry these caveats whenever they
make a reliability claim.

1. **Stack overflow from unbounded recursion.** Canopy does not prove termination. A non-terminating
   recursive `update`/`view` (or a pathologically deep data structure) can exhaust the JS stack. Where
   it throws across the host boundary it is caught by `guardJsCall` and surfaces as a red-box; a raw
   native stack exhaustion is covered by the host-crash floor (REL-2, in progress).

2. **Hermes out-of-memory.** Allocating beyond the device's memory budget is a runtime condition the
   type system cannot prevent. It is not converted to a graceful result today.

3. **The ports / FFI boundary.** Code reached through a package's `external/*.js` FFI file or a native
   capability module runs *outside* Canopy's type guarantees. A malformed payload crossing a port, or
   a bug inside hand-written native capability code, is the app author's edge — not the framework's
   guarantee. (Capabilities are sandboxed behind the typed `Cmd`/`Sub` contract, but their *bodies*
   are conventional code.)

4. **`==` on values that contain functions.** Structural equality is undefined for functions; comparing
   values that close over functions can throw at runtime (the Elm-lineage caveat). Avoid `==` on records
   holding closures.

5. **Host-side C++ / Yoga / NDK faults (raw signals).** `guardJsCall` catches C++ *exceptions*, and
   **REL-2's crash floor now also catches an UNCAUGHT JVM `Throwable` (Android) / `NSException` (iOS)
   that escapes a thread with no guard on its stack** — it writes a `buildId`-keyed crash record and
   then **chains** the prior handler (so the OS tombstone/kill and any crash-reporter still run; it
   never swallows). What remains below that floor is a **hard POSIX/Mach signal** — `SIGSEGV`/`SIGABRT`/
   `SIGBUS` inside Yoga, the JSI marshalling layer, or a capability `.so` — which still terminates the
   process (producing a correct OS crash report). An in-process **native signal floor** for those
   (`SIGSEGV/SIGABRT/SIGBUS/SIGILL/SIGFPE`) is now **implemented** (`host/shared/cpp/CanopySignalFloor.cpp`):
   it writes the same `buildId`-keyed breadcrumb async-signal-safely (a record FULLY pre-formatted at
   install, written from a pre-opened fd, on an alternate stack) and then **chains** the prior
   disposition — proven device-free by `host/shared/cpp/tools/signalfloor-test.cpp` (records + chains for
   all five hard signals; the process still dies from the signal). It ships **OFF BY DEFAULT** behind the
   `CANOPY_SIGNAL_FLOOR` opt-in: in an async-signal context a buggy handler is strictly worse than none,
   and the on-device safety can only be confirmed on real hardware, so until then the honest *default*
   posture for hard signals remains the OS crash report — the in-process floor is available + verified
   for the device-validation lane. Wiring + the opt-in are gated device-free by
   `scripts/check-crash-floor.sh [SIG]`; tracked under **REL-2**. This is the one place a "no errors"
   claim is not fully backed below the JS boundary *by default*.

---

## 3. What we measure (so the claim is proven, not asserted)

A guarantee is only credible if it is measured on real apps:

- **Crash-free-session metric** (REL-4): computed from a *real* denominator — sessions from a shipped
  store build on physical devices — per platform and per `buildId`, published with its explicit
  session count, and CI-gated against a committed floor. Pre-shipping numbers are labeled
  *emulator-only* and are not the headline number.
- **Reconciler / runtime fuzz corpus** (REL-5): a persisted regression corpus, not ephemeral seeds.
- **Cross-platform parity gates**: single-sourced test-vector corpora asserted by both hosts, each
  value reproduced by an independent on-Linux oracle, so iOS/Android drift is a red build.

---

## 4. This document is itself CI-enforced

`scripts/check-guarantee-doc.sh` (a step in `scripts/ci-test.sh`) fails the build if:
- any file path this document cites no longer exists (a guarantee can never point at a deleted gate), or
- any of the five asterisks (§2) is missing.

So the guarantee can neither cite a dead enforcement point nor silently drop a caveat.
