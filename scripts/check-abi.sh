#!/usr/bin/env bash
# check-abi.sh — the HEADLESS Hermes/JSI ABI gate for canopy/native (RNV-2).
#
# The boot-time gate (host/shared/cpp/CanopyAbiGate.h + CanopyHostJni.cpp) compares the LIVE
# Hermes bytecode version off the runtime against a value baked from host/vendor.lock.json.
# This script is its CI counterpart: it proves — on a Linux runner, no device, no emulator,
# no Android NDK, no in-house toolchain — that the baked pin actually matches the vendored
# binaries, and that the gate is wired into the boot path. It is the loud, early signal the
# master plan calls for: "getBytecodeVersion() ≠ the locked value" caught before a device ever
# SIGABRTs (risk R1).
#
# WHAT IT ASSERTS:
#   (1) The Hermes bytecode version RE-EXTRACTED from each pinned libhermes.so (by disassembling
#       the getBytecodeVersion() leaf straight out of the .text section) is IDENTICAL across
#       arm64-v8a and x86_64 — the two ABIs the host ships must speak the same HBC version.
#   (2) That re-extracted number EQUALS kCanopyExpectedHermesBytecodeVersion baked into
#       host/shared/cpp/CanopyAbiGate.h. (If a revendor swapped in a different Hermes, this is
#       where the C++ pin is forced to move in lockstep — the gate can't silently rot.)
#   (3) kCanopyExpectedRnVersion baked into CanopyAbiGate.h EQUALS the react-native version
#       pinned in host/vendor.lock.json (the hermes-engine pod-pin). The baked pin is therefore
#       provably "baked from vendor.lock.json", not a free-floating magic string.
#   (4) The Android boot site (CanopyHostJni.cpp) actually CALLS the engine gate — so the runtime
#       check can't be quietly deleted while this CI step stays green.
#   (5) IOS-4: the iOS boot site (CanopyHostViewController.mm) ALSO calls the SAME engine canary
#       (reads getBytecodeVersion() + runs checkHermesAbi before evaluating any JS). The boot-time
#       Hermes ABI gate is now enforced on BOTH platforms, not just Android — a mismatched
#       Hermes.xcframework/libhermes cannot silently corrupt at runtime on either.
#   (6) RNV-7: both boot sites ALSO gate the about-to-be-evaluated .hbc bundle's stamped bytecode
#       version against the same pin (canopy::checkBundleBytecode) BEFORE handing it to Hermes — so
#       a bundle compiled by a mismatched hermesc is refused loudly, not fed to the engine.
#
# It reads the libhermes.so that vendor.lock.json (RNV-1) already checksums, so the chain is:
#   vendor.lock.json sha256  ⟶ revendor.sh verify (the .so on disk is the pinned one)
#   the pinned .so's leaf     ⟶ THIS script         (its HBC version == the baked C++ pin)
#   the baked C++ pin         ⟶ boot gate           (== the LIVE runtime value, fail-closed)
#
# Usage:  bash scripts/check-abi.sh
# Exit:   0 = ABI pin consistent end-to-end · 1 = a drift/wiring regression was found.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_LOCK="$ROOT/host/vendor.lock.json"
GATE_HEADER="$ROOT/host/shared/cpp/CanopyAbiGate.h"
BOOT_SITE="$ROOT/host/android/app/src/main/jni/CanopyHostJni.cpp"
IOS_BOOT_SITE="$ROOT/host/ios/CanopyHostCore/Boot/CanopyHostViewController.mm"
ABIS=(arm64-v8a x86_64)

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

status=0
fail() { red "    FAIL — $*"; status=1; }

echo "==> Hermes/JSI ABI gate (scripts/check-abi.sh)"
echo

# ── Preconditions: the files this gate reasons over must exist ───────────────────────────────
for f in "$VENDOR_LOCK" "$GATE_HEADER" "$BOOT_SITE" "$IOS_BOOT_SITE"; do
  [ -f "$f" ] || { red "    FAIL — required file missing: ${f#$ROOT/}"; exit 1; }
done

# ── extract_bytecode_version <libhermes.so> ──────────────────────────────────────────────────
# Disassembles the getBytecodeVersion() leaf out of .text and returns the integer it loads into
# the return register. The function is a constant-returning leaf on every target Hermes ships:
#   x86_64 : B8 <imm32> C3                  (mov eax, imm32 ; ret)
#   arm64  : <imm> in a MOVZ w0,#imm        (movz w0,#imm{,lsl#s} ; ret == C0 03 5F D6)
# Pure ELF byte-reading via python3 (stdlib only) — no objdump/NDK needed, works on a bare
# ubuntu-latest runner. Prints the version integer on stdout; non-zero exit on any parse failure.
extract_bytecode_version() {
  python3 - "$1" <<'PY'
import struct, sys

path = sys.argv[1]
with open(path, "rb") as fh:
    data = fh.read()

if data[:4] != b"\x7fELF":
    sys.exit("not an ELF file: " + path)

is64 = data[4] == 2            # EI_CLASS: 2 == ELFCLASS64
little = data[5] == 1          # EI_DATA: 1 == little-endian
end = "<" if little else ">"
if not is64:
    sys.exit("expected ELF64: " + path)

e_machine = struct.unpack_from(end + "H", data, 18)[0]   # 0x3E x86_64, 0xB7 aarch64
e_shoff   = struct.unpack_from(end + "Q", data, 40)[0]
e_shentsize = struct.unpack_from(end + "H", data, 58)[0]
e_shnum     = struct.unpack_from(end + "H", data, 60)[0]
e_shstrndx  = struct.unpack_from(end + "H", data, 62)[0]

# Section headers: collect (name_off, type, addr, offset, size, link, entsize).
secs = []
for i in range(e_shnum):
    base = e_shoff + i * e_shentsize
    sh_name   = struct.unpack_from(end + "I", data, base + 0)[0]
    sh_type   = struct.unpack_from(end + "I", data, base + 4)[0]
    sh_addr   = struct.unpack_from(end + "Q", data, base + 16)[0]
    sh_offset = struct.unpack_from(end + "Q", data, base + 24)[0]
    sh_size   = struct.unpack_from(end + "Q", data, base + 32)[0]
    sh_link   = struct.unpack_from(end + "I", data, base + 40)[0]
    sh_entsz  = struct.unpack_from(end + "Q", data, base + 56)[0]
    secs.append((sh_name, sh_type, sh_addr, sh_offset, sh_size, sh_link, sh_entsz))

def vaddr_to_off(vaddr):
    # Find the PROGBITS/section that contains this vaddr and translate to a file offset.
    for (_, sh_type, sh_addr, sh_offset, sh_size, _, _) in secs:
        if sh_addr != 0 and sh_addr <= vaddr < sh_addr + sh_size:
            return sh_offset + (vaddr - sh_addr)
    sys.exit("vaddr 0x%x not in any section" % vaddr)

# Locate a dynsym/symtab section (type 11 == SHT_DYNSYM, 2 == SHT_SYMTAB) and walk its symbols,
# resolving names against its linked string table, to find getBytecodeVersion's value.
MANGLED = b"_ZN8facebook6hermes13HermesRuntime18getBytecodeVersionEv"
sym_value = None
for (_, sh_type, _, sh_offset, sh_size, sh_link, sh_entsz) in secs:
    if sh_type not in (2, 11) or sh_entsz == 0:
        continue
    str_off = secs[sh_link][3]
    str_size = secs[sh_link][4]
    strtab = data[str_off:str_off + str_size]
    for off in range(sh_offset, sh_offset + sh_size, sh_entsz):
        st_name = struct.unpack_from(end + "I", data, off + 0)[0]
        st_value = struct.unpack_from(end + "Q", data, off + 8)[0]
        if st_name == 0:
            continue
        end_n = strtab.find(b"\x00", st_name)
        name = strtab[st_name:end_n]
        if name == MANGLED:
            sym_value = st_value
            break
    if sym_value is not None:
        break

if sym_value is None:
    sys.exit("getBytecodeVersion symbol not found in " + path)

# ARM/THUMB low-bit is irrelevant for aarch64; clear it defensively.
foff = vaddr_to_off(sym_value & ~1)
code = data[foff:foff + 16]

if e_machine == 0x3E:          # x86_64: B8 <imm32> ... (mov eax, imm32)
    if code[0] != 0xB8:
        sys.exit("x86_64 getBytecodeVersion is not a `mov eax,imm32` leaf: %s" % code[:6].hex())
    print(struct.unpack_from("<I", code, 1)[0])
elif e_machine == 0xB7:        # aarch64: decode the MOVZ w0,#imm{,lsl#s} that sets the return reg.
    found = None
    for k in range(0, 12, 4):
        insn = struct.unpack_from("<I", code, k)[0]
        # MOVZ (32-bit): sf=0, opc=10, 100101 -> top bits 0x52800000 mask 0x7F800000 == 0x52800000,
        # and Rd in bits[4:0] must be 0 (w0).
        if (insn & 0x7F80001F) == (0x52800000 | 0):
            imm16 = (insn >> 5) & 0xFFFF
            hw = (insn >> 21) & 0x3
            found = imm16 << (16 * hw)
            break
    if found is None:
        sys.exit("aarch64 getBytecodeVersion: no MOVZ w0,#imm found: %s" % code[:8].hex())
    print(found)
else:
    sys.exit("unsupported e_machine 0x%x" % e_machine)
PY
}

# ── (1) Re-extract the bytecode version from each pinned libhermes.so; they must agree ────────
echo "--> [1/7] bytecode version re-extracted from the pinned libhermes.so (per ABI):"
declare -A bcv=()
canonical=""
for abi in "${ABIS[@]}"; do
  so="$ROOT/host/android/vendor/lib/$abi/libhermes.so"
  if [ ! -f "$so" ]; then
    fail "vendored libhermes.so missing for $abi (host/android/vendor/lib/$abi/libhermes.so)"
    continue
  fi
  if ! v="$(extract_bytecode_version "$so")"; then
    fail "could not read getBytecodeVersion() out of $abi/libhermes.so"
    continue
  fi
  bcv[$abi]="$v"
  echo "      $abi  -> HBC bytecode version $v"
  if [ -z "$canonical" ]; then canonical="$v"
  elif [ "$canonical" != "$v" ]; then
    fail "bytecode version differs across ABIs ($canonical vs $v) — vendored .so are not a matched set"
  fi
done
if [ -n "$canonical" ] && [ "$status" -eq 0 ]; then
  green "    OK — both ABIs speak HBC bytecode version $canonical."
fi
echo

# ── (2) That number must equal the C++ pin baked in CanopyAbiGate.h ──────────────────────────
echo "--> [2/7] baked pin matches the binaries (kCanopyExpectedHermesBytecodeVersion):"
baked_bcv="$(grep -oE 'kCanopyExpectedHermesBytecodeVersion[[:space:]]*=[[:space:]]*[0-9]+' "$GATE_HEADER" \
              | grep -oE '[0-9]+$' || true)"
if [ -z "$baked_bcv" ]; then
  fail "kCanopyExpectedHermesBytecodeVersion not found in CanopyAbiGate.h"
elif [ -z "$canonical" ]; then
  fail "no bytecode version was extracted from the binaries — cannot compare"
elif [ "$baked_bcv" != "$canonical" ]; then
  fail "baked kCanopyExpectedHermesBytecodeVersion=$baked_bcv but the pinned libhermes.so speaks $canonical."
  echo "          A revendor changed Hermes. Update kCanopyExpectedHermesBytecodeVersion in"
  echo "          host/shared/cpp/CanopyAbiGate.h to $canonical (and the RN pin below in lockstep)."
else
  green "    OK — CanopyAbiGate.h pins bytecode version $baked_bcv, matching the binaries."
fi
echo

# ── (3) The baked RN version must equal vendor.lock.json's react-native pin ──────────────────
echo "--> [3/7] baked RN version matches host/vendor.lock.json (kCanopyExpectedRnVersion):"
baked_rn="$(grep -oE 'kCanopyExpectedRnVersion[[:space:]]*=[[:space:]]*"[^"]+"' "$GATE_HEADER" \
             | grep -oE '"[^"]+"' | tr -d '"' || true)"
# The hermes-engine pod-pin in the lock records the react-native version (RNV-1 vendoredArtifacts).
locked_rn="$(python3 - "$VENDOR_LOCK" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    lock = json.load(f)
arts = lock.get("artifacts", [])
# Prefer the hermes-engine pod-pin (its version IS the react-native version); fall back to any
# artifact sourced from react-native.
for a in arts:
    if a.get("relPath") == "hermes-engine":
        print(a.get("version", "")); sys.exit(0)
for a in arts:
    if "react-native" in a.get("source", "").lower():
        print(a.get("version", "")); sys.exit(0)
sys.exit("no hermes-engine / react-native pin found in vendor.lock.json")
PY
)"
if [ -z "$baked_rn" ]; then
  fail "kCanopyExpectedRnVersion not found in CanopyAbiGate.h"
elif [ -z "$locked_rn" ]; then
  fail "could not read the react-native pin from vendor.lock.json"
elif [ "$baked_rn" != "$locked_rn" ]; then
  fail "baked kCanopyExpectedRnVersion=\"$baked_rn\" but vendor.lock.json pins react-native \"$locked_rn\"."
  echo "          Move kCanopyExpectedRnVersion in CanopyAbiGate.h to \"$locked_rn\"."
else
  green "    OK — CanopyAbiGate.h pins react-native $baked_rn, matching vendor.lock.json."
fi
echo

# ── (4) The ANDROID boot path must actually invoke the engine gate ───────────────────────────
echo "--> [4/7] the Android boot path invokes the engine gate (CanopyHostJni.cpp):"
if grep -q 'enforceHermesAbiGate' "$BOOT_SITE" \
   && grep -q 'getBytecodeVersion' "$BOOT_SITE" \
   && grep -q 'CanopyAbiGate.h' "$BOOT_SITE"; then
  green "    OK — boot reads getBytecodeVersion() and runs the gate before evaluating the bundle."
else
  fail "CanopyHostJni.cpp does not wire the boot-time ABI gate (expected enforceHermesAbiGate +"
  echo "          getBytecodeVersion + #include CanopyAbiGate.h). The runtime check would be a no-op."
fi
echo

# ── (5) IOS-4: the iOS boot path must invoke the SAME engine canary ───────────────────────────
# The boot-time Hermes ABI gate is no longer Android-only. The iOS boot site
# (CanopyHostViewController.mm) reads the LIVE getBytecodeVersion() off the runtime it created and
# runs canopy::checkHermesAbi against the same baked pin BEFORE evaluating any JS — so a mismatched
# Hermes.xcframework/libhermes (a partial revendor, a swapped binary) is caught on iOS too, not
# only Android. This assertion is what stops the iOS canary from being silently deleted while CI
# stays green (the symmetric guarantee step [4] gives Android). The compare logic is the SAME
# canopy::checkHermesAbi in CanopyAbiGate.h, unit-tested device-free by the tool's `stack test`.
echo "--> [5/7] the iOS boot path invokes the engine canary (CanopyHostViewController.mm):"
if grep -q 'enforceHermesAbiGate' "$IOS_BOOT_SITE" \
   && grep -q 'getBytecodeVersion' "$IOS_BOOT_SITE" \
   && grep -q 'checkHermesAbi' "$IOS_BOOT_SITE" \
   && grep -q 'CanopyAbiGate.h' "$IOS_BOOT_SITE"; then
  green "    OK — iOS boot reads getBytecodeVersion() and runs checkHermesAbi before evaluating any JS."
else
  fail "CanopyHostViewController.mm does not wire the boot-time ABI canary (expected"
  echo "          enforceHermesAbiGate + getBytecodeVersion + checkHermesAbi + #include CanopyAbiGate.h)."
  echo "          The iOS runtime ABI check would be a no-op — a mismatched Hermes could corrupt silently."
fi
echo

# ── (6) RNV-7: BOTH boot paths must gate the .hbc bundle's bytecode version too ────────────────
# The build tool emits a real Hermes .hbc whose header stamps the bytecode-format version; each
# host must refuse a bundle whose stamped version != the engine pin BEFORE handing it to Hermes
# (canopy::checkBundleBytecode). This proves that load-time gate is wired on BOTH platforms, so a
# wrong-toolchain .hbc can't be silently fed to the engine while this CI step stays green. The C++
# helper itself lives in CanopyAbiGate.h and is unit-tested device-free (the bytecode-version
# parser) by the tool's `stack test` (Spec.hs, "Hermes .hbc bytecode (RNV-7)").
echo "--> [6/7] both boot paths gate the .hbc bytecode version (RNV-7):"
if grep -q 'checkBundleBytecode' "$GATE_HEADER" \
   && grep -q 'looksLikeHermesBytecode' "$GATE_HEADER" \
   && grep -q 'enforceBundleBytecodeGate' "$BOOT_SITE" \
   && grep -q 'checkBundleBytecode' "$BOOT_SITE" \
   && grep -q 'checkBundleBytecode' "$IOS_BOOT_SITE"; then
  green "    OK — Android + iOS call checkBundleBytecode on the bundle before evaluating it (.hbc version gate)."
else
  fail "the RNV-7 .hbc load gate is not wired (expected checkBundleBytecode + looksLikeHermesBytecode"
  echo "          in CanopyAbiGate.h, enforceBundleBytecodeGate + checkBundleBytecode in CanopyHostJni.cpp,"
  echo "          and checkBundleBytecode in CanopyHostViewController.mm). A wrong-toolchain .hbc could be"
  echo "          handed to the engine unchecked on one platform."
fi
echo

# ── (7) The gate's VERDICT logic must actually behave (compile + RUN it, device-free) ─────────
# Steps [4]/[5] prove the gate is WIRED into both boot sites; this step proves the compare logic
# the canary calls (canopy::checkHermesAbi) is CORRECT — by compiling a tiny TU against the REAL
# CanopyAbiGate.h on this Linux runner and running it. This is the device-free behavioural twin of
# the iOS XCTest cases (CanopyEngineTests.mm testHermesAbiGate*): the baked pin's own version is
# accepted, a drifted version is rejected with a MISMATCH message, and a wrong-version .hbc buffer
# is refused. Skipped (NOTICE, not a failure) if no C++ compiler is on the runner.
echo "--> [7/7] the ABI-gate verdict logic behaves (compile + run canopy::checkHermesAbi):"
CXX_BIN="${CXX:-}"
if [ -z "$CXX_BIN" ]; then
  if command -v c++ >/dev/null 2>&1; then CXX_BIN=c++
  elif command -v g++ >/dev/null 2>&1; then CXX_BIN=g++
  elif command -v clang++ >/dev/null 2>&1; then CXX_BIN=clang++
  fi
fi
if [ -z "$CXX_BIN" ]; then
  printf '\033[33m%s\033[0m\n' "    NOTICE — no C++ compiler on PATH; skipping the behavioural run (wiring steps still gate)."
else
  probe_dir="$(mktemp -d)"
  trap 'rm -rf "$probe_dir"' EXIT
  cat > "$probe_dir/abi_probe.cpp" <<'CPP'
#include "CanopyAbiGate.h"
#include <cstdint>
#include <cstdio>
using namespace canopy;
static int fails = 0;
static void expect(bool cond, const char* what) {
  if (!cond) { std::printf("      probe FAIL: %s\n", what); ++fails; }
}
int main() {
  // The canary accepts the engine version it was built+vendored against.
  expect(checkHermesAbi(kCanopyExpectedHermesBytecodeVersion, "HermesRuntime").ok,
         "the baked pin's own bytecode version is accepted");
  // A drifted engine is rejected, LOUD.
  AbiCheckResult bad = checkHermesAbi(kCanopyExpectedHermesBytecodeVersion + 1, "HermesRuntime");
  expect(!bad.ok, "a drifted bytecode version is rejected");
  expect(bad.message.find("ABI MISMATCH") != std::string::npos,
         "the rejection message is an unmistakable MISMATCH line");
  // A wrong-version .hbc buffer is refused; plain JS source always passes.
  uint8_t hbc[16] = {0xC6,0x1F,0xBC,0x03,0xC1,0x03,0x19,0x1F, 0,0,0,0, 0,0,0,0};
  hbc[8] = (uint8_t)((kCanopyExpectedHermesBytecodeVersion + 7) & 0xFF);
  expect(!checkBundleBytecode(hbc, sizeof(hbc)).ok, "a wrong-version .hbc buffer is refused");
  const char* js = "globalThis.__canopy_boot = function(){};";
  expect(checkBundleBytecode(reinterpret_cast<const uint8_t*>(js), 39).ok,
         "plain JS source (no HBC magic) always passes");
  return fails == 0 ? 0 : 1;
}
CPP
  if "$CXX_BIN" -std=c++17 -I "$ROOT/host/shared/cpp" "$probe_dir/abi_probe.cpp" \
        -o "$probe_dir/abi_probe" 2>"$probe_dir/cc.log" && "$probe_dir/abi_probe"; then
    green "    OK — checkHermesAbi accepts the pin, rejects drift; checkBundleBytecode refuses a wrong .hbc."
  else
    fail "the ABI-gate verdict logic did not behave as designed (canopy::checkHermesAbi / checkBundleBytecode)."
    sed 's|^|          |' "$probe_dir/cc.log" 2>/dev/null | head -8
  fi
fi
echo

if [ "$status" -eq 0 ]; then
  green "ALL GREEN — Hermes ABI pin consistent end-to-end (binaries ⇄ C++ pin ⇄ vendor.lock ⇄ Android+iOS boot gate ⇄ .hbc load gate)."
else
  red "REGRESSION — the Hermes/JSI ABI pin drifted. A device SIGABRT is the symptom this prevents." >&2
fi
exit "$status"
