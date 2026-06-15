#!/usr/bin/env bash
# check-rn-coupling.sh — the RN coupling guard for canopy/native.
#
# canopy/native does NOT use React Native's Fabric runtime, RCTBridge, or TurboModules.
# Its entire coupling to the RN ecosystem is a TINY, deliberately-frozen surface:
#   • JSI            (jsi::*)               — value marshalling at the JS↔native seam
#   • Hermes         (facebook::hermes::)   — exactly one symbol: makeHermesRuntime()
#   • Yoga           (YG* / yoga/Yoga.h)    — flexbox layout (iOS host only)
#   • plain JNI      (jni.h)                — Android, NOT fbjni / facebook::jni
#
# This script freezes that surface as a contract. It fails LOUD if:
#   (1) a NEW source file (outside the allowlist below) starts using jsi::/hermes::/Yoga —
#       i.e. the coupling surface grew and nobody updated the contract; or
#   (2) any FORBIDDEN symbol appears anywhere (RCTBridge / TurboModule / fbjni /
#       facebook::jni / MountingManager / RCTSurface / ShadowTree) — i.e. someone pulled in
#       the heavy RN runtime we explicitly do NOT depend on.
#
# It is pure bash + grep (no device, no SDK, no compiler) and runs in CI's cheap `gate` job.
#
# The ALLOWLIST below is mirrored as a table in docs/rn-coupling.md. If you add a file
# here, you MUST update both — the parity check at the end of this script enforces that.
#
# Usage:  bash scripts/check-rn-coupling.sh
# Exit:   0 = surface unchanged (green) · 1 = a coupling/forbidden regression was found.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="$ROOT/host"
DOC="$ROOT/docs/rn-coupling.md"

# ── The frozen coupling surface ─────────────────────────────────────────────────────────
# Paths are relative to host/. Every file here legitimately references a coupling symbol;
# the guard fails if a coupling symbol appears in a file NOT listed here.
ALLOWLIST=(
  # --- portable JSI glue (the ONLY jsi::Value marshalling points) ---
  "shared/cpp/CanopyFabric.cpp"      # 7 __fabric_* host fns + canopyEmitEvent/canopyBoot
  "shared/cpp/CanopyFabric.h"        # #include <jsi/jsi.h>; declares the JSI installer
  "shared/cpp/CanopyModules.cpp"     # __canopy_call/_cancel + canopyResolveCall
  "shared/cpp/CanopyModules.h"       # #include <jsi/jsi.h>; ModuleRegistry holds jsi::Runtime*
  # --- shared module headers that only NAME jsi::Runtime in comments/contracts ---
  "shared/cpp/CanopyImage.h"         # comment: "nothing touches ... the jsi::Runtime"
  "shared/cpp/CanopyJni.h"           # comment: "NEVER touches the jsi::Runtime"
  "shared/cpp/EchoModule.h"          # comment: "NEVER touches the jsi::Runtime"
  "shared/cpp/RestoreEngineModule.h" # comment: "touches the jsi::Runtime; only ..."
  # --- Android boot (plain JNI + Hermes makeHermesRuntime) ---
  "android/app/src/main/jni/CanopyHostJni.cpp"  # facebook::hermes::makeHermesRuntime()
  # --- iOS boot (Hermes makeHermesRuntime + held jsi::Runtime) ---
  "ios/CanopyHostCore/Boot/CanopyHostViewController.h"
  "ios/CanopyHostCore/Boot/CanopyHostViewController.mm"
  "ios/CanopyHostCore/Boot/CanopyModuleHost.h"
  "ios/CanopyHostCore/Boot/CanopyModuleHost.mm"
  # --- iOS bridge headers that forward-declare / name jsi::Runtime ---
  "ios/CanopyHostCore/Bridge/CanopyModule.h"
  "ios/CanopyHostCore/Bridge/CanopyNativeModule.h"
  "ios/CanopyHostCore/CanopyHostCore-Bridging-Header.h"
  "ios/CanopyHostCore/Modules/CanopyModuleSupport.mm"  # comment: "touches no jsi::Runtime"
  # --- iOS render host: YOGA lives here (named "Fabric" but drives Yoga directly) ---
  "ios/CanopyHostCore/Render/CanopyHostFabric.h"
  "ios/CanopyHostCore/Render/CanopyHostFabric.mm"      # #import <yoga/Yoga.h>; YGNode* API
  # --- iOS tests ---
  "ios/Tests/CanopyHostCoreTests/CanopyEngineTests.mm"
)

# Symbols that DEFINE the (allowed-but-frozen) coupling surface. A file matching any of
# these must be in ALLOWLIST.
COUPLING_RE='jsi::|facebook::hermes::|facebook::jsi|\bYG[A-Z]|yoga/Yoga\.h|makeHermesRuntime|<hermes/hermes\.h>'

# Symbols that must NEVER appear (the heavy RN runtime we do not depend on, and fbjni).
FORBIDDEN_RE='RCTBridge|TurboModule|facebook::jni|fbjni|RCTSurface|MountingManager|ShadowTree|RCTComponentViewProtocol|registerNatives|HybridClass'

# File globs to search and dirs to exclude (vendored RN/Hermes/Yoga headers live here and
# would swamp the signal — they are third-party, not OUR coupling).
INCLUDES=(--include='*.cpp' --include='*.h' --include='*.mm' --include='*.hpp')
EXCLUDE_RE='/vendor/|/third_party/'

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

status=0

echo "==> RN coupling guard (scripts/check-rn-coupling.sh)"
echo "    search root: host/  (excluding host/*/vendor, host/shared/third_party)"
echo

# ── (1) FORBIDDEN symbols — must be zero ─────────────────────────────────────────────────
echo "--> [1/3] forbidden RN-runtime/fbjni symbols (expect ZERO):"
forbidden_hits="$(grep -rnE "$FORBIDDEN_RE" "$HOST" "${INCLUDES[@]}" 2>/dev/null \
  | grep -vE "$EXCLUDE_RE" || true)"
if [ -n "$forbidden_hits" ]; then
  red "    FAIL — forbidden RN/fbjni symbol(s) found. canopy/native must NOT use these:"
  echo "$forbidden_hits" | sed 's|^|      |'
  status=1
else
  green "    OK — no RCTBridge / TurboModule / fbjni / facebook::jni / MountingManager / ShadowTree."
fi
echo

# ── (2) NEW coupling files — must be inside the allowlist ─────────────────────────────────
echo "--> [2/3] coupling symbols confined to the allowlist:"
# All files that currently reference a coupling symbol, relative to host/.
mapfile -t found_files < <(
  grep -rlnE "$COUPLING_RE" "$HOST" "${INCLUDES[@]}" 2>/dev/null \
    | grep -vE "$EXCLUDE_RE" \
    | sed "s|^$HOST/||" \
    | sort -u
)

# Build a lookup of the allowlist for O(1) membership.
declare -A allowed=()
for f in "${ALLOWLIST[@]}"; do allowed["$f"]=1; done

unlisted=()
for f in "${found_files[@]}"; do
  [ -z "$f" ] && continue
  if [ -z "${allowed[$f]:-}" ]; then
    unlisted+=("$f")
  fi
done

if [ "${#unlisted[@]}" -gt 0 ]; then
  red "    FAIL — coupling symbol appeared in ${#unlisted[@]} file(s) NOT in the allowlist:"
  for f in "${unlisted[@]}"; do
    echo "      + $f"
    grep -nE "$COUPLING_RE" "$HOST/$f" 2>/dev/null | grep -vE "$EXCLUDE_RE" \
      | head -3 | sed 's|^|          |'
  done
  echo
  echo "    If this is an INTENTIONAL extension of the coupling surface, add the file to"
  echo "    BOTH the ALLOWLIST array in this script AND the table in docs/rn-coupling.md."
  status=1
else
  green "    OK — all ${#found_files[@]} coupling files are accounted for in the allowlist."
fi

# Also flag allowlist entries that no longer match anything (stale — keeps the doc honest).
stale=()
for f in "${ALLOWLIST[@]}"; do
  if ! printf '%s\n' "${found_files[@]}" | grep -qxF "$f"; then
    stale+=("$f")
  fi
done
if [ "${#stale[@]}" -gt 0 ]; then
  red "    FAIL — ${#stale[@]} allowlist entr(y/ies) no longer reference any coupling symbol"
  red "           (or were moved/deleted) — prune them from the script + doc:"
  for f in "${stale[@]}"; do echo "      - $f"; done
  status=1
fi
echo

# ── (3) Doc/guard parity — the allowlist table in the doc must match this array ───────────
echo "--> [3/3] doc/guard parity (docs/rn-coupling.md ⇄ this script):"
if [ ! -f "$DOC" ]; then
  red "    FAIL — $DOC is missing; the contract doc must exist."
  status=1
else
  parity_fail=0
  for f in "${ALLOWLIST[@]}"; do
    if ! grep -qF "$f" "$DOC"; then
      red "    FAIL — allowlist file not documented in rn-coupling.md: $f"
      parity_fail=1
      status=1
    fi
  done
  if [ "$parity_fail" -eq 0 ]; then
    green "    OK — every allowlisted file appears in docs/rn-coupling.md."
  fi
fi
echo

if [ "$status" -eq 0 ]; then
  green "ALL GREEN — RN coupling surface unchanged (${#found_files[@]} files, frozen)."
else
  red "REGRESSION — the RN coupling surface changed. See docs/rn-coupling.md." >&2
fi
exit "$status"
