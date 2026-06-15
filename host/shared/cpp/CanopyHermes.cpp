// CanopyHermes.cpp — the ONE place a Hermes engine symbol is named (RNV-4).
//
// This translation unit is the entire Hermes coupling. Everything else in the host creates its JS
// runtime via canopy::makeRuntime() and sees only jsi::Runtime. See CanopyHermes.h for the why.
//
// Two backends, chosen at COMPILE TIME by -DCANOPY_HERMES_CABI:
//
//   default            → facebook::hermes::makeHermesRuntime()              (RN-bundled .so today)
//   CANOPY_HERMES_CABI → makeHermesABIRuntimeWrapper(get_hermes_abi_vtable())  (stable C-vtable;
//                        needs a standalone Hermes that EXPORTS the vtable — RNV-6)
//
// Only ONE of the two #include sets + bodies is compiled, so a build never references a symbol its
// linked libhermes does not provide. (Picking the C-ABI path against the RN-bundled .so would fail
// to LINK on the missing get_hermes_abi_vtable / makeHermesABIRuntimeWrapper — which is correct:
// the flag is for when RNV-6 vendors an engine that exports them.)

#include "CanopyHermes.h"

#if defined(CANOPY_HERMES_CABI)
// ── Backend (B): the stable C-vtable ABI ─────────────────────────────────────────────────────
// hermes_vtable.h declares get_hermes_abi_vtable() (the C entry point that returns the frozen
// HermesABIVTable), and HermesABIRuntimeWrapper.h declares the jsi::Runtime adapter over it. Both
// are vendored under host/android/vendor/hermes-include/hermes_abi. This path is ABI-durable: a
// Hermes minor bump appends to the vtable but never moves these C symbols.
#include <hermes_abi/HermesABIRuntimeWrapper.h>
#include <hermes_abi/hermes_vtable.h>
#else
// ── Backend (A): the C++ factory (default) ───────────────────────────────────────────────────
// The RN-0.76.9-bundled libhermes.so exports ONLY this symbol (verified by nm -D). It is a C++
// symbol with no stable ABI, which is exactly why RNV-4 wraps it behind canopy::makeRuntime().
#include <hermes/hermes.h>
#endif

namespace canopy {

std::unique_ptr<facebook::jsi::Runtime> makeRuntime() {
#if defined(CANOPY_HERMES_CABI)
  // Wrap the engine's frozen C-vtable into a jsi::Runtime. get_hermes_abi_vtable() returns a
  // pointer to a static, immortal vtable; makeHermesABIRuntimeWrapper owns the runtime it creates.
  return facebook::hermes::makeHermesABIRuntimeWrapper(get_hermes_abi_vtable());
#else
  // Fully qualified for the same reason the old boot sites were: with `using namespace facebook;`
  // in effect at some call sites and the real Hermes headers (which also declare a top-level
  // ::hermes VM namespace), a bare `hermes::` is ambiguous. Here we are in namespace canopy with
  // no `using`, but we keep the fully-qualified form so the coupling is grep-obvious.
  return facebook::hermes::makeHermesRuntime();
#endif
}

HermesBackend makeRuntimeBackend() {
#if defined(CANOPY_HERMES_CABI)
  return HermesBackend::CApiVTableWrapper;
#else
  return HermesBackend::CxxMakeHermesRuntime;
#endif
}

const char* makeRuntimeBackendName() {
#if defined(CANOPY_HERMES_CABI)
  return "Hermes C-ABI vtable (makeHermesABIRuntimeWrapper + get_hermes_abi_vtable) [RNV-4/RNV-6]";
#else
  return "Hermes C++ factory (facebook::hermes::makeHermesRuntime) [RNV-4 default]";
#endif
}

}  // namespace canopy
