#!/usr/bin/env bash
# check-vendor-pins.sh — the cross-platform RN-version grep-guard for canopy/native (RNV-8).
#
# WHY THIS EXISTS
# ──────────────
# The host pins ONE React-Native release across FOUR places, and the JSI/Hermes ABI is only
# matched if they all agree (Risk #1 — a mismatch SIGABRTs on a user's device):
#
#     iOS Podfile           host/ios/Podfile                       $RN_VERSION = '0.76.9'
#     Android Hermes pin     host/android/app/src/main/cpp/CMakeLists.txt   (comment: "0.76.9 … AARs")
#     baked C++ ABI pin      host/shared/cpp/CanopyAbiGate.h        kCanopyExpectedRnVersion = "0.76.9"
#     vendor lock pod-pins   host/vendor.lock.json                  hermes-engine + Yoga version
#
# check-abi.sh already proves the LAST TWO agree (baked C++ pin ⇄ vendor.lock.json) AND that the
# baked number matches the vendored libhermes.so bytecode. This grep-guard closes the remaining
# hole the master plan names explicitly: "a PR bumping only the Podfile (not the Android lock) →
# CI red." It is the iOS↔Android tie: a bump that touches only ONE platform's pin is caught here,
# loudly, on a Linux runner with no device, no Mac, no SDK — pure grep + jq.
#
# WHAT IT ASSERTS
#   (1) Podfile $RN_VERSION             == CanopyAbiGate.h kCanopyExpectedRnVersion
#   (2) CanopyAbiGate.h kCanopyExpectedRnVersion == vendor.lock.json hermes-engine pod-pin version
#   (3) vendor.lock.json hermes-engine  == vendor.lock.json Yoga pod-pin (the iOS pair move together)
#   (4) the CMakeLists Hermes-pin comment names that SAME RN version (the Android .so provenance)
#
# Transitively (1)+(2)+(3)+(4) force all four pins to one value. So a one-sided bump — Podfile
# only, lock only, CMake only, or the C++ pin only — turns CI red here.
#
# Usage:  bash scripts/check-vendor-pins.sh
# Exit:   0 = all RN pins agree · 1 = a one-sided / drifted pin was found.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PODFILE="$ROOT/host/ios/Podfile"
GATE_HEADER="$ROOT/host/shared/cpp/CanopyAbiGate.h"
VENDOR_LOCK="$ROOT/host/vendor.lock.json"
CMAKELISTS="$ROOT/host/android/app/src/main/cpp/CMakeLists.txt"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

status=0
fail() { red "    FAIL — $*"; status=1; }

echo "==> Cross-platform RN-version pin guard (scripts/check-vendor-pins.sh)"
echo

# ── Preconditions ─────────────────────────────────────────────────────────────────────────────
for f in "$PODFILE" "$GATE_HEADER" "$VENDOR_LOCK" "$CMAKELISTS"; do
  [ -f "$f" ] || { red "    FAIL — required file missing: ${f#"$ROOT"/}"; exit 1; }
done

# ── Extract each pin ──────────────────────────────────────────────────────────────────────────
# iOS Podfile:  $RN_VERSION = '0.76.9'   (single- or double-quoted)
podfile_rn="$(grep -oE "\\\$RN_VERSION[[:space:]]*=[[:space:]]*['\"][^'\"]+['\"]" "$PODFILE" \
              | head -1 | grep -oE "['\"][^'\"]+['\"]" | tr -d "'\"" || true)"

# Baked C++ pin: kCanopyExpectedRnVersion = "0.76.9"
baked_rn="$(grep -oE 'kCanopyExpectedRnVersion[[:space:]]*=[[:space:]]*"[^"]+"' "$GATE_HEADER" \
            | grep -oE '"[^"]+"' | tr -d '"' || true)"

# vendor.lock.json hermes-engine + Yoga pod-pin versions.
lock_hermes="$(jq -r '.artifacts[] | select(.relPath == "hermes-engine") | .version' "$VENDOR_LOCK" 2>/dev/null || true)"
lock_yoga="$(jq -r '.artifacts[]   | select(.relPath == "Yoga")          | .version' "$VENDOR_LOCK" 2>/dev/null || true)"

echo "--> pins read from disk:"
echo "      Podfile  \$RN_VERSION                 = ${podfile_rn:-<none>}"
echo "      CanopyAbiGate.h kCanopyExpectedRnVersion = ${baked_rn:-<none>}"
echo "      vendor.lock.json hermes-engine        = ${lock_hermes:-<none>}"
echo "      vendor.lock.json Yoga                 = ${lock_yoga:-<none>}"
echo

# Presence checks first (an empty pin is a regression, not a silent pass).
[ -n "$podfile_rn" ]  || fail "could not read \$RN_VERSION from host/ios/Podfile"
[ -n "$baked_rn" ]    || fail "could not read kCanopyExpectedRnVersion from CanopyAbiGate.h"
[ -n "$lock_hermes" ] || fail "could not read the hermes-engine pod-pin from vendor.lock.json"
[ -n "$lock_yoga" ]   || fail "could not read the Yoga pod-pin from vendor.lock.json"

# ── (1) Podfile ⇄ baked C++ pin (the iOS↔shared tie — the "Podfile-only bump" hole) ───────────
echo "--> [1/4] iOS Podfile \$RN_VERSION == CanopyAbiGate.h kCanopyExpectedRnVersion:"
if [ -n "$podfile_rn" ] && [ -n "$baked_rn" ]; then
  if [ "$podfile_rn" = "$baked_rn" ]; then
    green "    OK — both pin react-native $podfile_rn."
  else
    fail "Podfile pins react-native \"$podfile_rn\" but CanopyAbiGate.h pins \"$baked_rn\"."
    echo "          A one-sided bump. Move BOTH platforms together: the iOS Podfile \$RN_VERSION and"
    echo "          host/shared/cpp/CanopyAbiGate.h kCanopyExpectedRnVersion must name the same release."
  fi
fi
echo

# ── (2) baked C++ pin ⇄ vendor.lock.json hermes-engine (mirrors check-abi.sh step 3) ──────────
echo "--> [2/4] CanopyAbiGate.h kCanopyExpectedRnVersion == vendor.lock.json hermes-engine pod-pin:"
if [ -n "$baked_rn" ] && [ -n "$lock_hermes" ]; then
  if [ "$baked_rn" = "$lock_hermes" ]; then
    green "    OK — both pin react-native $baked_rn."
  else
    fail "CanopyAbiGate.h pins \"$baked_rn\" but vendor.lock.json's hermes-engine is \"$lock_hermes\"."
    echo "          Re-run scripts/revendor.sh lock after a bump, then move the C++ pin in lockstep."
  fi
fi
echo

# ── (3) hermes-engine ⇄ Yoga (the iOS pod pair must come from one RN release) ─────────────────
echo "--> [3/4] vendor.lock.json hermes-engine == Yoga pod-pin (one matched RN release):"
if [ -n "$lock_hermes" ] && [ -n "$lock_yoga" ]; then
  if [ "$lock_hermes" = "$lock_yoga" ]; then
    green "    OK — hermes-engine and Yoga are both react-native $lock_hermes."
  else
    fail "vendor.lock.json hermes-engine=\"$lock_hermes\" but Yoga=\"$lock_yoga\" — the iOS pods drifted apart."
    echo "          Both pods MUST come from the same React-Native release (Risk #1). Re-vendor + re-lock."
  fi
fi
echo

# ── (4) the Android CMakeLists Hermes-pin comment names that same RN release ──────────────────
# The .so provenance lives in a comment (the binaries are vendored, not built here), so we assert
# that the locked RN version literally appears in the CMakeLists provenance note. This catches a
# bump that updates the vendored .so but forgets to refresh the recorded Android provenance.
echo "--> [4/4] CMakeLists Hermes-pin provenance names react-native $lock_hermes:"
if [ -n "$lock_hermes" ]; then
  if grep -qF "$lock_hermes" "$CMAKELISTS"; then
    green "    OK — CMakeLists.txt names react-native $lock_hermes (matches the vendored .so provenance)."
  else
    fail "CMakeLists.txt does not name react-native \"$lock_hermes\" (its Hermes-pin provenance comment drifted)."
    echo "          Update the 'extracted from the <rn> … AARs' note in"
    echo "          host/android/app/src/main/cpp/CMakeLists.txt to react-native $lock_hermes."
  fi
fi
echo

if [ "$status" -eq 0 ]; then
  green "ALL GREEN — every RN pin agrees (Podfile ⇄ C++ ABI pin ⇄ vendor.lock.json ⇄ CMakeLists)."
else
  red "REGRESSION — a one-sided RN-version bump was found. A device SIGABRT is the symptom this prevents." >&2
fi
exit "$status"
