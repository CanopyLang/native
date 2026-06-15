// CanopyHermes.h — the ONE Hermes runtime factory (RNV-4).
//
// WHY THIS FILE EXISTS — the durable lever in the RN-coupling story.
// canopy/native's entire coupling to the Hermes engine is "create a jsi::Runtime backed by
// Hermes". Before RNV-4 that was spelled `facebook::hermes::makeHermesRuntime()` DIRECTLY at the
// two boot sites (Android CanopyHostJni.cpp, iOS CanopyHostViewController.mm). makeHermesRuntime
// is a C++ symbol — its name mangles in Hermes' internal C++ types (hermes::vm::RuntimeConfig),
// and Hermes ships NO stable C++ ABI. So every Hermes minor bump could move that symbol and break
// our link, AND the coupling was duplicated across two platforms.
//
// RNV-4 collapses that to a SINGLE seam: `CanopyHermes::makeRuntime()`. Both boot sites call it;
// neither names a Hermes symbol any more. A Hermes engine swap is now a one-file change behind a
// frozen boundary — the rest of the host (and the iOS sibling) is insulated. This is exactly the
// "file swap behind a frozen C boundary" the master plan (RNV-4) calls for.
//
// TWO BACKENDS, SELECTED AT COMPILE TIME — and WHY there are two:
//
//   (A) DEFAULT — the C++ symbol `facebook::hermes::makeHermesRuntime()`.
//       This is what works with the libhermes.so we vendor TODAY (extracted from the
//       react-native 0.76.9 hermes-android AAR). That .so exports ONLY the C++ entry point;
//       VERIFIED empirically: `nm -D host/android/vendor/lib/*/libhermes.so` shows exactly one
//       relevant export, `facebook::hermes::makeHermesRuntime(hermes::vm::RuntimeConfig const&)`,
//       and ZERO C-ABI symbols (no get_hermes_abi_vtable, no makeHermesABIRuntimeWrapper). The
//       RN-bundled Hermes simply is not built with the C-API surface compiled in. So the default
//       MUST stay the C++ path or the host would not link — see scripts/check-hermes-cabi.sh,
//       which probes the vendored .so for the C-ABI export and reports whether the C-ABI path is
//       available yet (it is NOT, with the RN-bundled .so).
//
//   (B) CANOPY_HERMES_CABI — the STABLE C-vtable path:
//       makeHermesABIRuntimeWrapper(get_hermes_abi_vtable()).
//       hermes_abi.h defines a FROZEN C ABI (HermesABIVTable → make_hermes_runtime), and
//       HermesABIRuntimeWrapper.h wraps a vtable into a jsi::Runtime. This is the durable boundary
//       a Hermes minor bump CANNOT break: the vtable is versioned/append-only C, not mangled C++.
//       It requires a libhermes that EXPORTS get_hermes_abi_vtable — i.e. a standalone Hermes
//       release (RNV-6's spike) rather than the AAR-extracted engine. When RNV-6 vendors such an
//       engine, flipping the default is ONE compile flag (-DCANOPY_HERMES_CABI=1) — no boot-site
//       edit, because both sites already go through THIS seam. That is the whole point of landing
//       RNV-4 now: the seam is in place and exercised, so RNV-6 becomes a backend swap, not a
//       cross-cutting refactor.
//
// The header itself is tiny and includes <jsi/jsi.h> only (for the return type). The Hermes/C-ABI
// includes live in CanopyHermes.cpp so the coupling is confined to one translation unit.

#pragma once

#include <jsi/jsi.h>
#include <memory>

namespace canopy {

// Which Hermes backend the factory was compiled against — for boot-time logging / provenance so a
// device log says exactly how the runtime was created. Returned by makeRuntimeBackendName().
enum class HermesBackend {
  CxxMakeHermesRuntime,  // (A) facebook::hermes::makeHermesRuntime() — the RN-bundled .so path
  CApiVTableWrapper,     // (B) makeHermesABIRuntimeWrapper(get_hermes_abi_vtable()) — RNV-6 path
};

// The ONE Hermes runtime factory. Creates a default-configured Hermes-backed jsi::Runtime and
// returns it as the engine-agnostic jsi::Runtime base — the caller (the boot site) never sees a
// Hermes type. Compiled to backend (A) by default, or (B) under -DCANOPY_HERMES_CABI.
//
// Both boot sites (Android CanopyHostJni.cpp, iOS CanopyHostViewController.mm) call THIS instead of
// makeHermesRuntime() directly. A Hermes engine swap changes only CanopyHermes.cpp.
std::unique_ptr<facebook::jsi::Runtime> makeRuntime();

// The backend this build was compiled with (compile-time constant). Lets the boot site log which
// path created the runtime without itself naming a Hermes symbol.
HermesBackend makeRuntimeBackend();

// A short human-readable name for the active backend (for the boot log line). Never throws.
const char* makeRuntimeBackendName();

}  // namespace canopy
