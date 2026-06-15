// CanopyAbiGate.h — the boot-time Hermes/JSI ABI gate (RNV-2).
//
// THE FOOTGUN this closes: the host links a PREBUILT libhermes.so (vendored under
// host/android/vendor, pinned by host/vendor.lock.json — RNV-1). Hermes has NO stable C++
// ABI. If the libhermes a build links ever drifts from the JSI headers it was compiled
// against — a partial revendor, a stale .so on a CI cache, a hand-swapped binary — the host
// still COMPILES and BOOTS on the dev emulator, then SIGABRTs on a user's arm64 device the
// first time a non-trivial JSI Value crosses the seam (risk R1 in the master plan). There is
// no louder symptom until it is in a user's hands.
//
// THE GATE: Hermes exposes the one ABI number that the runtime computes itself —
// HermesRuntime::getBytecodeVersion(), the HBC format version the LINKED engine speaks. We
// bake the value expected for the vendored pin (kCanopyExpectedHermesBytecodeVersion, derived
// from host/vendor.lock.json's pinned react-native version — see check-abi.sh, which RE-derives
// it straight from the pinned libhermes.so bytes and fails CI on any drift from this header).
// At boot the host reads the LIVE value off the runtime it just created and compares; a
// mismatch is reported LOUD — red-box in debug, fatal log in release — never silent.
//
// This header is deliberately TINY and dependency-free: it references NO JSI or Hermes symbol at
// all (so it stays off the RN-coupling allowlist, scripts/check-rn-coupling.sh) and pulls in no
// platform header. The boot site (Android: CanopyHostJni.cpp; iOS: CanopyHostViewController.mm
// may adopt the same call) reads the two LIVE values from the runtime and passes them in, then
// routes the verdict to its own error sink. Pure comparison, unit-testable without a runtime.
//
// WHY bytecode version is THE check (vs a JSI struct-version): JSI in react-native 0.76.9 ships
// no numeric ABI macro, and the bytecode version is exactly the contract a future real-.hbc
// bundle (RNV-7) is gated on — so gating it now is forward-compatible: the same number a bundle
// will carry in its manifest is the number the engine must speak. The VM description string
// (the JSI Runtime description(), e.g. "HermesRuntime") rides along as diagnostic provenance.

#pragma once

#include <string>

namespace canopy {

// ── The baked pin (derived from host/vendor.lock.json) ──────────────────────────────────────
// vendor.lock.json pins react-native 0.76.9 (the hermes-engine pod-pin + the hermes-include /
// libhermes.so tree). react-native 0.76.9's Hermes speaks HBC bytecode version 96 — VERIFIED by
// disassembling the pinned libhermes.so (getBytecodeVersion() is a `mov eax, 0x60; ret` leaf on
// x86_64 and a `movz w0, #0x60; ret` leaf on arm64-v8a; 0x60 == 96, identical on both ABIs).
// scripts/check-abi.sh re-extracts this number from the pinned .so on every CI run and fails if
// it ever diverges from THIS constant — so the pin can never silently rot.
//
// On an ABI bump (RNV upgrade): revendor a new libhermes, run `scripts/check-abi.sh` to read the
// new number, and move kCanopyExpectedRnVersion + kCanopyExpectedHermesBytecodeVersion here in
// lockstep. check-abi.sh also asserts kCanopyExpectedRnVersion equals vendor.lock.json's pin.
constexpr int kCanopyExpectedHermesBytecodeVersion = 96;
constexpr const char* kCanopyExpectedRnVersion = "0.76.9";

// The verdict of an ABI check: ok + a human-readable message (always populated, for the log).
struct AbiCheckResult {
  bool ok = false;
  std::string message;  // a one-line reason — on mismatch, what was expected vs. seen.
};

// Compare the LIVE Hermes ABI (read off the runtime the host just created) against the baked
// pin. `liveBytecodeVersion` is HermesRuntime::getBytecodeVersion(); `vmDescription` is the JSI
// Runtime description() (diagnostic only — provenance in the message, never gated on, so a
// harmless RN rename of the description string can't false-fail a boot).
//
// Pure + total: no platform calls, no allocation beyond the message string. The caller decides
// the consequence (red-box / fatal). Unit-testable by passing crafted values.
inline AbiCheckResult checkHermesAbi(int liveBytecodeVersion, const std::string& vmDescription) {
  AbiCheckResult r;
  if (liveBytecodeVersion == kCanopyExpectedHermesBytecodeVersion) {
    r.ok = true;
    r.message = "Hermes ABI OK: bytecode version " + std::to_string(liveBytecodeVersion) +
                " matches the vendored pin (react-native " + kCanopyExpectedRnVersion +
                "); VM=" + vmDescription;
    return r;
  }
  r.ok = false;
  r.message =
      "HERMES/JSI ABI MISMATCH — the linked libhermes speaks HBC bytecode version " +
      std::to_string(liveBytecodeVersion) + " but the host was built+vendored against version " +
      std::to_string(kCanopyExpectedHermesBytecodeVersion) + " (react-native " +
      kCanopyExpectedRnVersion +
      "). The vendored libhermes.so does NOT match its pinned JSI headers — a partial revendor or "
      "a swapped binary. This would boot here and then corrupt/SIGABRT on a real device. Re-run "
      "scripts/revendor.sh and rebuild against host/vendor.lock.json. VM=" +
      vmDescription;
  return r;
}

}  // namespace canopy
