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
#   (4) The boot site (CanopyHostJni.cpp) actually CALLS the gate — so the runtime check can't
#       be quietly deleted while this CI step stays green.
#   (5) RNV-7: the boot site ALSO gates the about-to-be-evaluated .hbc bundle's stamped bytecode
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
ABIS=(arm64-v8a x86_64)

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

status=0
fail() { red "    FAIL — $*"; status=1; }

echo "==> Hermes/JSI ABI gate (scripts/check-abi.sh)"
echo

# ── Preconditions: the files this gate reasons over must exist ───────────────────────────────
for f in "$VENDOR_LOCK" "$GATE_HEADER" "$BOOT_SITE"; do
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
echo "--> [1/5] bytecode version re-extracted from the pinned libhermes.so (per ABI):"
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
echo "--> [2/5] baked pin matches the binaries (kCanopyExpectedHermesBytecodeVersion):"
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
echo "--> [3/5] baked RN version matches host/vendor.lock.json (kCanopyExpectedRnVersion):"
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

# ── (4) The boot path must actually invoke the engine gate ───────────────────────────────────
echo "--> [4/5] the boot path invokes the engine gate (CanopyHostJni.cpp):"
if grep -q 'enforceHermesAbiGate' "$BOOT_SITE" \
   && grep -q 'getBytecodeVersion' "$BOOT_SITE" \
   && grep -q 'CanopyAbiGate.h' "$BOOT_SITE"; then
  green "    OK — boot reads getBytecodeVersion() and runs the gate before evaluating the bundle."
else
  fail "CanopyHostJni.cpp does not wire the boot-time ABI gate (expected enforceHermesAbiGate +"
  echo "          getBytecodeVersion + #include CanopyAbiGate.h). The runtime check would be a no-op."
fi
echo

# ── (5) RNV-7: the boot path must gate the .hbc bundle's bytecode version too ─────────────────
# The build tool emits a real Hermes .hbc whose header stamps the bytecode-format version; the
# host must refuse a bundle whose stamped version != the engine pin BEFORE handing it to Hermes
# (canopy::checkBundleBytecode). This proves that load-time gate is wired, so a wrong-toolchain
# .hbc can't be silently fed to the engine while this CI step stays green. The C++ helper itself
# lives in CanopyAbiGate.h and is unit-tested device-free (the bytecode-version parser) by the
# tool's `stack test` (Spec.hs, "Hermes .hbc bytecode (RNV-7)").
echo "--> [5/5] the boot path gates the .hbc bytecode version (RNV-7, CanopyHostJni.cpp):"
if grep -q 'checkBundleBytecode' "$GATE_HEADER" \
   && grep -q 'looksLikeHermesBytecode' "$GATE_HEADER" \
   && grep -q 'enforceBundleBytecodeGate' "$BOOT_SITE" \
   && grep -q 'checkBundleBytecode' "$BOOT_SITE"; then
  green "    OK — boot calls checkBundleBytecode on the bundle before evaluating it (.hbc version gate)."
else
  fail "the RNV-7 .hbc load gate is not wired (expected checkBundleBytecode + looksLikeHermesBytecode"
  echo "          in CanopyAbiGate.h, and enforceBundleBytecodeGate + checkBundleBytecode in"
  echo "          CanopyHostJni.cpp). A wrong-toolchain .hbc could be handed to the engine unchecked."
fi
echo

if [ "$status" -eq 0 ]; then
  green "ALL GREEN — Hermes ABI pin consistent end-to-end (binaries ⇄ C++ pin ⇄ vendor.lock ⇄ boot gate ⇄ .hbc load gate)."
else
  red "REGRESSION — the Hermes/JSI ABI pin drifted. A device SIGABRT is the symptom this prevents." >&2
fi
exit "$status"
