#!/usr/bin/env bash
# check-hermes-cabi.sh — RNV-4 seam + Hermes C-ABI capability probe (device-free, no SDK).
#
# RNV-4 routes BOTH boot sites through ONE Hermes runtime factory, canopy::makeRuntime()
# (host/shared/cpp/CanopyHermes.cpp). That factory has two compile-time backends:
#   (A) default            → facebook::hermes::makeHermesRuntime()          (the RN-bundled .so)
#   (B) -DCANOPY_HERMES_CABI → makeHermesABIRuntimeWrapper(get_hermes_abi_vtable())  (stable C-vtable)
#
# This script does two device-free jobs:
#
#   [1] WIRING — proves the RNV-4 seam is actually in place and can't be silently reverted:
#         • CanopyHermes.{h,cpp} exist and define canopy::makeRuntime();
#         • the Android boot site (CanopyHostJni.cpp) and the iOS boot site
#           (CanopyHostViewController.mm) call canopy::makeRuntime() and DO NOT call
#           makeHermesRuntime() directly any more (the coupling moved behind the seam);
#         • CanopyHermes.cpp is in the Android CMake source list.
#
#   [2] CAPABILITY — reports whether the vendored libhermes.so EXPORTS the C-ABI vtable
#       (get_hermes_abi_vtable). This is the RNV-6 gate the RNV-4 plan calls out: the
#       RN-0.76.9-bundled libhermes does NOT ship the C-ABI (only the C++ makeHermesRuntime),
#       so backend (B) cannot be the default until a standalone Hermes that exports the vtable
#       is vendored. This is reported as a NOTICE (informational), NOT a failure — the default
#       backend (A) is correct and green today. The day a revendor brings the C-ABI export, this
#       probe flips to "available", which is the signal to flip the default to -DCANOPY_HERMES_CABI.
#
# Usage:  bash scripts/check-hermes-cabi.sh
# Exit:   0 = the RNV-4 seam is correctly wired (capability is advisory) · 1 = the seam regressed.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HERMES_CPP="$ROOT/host/shared/cpp/CanopyHermes.cpp"
HERMES_H="$ROOT/host/shared/cpp/CanopyHermes.h"
ANDROID_BOOT="$ROOT/host/android/app/src/main/jni/CanopyHostJni.cpp"
IOS_BOOT="$ROOT/host/ios/CanopyHostCore/Boot/CanopyHostViewController.mm"
CMAKE="$ROOT/host/android/app/src/main/cpp/CMakeLists.txt"
ABIS=(arm64-v8a x86_64)

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

status=0
fail() { red "    FAIL — $*"; status=1; }

echo "==> RNV-4 Hermes seam + C-ABI capability probe (scripts/check-hermes-cabi.sh)"
echo

# ── [1] WIRING ───────────────────────────────────────────────────────────────────────────────
echo "--> [1/2] the RNV-4 runtime-factory seam is wired:"

for f in "$HERMES_CPP" "$HERMES_H" "$ANDROID_BOOT" "$CMAKE"; do
  [ -f "$f" ] || fail "required file missing: ${f#$ROOT/}"
done
# iOS boot is authored-only (no Mac here); check it if present, but don't hard-require it.
[ -f "$IOS_BOOT" ] || yellow "    NOTE — iOS boot site absent (${IOS_BOOT#$ROOT/}); skipping its checks."

if [ -f "$HERMES_H" ] && grep -q 'makeRuntime' "$HERMES_H"; then
  green "    OK — CanopyHermes.h declares canopy::makeRuntime()."
else
  fail "CanopyHermes.h does not declare makeRuntime()."
fi

# The factory must name a real Hermes entry point in AT LEAST one backend branch (else it is a stub).
if [ -f "$HERMES_CPP" ] \
   && grep -q 'makeHermesRuntime' "$HERMES_CPP" \
   && grep -q 'makeHermesABIRuntimeWrapper' "$HERMES_CPP" \
   && grep -q 'get_hermes_abi_vtable' "$HERMES_CPP" \
   && grep -q 'CANOPY_HERMES_CABI' "$HERMES_CPP"; then
  green "    OK — CanopyHermes.cpp wraps BOTH backends (C++ makeHermesRuntime + C-vtable wrapper)."
else
  fail "CanopyHermes.cpp must wrap both backends behind CANOPY_HERMES_CABI"
  echo "          (makeHermesRuntime AND makeHermesABIRuntimeWrapper + get_hermes_abi_vtable)."
fi

# The Android boot site must call the seam and NOT name makeHermesRuntime directly any more.
if grep -q 'canopy::makeRuntime' "$ANDROID_BOOT"; then
  green "    OK — Android boot (CanopyHostJni.cpp) creates the runtime via canopy::makeRuntime()."
else
  fail "CanopyHostJni.cpp does not call canopy::makeRuntime() — the seam is not wired."
fi
if grep -qE '=\s*facebook::hermes::makeHermesRuntime\(' "$ANDROID_BOOT"; then
  fail "CanopyHostJni.cpp STILL assigns facebook::hermes::makeHermesRuntime() directly — RNV-4 expects"
  echo "          that creation to go through canopy::makeRuntime() (the boot site must not name the engine)."
else
  green "    OK — Android boot no longer assigns makeHermesRuntime() directly (coupling is behind the seam)."
fi

# Android CMake must compile the factory TU.
if grep -q 'CanopyHermes.cpp' "$CMAKE"; then
  green "    OK — CanopyHermes.cpp is in the Android CMake source list."
else
  fail "CanopyHermes.cpp is not in host/android/app/src/main/cpp/CMakeLists.txt — it won't be built."
fi

# iOS boot site (authored-only): same two assertions if the file exists.
if [ -f "$IOS_BOOT" ]; then
  if grep -q 'canopy::makeRuntime' "$IOS_BOOT"; then
    green "    OK — iOS boot (CanopyHostViewController.mm) creates the runtime via canopy::makeRuntime()."
  else
    fail "CanopyHostViewController.mm does not call canopy::makeRuntime() — the iOS seam is not wired."
  fi
  if grep -qE '=\s*facebook::hermes::makeHermesRuntime\(' "$IOS_BOOT"; then
    fail "CanopyHostViewController.mm STILL assigns makeHermesRuntime() directly — route it through the seam."
  else
    green "    OK — iOS boot no longer assigns makeHermesRuntime() directly."
  fi
fi
echo

# ── [2] CAPABILITY ─────────────────────────────────────────────────────────────────────────────
# Probe the vendored libhermes.so for the C-ABI export. This decides whether backend (B) — the
# durable C-vtable path — can be the default yet (RNV-6). Advisory: NEVER fails the build.
echo "--> [2/2] vendored libhermes.so C-ABI capability (advisory — RNV-6 gate):"

# nm is the cheap path; if it is absent, fall back to a pure-python dynsym scan (stdlib only) so the
# probe still works on a bare runner with no binutils.
probe_cabi() {
  local so="$1"
  if command -v nm >/dev/null 2>&1; then
    if nm -D --defined-only "$so" 2>/dev/null | grep -q 'get_hermes_abi_vtable'; then
      echo "yes"; return 0
    fi
    echo "no"; return 0
  fi
  python3 - "$so" <<'PY'
import struct, sys
path = sys.argv[1]
with open(path, "rb") as fh:
    data = fh.read()
if data[:4] != b"\x7fELF":
    print("err"); sys.exit(0)
end = "<" if data[5] == 1 else ">"
e_shoff = struct.unpack_from(end + "Q", data, 40)[0]
e_shentsize = struct.unpack_from(end + "H", data, 58)[0]
e_shnum = struct.unpack_from(end + "H", data, 60)[0]
secs = []
for i in range(e_shnum):
    base = e_shoff + i * e_shentsize
    sh_type = struct.unpack_from(end + "I", data, base + 4)[0]
    sh_offset = struct.unpack_from(end + "Q", data, base + 24)[0]
    sh_size = struct.unpack_from(end + "Q", data, base + 32)[0]
    sh_link = struct.unpack_from(end + "I", data, base + 40)[0]
    sh_entsz = struct.unpack_from(end + "Q", data, base + 56)[0]
    secs.append((sh_type, sh_offset, sh_size, sh_link, sh_entsz))
target = b"get_hermes_abi_vtable"
for (sh_type, sh_offset, sh_size, sh_link, sh_entsz) in secs:
    if sh_type not in (2, 11) or sh_entsz == 0:
        continue
    str_off = secs[sh_link][1]; str_size = secs[sh_link][2]
    strtab = data[str_off:str_off + str_size]
    for off in range(sh_offset, sh_offset + sh_size, sh_entsz):
        st_name = struct.unpack_from(end + "I", data, off + 0)[0]
        st_value = struct.unpack_from(end + "Q", data, off + 8)[0]
        if st_name == 0 or st_value == 0:
            continue
        e = strtab.find(b"\x00", st_name)
        if strtab[st_name:e] == target:
            print("yes"); sys.exit(0)
print("no")
PY
}

any_so=0
cabi_available=1   # 1 == available on all probed ABIs; set to 0 the moment one lacks it
for abi in "${ABIS[@]}"; do
  so="$ROOT/host/android/vendor/lib/$abi/libhermes.so"
  if [ ! -f "$so" ]; then
    yellow "    NOTE — vendored libhermes.so absent for $abi (run scripts/fetch-vendor.sh); skipping."
    continue
  fi
  any_so=1
  res="$(probe_cabi "$so")"
  case "$res" in
    yes) green "    $abi  -> EXPORTS get_hermes_abi_vtable (C-ABI available)";;
    no)  yellow "    $abi  -> does NOT export get_hermes_abi_vtable (C++ makeHermesRuntime only)"; cabi_available=0;;
    *)   yellow "    $abi  -> could not parse the .so for the C-ABI export (treating as unavailable)"; cabi_available=0;;
  esac
done

echo
if [ "$any_so" -eq 0 ]; then
  yellow "    ADVISORY — no vendored libhermes.so on disk to probe; capability unknown (seam still wired)."
elif [ "$cabi_available" -eq 1 ]; then
  green   "    CAPABILITY — the vendored libhermes EXPORTS the C-ABI vtable on every ABI."
  echo    "    >>> RNV-6 unblocked: you can now build the durable backend with -DCANOPY_HERMES_CABI=1"
  echo    "        and make it the default in CanopyHermes.cpp."
else
  yellow  "    ADVISORY — the vendored (RN-bundled) libhermes exports ONLY the C++ makeHermesRuntime;"
  echo    "    it does NOT ship get_hermes_abi_vtable. So backend (A) is correct as the default today."
  echo    "    The stable C-vtable backend (B) lands when RNV-6 vendors a standalone Hermes that exports"
  echo    "    the vtable — at which point this probe flips to CAPABILITY and the default can move."
fi
echo

if [ "$status" -eq 0 ]; then
  green "ALL GREEN — the RNV-4 Hermes runtime-factory seam is wired (C-ABI capability is advisory)."
else
  red "REGRESSION — the RNV-4 Hermes seam is not correctly wired." >&2
fi
exit "$status"
