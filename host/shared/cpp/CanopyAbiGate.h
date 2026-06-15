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

#include <cstddef>
#include <cstdint>
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

// ── The .hbc LOAD gate (RNV-7) ───────────────────────────────────────────────────────────────
// RNV-7 ships a real Hermes bytecode bundle (canopy.bundle.hbc, emitted by hermesc in the build
// tool). The bytecode version stamped in that file's header is THE gated contract: the engine can
// only execute HBC whose version equals HermesRuntime::getBytecodeVersion(). RNV-2 already proves
// that live engine value equals kCanopyExpectedHermesBytecodeVersion (the boot-time checkHermesAbi
// + CI's check-abi.sh). So if the .hbc we are about to evaluate carries a DIFFERENT version, the
// engine would reject it (or, on a corrupt header, mis-execute it). We catch that BEFORE handing it
// to Hermes — the same fail-LOUD posture as the engine gate — so a stale/wrong-toolchain bundle is
// a readable boot error, not a Hermes-internal abort.
//
// The Hermes File Format header is fixed-layout: an 8-byte magic followed by a little-endian
// uint32 bytecode version (see hermes/BCGen/HBC/BytecodeFileFormat.h). We read those bytes here
// WITHOUT depending on any Hermes symbol (so this header stays off the RN-coupling allowlist and
// is unit-testable with crafted bytes). The build tool (Bundle.hs) reads the SAME offset to stamp
// the version into canopy.manifest.json — one wire format, three readers (build tool, this gate,
// the engine), so they can never silently disagree.

// The 64-bit magic that opens every Hermes bytecode file, little-endian on disk (the bytes
// 0xC6 0x1F 0xBC 0x03 0xC1 0x03 0x19 0x1F). Used to recognize HBC vs. plain JS source.
constexpr uint64_t kCanopyHermesBytecodeMagic = 0x1F1903C103BC1FC6ULL;

// True iff `data`/`len` begins with the Hermes bytecode magic — i.e. it is an .hbc file, not JS
// source. Mirrors HermesRuntime::isHermesBytecode without linking it (so the gate is pure).
inline bool looksLikeHermesBytecode(const uint8_t* data, size_t len) {
  if (data == nullptr || len < 8) return false;
  uint64_t magic = 0;
  for (int i = 0; i < 8; ++i) {
    magic |= static_cast<uint64_t>(data[i]) << (8 * i);
  }
  return magic == kCanopyHermesBytecodeMagic;
}

// Extract the bytecode version stamped in an .hbc header (the LE uint32 at offset 8). Returns -1
// if the buffer is too short or does not carry the Hermes magic (i.e. it is not HBC at all).
inline int hermesBytecodeFileVersion(const uint8_t* data, size_t len) {
  if (!looksLikeHermesBytecode(data, len) || len < 12) return -1;
  return static_cast<int>(static_cast<uint32_t>(data[8]) |
                          (static_cast<uint32_t>(data[9]) << 8) |
                          (static_cast<uint32_t>(data[10]) << 16) |
                          (static_cast<uint32_t>(data[11]) << 24));
}

// Gate an about-to-be-evaluated bundle buffer (RNV-7). For PLAIN JS source (no HBC magic) this is
// always ok — the dev path keeps shipping JS, and the engine parses it as before. For an .hbc
// buffer, the stamped version MUST equal kCanopyExpectedHermesBytecodeVersion (== the live engine
// version, by RNV-2); a mismatch means a bundle built by a hermesc whose HBC format differs from
// the vendored engine — it must not be handed to Hermes. Pure + total; the caller decides the
// consequence (red-box / fatal log) exactly like checkHermesAbi.
inline AbiCheckResult checkBundleBytecode(const uint8_t* data, size_t len) {
  AbiCheckResult r;
  if (!looksLikeHermesBytecode(data, len)) {
    r.ok = true;
    r.message = "bundle is plain JS source (no HBC magic) — the engine will parse it as before";
    return r;
  }
  int fileVersion = hermesBytecodeFileVersion(data, len);
  if (fileVersion == kCanopyExpectedHermesBytecodeVersion) {
    r.ok = true;
    r.message = "Hermes .hbc OK: bundle bytecode version " + std::to_string(fileVersion) +
                " matches the vendored engine pin (react-native " + kCanopyExpectedRnVersion + ")";
    return r;
  }
  r.ok = false;
  r.message =
      "HERMES .HBC VERSION MISMATCH — canopy.bundle.hbc carries bytecode version " +
      std::to_string(fileVersion) + " but the vendored engine speaks version " +
      std::to_string(kCanopyExpectedHermesBytecodeVersion) + " (react-native " +
      kCanopyExpectedRnVersion +
      "). The bundle was compiled by a hermesc whose HBC format differs from the engine the host "
      "links — the engine would reject it. Rebuild the bundle with the matching hermesc (see "
      "tool/src/Canopy/Native/Bundle.hs) or revendor in lockstep.";
  return r;
}

}  // namespace canopy
