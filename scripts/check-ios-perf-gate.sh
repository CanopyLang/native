#!/usr/bin/env bash
# check-ios-perf-gate.sh — RND-11 structural gate for the iOS half of the per-commit perf gate (NO Mac).
#
# RND-11 asks for the per-commit perf regression gate to be "mirrored into the iOS harness". The iOS
# host cannot be COMPILED off macOS, so — exactly like check-ios-devloop.sh / check-ios-capability-parity.sh
# — this gate proves device-free, by structural assertion, that the iOS perf path is wired to the SAME
# per-commit gate and the SAME relative-baseline discipline as Android. It fails LOUD in CI's cheap Linux
# `gate` job the moment that wiring drifts, long before any Mac build runs.
#
# WHY THERE IS NO SECOND iOS RECONCILER TO TIME
# ---------------------------------------------
# canopy/native ships ONE reconciler — package/external/native.js — and BOTH hosts load that same JS
# bundle (Android via Hermes-in-JNI, iOS via Hermes-in-CanopyHostViewController). So the four device-free
# walker gates the per-commit gate enforces (bench.js p50+p95, run-lazy, run-list-perf, run-stress) time
# the EXACT JS the iOS host executes. Gating them once IS gating the iOS reconciler — there is no
# iOS-specific reconciler that could regress independently. This gate asserts that invariant is real
# (the iOS boot loads the shared bundle, not a forked one).
#
# THE TWO LANES THIS ASSERTS ARE WIRED
# ------------------------------------
#   (A) the SHARED device-free reconciler gate — the per-commit gate (scripts/perf-regression-gate.sh)
#       runs the four walker gates over the shared package/external/native.js, and the iOS host boots
#       that same shared bundle. So the per-commit gate already covers iOS's reconciler.
#   (B) the iOS DEVICE frame-trace lane — the on-Simulator/on-device half — is distilled by
#       scripts/df-ios-trace-summary.mjs into the SAME perf-report.js dump shape as Android, and gated
#       by harness/perf-report.js --baseline against a PER-DEVICE relative baseline
#       (harness/perf-baselines/<device>.json) — the identical relative discipline (jank% additive
#       points, p95 frame-time relative multiple) the Android frame-metrics dump is gated by. One gate,
#       both platforms; never an absolute millisecond.
#
# Pure bash + grep + node (no device, no SDK, no Xcode). Usage:  bash scripts/check-ios-perf-gate.sh
# Exit: 0 = the iOS perf path is wired to the per-commit gate + relative baseline · 1 = a seam drifted.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IOS="$ROOT/host/ios"

GATE="$ROOT/scripts/perf-regression-gate.sh"
BENCH="$ROOT/harness/bench.js"
PERF_REPORT="$ROOT/harness/perf-report.js"
TRACE_SUMMARY="$ROOT/scripts/df-ios-trace-summary.mjs"
BROWSERSTACK="$ROOT/scripts/df-browserstack.sh"
NATIVE_JS="$ROOT/package/external/native.js"
BASELINES_DIR="$ROOT/harness/perf-baselines"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
status=0

# need <label> <file> <pattern...> — every pattern must be present in the file.
need() {
  local label="$1" file="$2"; shift 2
  if [ ! -f "$file" ]; then red "    FAIL — $label: missing file ${file#$ROOT/}"; status=1; return; fi
  local miss=()
  for pat in "$@"; do
    grep -qE -- "$pat" "$file" || miss+=("$pat")
  done
  if [ "${#miss[@]}" -gt 0 ]; then
    red "    FAIL — $label (${file#$ROOT/}) is missing:"
    for m in "${miss[@]}"; do echo "        · $m"; done
    status=1
  else
    green "    OK  — $label"
  fi
}

echo "==> iOS per-commit perf-gate mirror (scripts/check-ios-perf-gate.sh)"
echo "    (structural — the iOS host cannot be compiled off macOS; this proves the perf path is wired"
echo "     to the SAME per-commit gate + the SAME relative-baseline discipline as Android.)"
echo

# ── (A) the per-commit gate runs the four shared walker gates ─────────────────────────────
echo "--> [A] the per-commit gate (scripts/perf-regression-gate.sh) drives the four shared gates:"
need "the gate wires bench p50+p95, run-lazy, run-list-perf, run-stress" "$GATE" \
  'bench\.js.*--baseline.*--gate-p95' \
  'run-lazy\.js' \
  'run-list-perf\.js' \
  'run-stress\.js'
need "bench.js exposes the p95 (tail-frame) gate RND-11 added" "$BENCH" \
  '--gate-p95' \
  'p95Tolerance' \
  'p95Regressions'

# ── (B) the iOS host loads the SAME shared reconciler bundle the gate times ────────────────
echo "--> [B] the iOS host boots the SHARED package/external/native.js the gate times (no iOS fork):"
# the shared reconciler exists and exports the walker the gate drives.
need "the shared reconciler exports the walker the gate times" "$NATIVE_JS" \
  '_Native_render' \
  '_Native_updateTNode'
# the iOS boot loads a canopy bundle (the same artifact canopy-native emits, which embeds native.js) —
# it does not ship a forked reconciler. Assert the boot site evaluates the bundle, not a private walker.
VC="$IOS/CanopyHostCore/Boot/CanopyHostViewController.mm"
if [ -f "$VC" ]; then
  need "the iOS VC boots the canopy bundle (shared JS), via __canopy_boot" "$VC" \
    '__canopy_boot'
else
  # be tolerant of the exact boot-site filename across iOS waves: assert SOME iOS boot site calls __canopy_boot.
  if grep -rqE -- '__canopy_boot' "$IOS" 2>/dev/null; then
    green "    OK  — an iOS boot site evaluates the shared canopy bundle (__canopy_boot)"
  else
    red "    FAIL — no iOS boot site calls __canopy_boot (cannot confirm iOS loads the shared reconciler)"
    status=1
  fi
fi

# ── (C) the iOS DEVICE frame-trace lane uses the SAME perf-report.js relative gate ─────────
echo "--> [C] the iOS device frame-trace lane is gated by the SAME relative perf-report.js gate:"
need "df-ios-trace-summary distils iOS traces into the perf-report.js dump shape" "$TRACE_SUMMARY" \
  'perf-report\.js' \
  'jankPct' \
  'p95Ms' \
  'arm64'
need "the BrowserStack iOS driver gates the distilled summary vs a per-device baseline" "$BROWSERSTACK" \
  'df-ios-trace-summary\.mjs' \
  'perf-report\.js' \
  'perf-baselines'
need "perf-report.js gates RELATIVELY (jank% additive points, p95 frame-time multiple)" "$PERF_REPORT" \
  'jankPoints' \
  'p95Tol' \
  'p95Ms'

# ── (D) the per-device baselines are RELATIVE + per-device (never an absolute ms) ──────────
echo "--> [D] per-device baselines are relative + per-device-class (an iPhone baseline ≠ an emulator one):"
if [ -d "$BASELINES_DIR" ]; then
  need "perf-baselines/README documents the iOS per-device relative gate" "$BASELINES_DIR/README.md" \
    'iphone' \
    'relative' \
    'perf-report\.js'
  green "    OK  — harness/perf-baselines/ exists (per-device relative baselines live here)"
else
  red "    FAIL — harness/perf-baselines/ missing (the per-device baseline store)"
  status=1
fi

# ── (E) the gate logic is self-proving (perf-report.js --selftest is device-free) ─────────
echo "--> [E] the iOS device-lane gate logic is device-free self-proving:"
if node "$PERF_REPORT" --selftest >/dev/null 2>&1; then
  green "    OK  — perf-report.js --selftest passes (the relative gate logic is proven device-free)"
else
  red "    FAIL — perf-report.js --selftest failed (the iOS device-lane gate logic is broken)"
  status=1
fi

echo
if [ "$status" -eq 0 ]; then
  green "ALL GREEN — the iOS perf path is wired to the per-commit gate + the same relative-baseline gate."
  green "            (Mac-gated: a real Simulator/BrowserStack trace run is documented in docs/device-farm.md.)"
else
  red "REGRESSION — the iOS perf gate mirror drifted. See plans/dependent/RND-11.md + docs/device-farm.md." >&2
fi
exit "$status"
