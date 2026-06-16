#!/usr/bin/env bash
# perf-regression-gate.sh — RND-11: the per-commit performance regression gate.
#
# WHAT THIS IS
# -----------
# RND-9 ratified the competitive perf BAR (harness/perf-bar.json vs RN 0.76.9) and RND-10 built the
# stress/fuzz suite (harness/run-stress.js). A measured bar is only credible if a regression FAILS the
# build — so RND-11 is the GATE: one script, run per commit, that goes red the moment a change makes
# the reconciler/walker slower or wrong. It is the device-FREE perf belt of scripts/ci-test.sh and the
# CI .github/workflows/ci.yml job (it runs INSIDE ci-test.sh; this wrapper also stands alone for a
# quick local "did I just regress perf?" check).
#
# THE FOUR HARD GATES (every one fails the build; none is advisory):
#
#   1. bench.js  --baseline --gate-p95   (RND-3 timings, RND-11 p95)
#        The median (p50) AND the tail-frame (p95) JS-CPU cost of the six reconciler scenarios
#        (coldRender / warmDiff / fullReorder / lazyStable / scalarFastPath / batchFrame) must not
#        regress past the baseline. p50 catches a body-of-the-distribution slowdown; p95 catches a
#        regression that leaves the median flat but FATTENS THE TAIL (a slow path firing 1-in-20
#        frames, an alloc that triggers GC) — which is exactly the "occasional dropped frame" a user
#        perceives as jank. p95 is gated at a tighter 10% (RND-11's headline number); p50 at 25%.
#        The baseline (harness/bench-baseline.json) is RELATIVE and MACHINE-DEPENDENT — re-record per
#        CI machine class with: node harness/bench.js --update-baseline   (see --record below).
#
#   2. run-lazy.js          (RND-1 lazy short-circuit)
#        Proves `lazy`/thunk memoization still short-circuits: a frame that does not change a lazy
#        subtree's arg must NOT re-invoke its render fn. A regression here silently re-runs every
#        memoized subtree every frame — the single most expensive correctness-shaped perf regression
#        the reconciler can take, and the foundation the whole windowing story rests on.
#
#   3. run-list-perf.js     (RND-6 windowing)
#        Proves Native.List windowing holds: a scroll inside the current row window diffs to ZERO
#        host ops, and the per-frame cost is O(rows entering the window), not O(window size) and never
#        O(total rows). A regression here turns a 1000-row fling back into O(N)-per-frame work.
#
#   4. run-stress.js        (RND-10 stress/fuzz + scaling)
#        The heavy reconciler fuzzer: thousands of seeded random mutations over depth-30/breadth-5000
#        keyed trees, asserting (per frame) no-crash + a structural oracle + child-order + handle
#        identity + diff==rebuild + no-handle-leak, PLUS the move-minimality scaling assertion (a full
#        reverse of N keyed children costs exactly N-1 inserts). This is the gate that proves an
#        O(n)->O(n^2) reconciler regression can never land — the regression the bench p95 number would
#        also reflect, pinned here structurally and deterministically.
#
# IOS MIRROR (the "mirrored into the iOS harness" half of RND-11):
#   The four gates above are device-FREE and walker-level — they run the REAL package/external/native.js
#   reconciler, which is the SAME JS the iOS host loads (one bundle, both platforms). So gates 1-4 ARE
#   the iOS reconciler perf gate; there is no second iOS-specific reconciler to time. The iOS DEVICE
#   frame-trace lane (the on-Simulator/on-device half) is gated by the same RELATIVE discipline through
#   harness/perf-report.js + scripts/df-ios-trace-summary.mjs (BrowserStack series -> perf-report dump
#   shape -> perf-report.js --baseline harness/perf-baselines/<device>.json). scripts/check-ios-perf-gate.sh
#   is the device-free STRUCTURAL proof that the iOS perf path is wired to this same per-commit gate +
#   the same relative-baseline discipline (it cannot be compiled off macOS, so it is asserted by grep).
#
# Usage:
#   scripts/perf-regression-gate.sh                 run the four hard gates (the per-commit gate)
#   scripts/perf-regression-gate.sh --quick         smaller stress sizes (faster local pre-push check)
#   scripts/perf-regression-gate.sh --record        re-record the bench baseline on THIS machine class
#                                                   (writes harness/bench-baseline.json; commit it)
#   scripts/perf-regression-gate.sh --p50-tol 0.10 --p95-tol 0.10   tighten on a quiet/dedicated box
#
# Exit code: 0 iff ALL gates pass; non-zero on the first failing gate's count.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HARNESS="$ROOT/harness"
BASELINE="$HARNESS/bench-baseline.json"

# Tolerances. p95 at 10% is RND-11's headline; p50 at 25% absorbs the larger median jitter of a
# JS-CPU microbench on shared CI hardware (the bench header documents why). Both overridable.
P50_TOL="0.25"
P95_TOL="0.10"
QUICK=""
RECORD=""

while [ $# -gt 0 ]; do
  case "$1" in
    --quick)   QUICK="--quick"; shift ;;
    --record)  RECORD="1"; shift ;;
    --p50-tol) P50_TOL="$2"; shift 2 ;;
    --p95-tol) P95_TOL="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,60p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

C_B='\033[1m'; C_G='\033[32m'; C_R='\033[31m'; C_Y='\033[33m'; C_0='\033[0m'

if [ -n "$RECORD" ]; then
  echo -e "${C_B}RND-11 — re-recording the bench baseline on this machine class${C_0}"
  echo "    (p50/p95/p99 are MACHINE-DEPENDENT ns; the gate is RELATIVE. Commit the result.)"
  node "$HARNESS/bench.js" --update-baseline
  echo -e "${C_G}baseline written → $BASELINE${C_0}"
  echo "    Review the diff and commit it so the per-commit gate runs against THIS machine class."
  exit 0
fi

fail=0

echo -e "${C_B}RND-11 — per-commit perf regression gate${C_0}"
echo "    p50 tolerance ${P50_TOL} · p95 tolerance ${P95_TOL} · baseline $(basename "$BASELINE")"
echo

# ---- Gate 1: bench.js p50 + p95 baseline gate -------------------------------------------------
echo -e "${C_B}[1/4] bench.js --baseline --gate-p95 (RND-3 timings + RND-11 p95 tail-frame gate)${C_0}"
if [ ! -f "$BASELINE" ]; then
  echo -e "${C_R}    baseline missing: $BASELINE — run: scripts/perf-regression-gate.sh --record${C_0}" >&2
  fail=1
else
  node "$HARNESS/bench.js" --baseline "$BASELINE" --gate-p95 \
    --tolerance "$P50_TOL" --p95-tolerance "$P95_TOL" || fail=1
fi
echo

# ---- Gate 2: lazy short-circuit (RND-1) -------------------------------------------------------
echo -e "${C_B}[2/4] run-lazy.js (RND-1 lazy/thunk short-circuit — memoization actually skips work)${C_0}"
node "$HARNESS/run-lazy.js" || fail=1
echo

# ---- Gate 3: windowing (RND-6) ----------------------------------------------------------------
echo -e "${C_B}[3/4] run-list-perf.js (RND-6 Native.List windowing — O(rows entering), not O(N))${C_0}"
if [ ! -f "$ROOT/examples/listtest/build/canopy.bundle.js" ]; then
  echo "    (building examples/listtest bundle — not present)"
  canopy-native build "$ROOT/examples/listtest" || fail=1
fi
node "$HARNESS/run-list-perf.js" || fail=1
echo

# ---- Gate 4: stress/fuzz + scaling (RND-10) ---------------------------------------------------
echo -e "${C_B}[4/4] run-stress.js (RND-10 stress/fuzz + move-minimal scaling — no O(n^2) regression)${C_0}"
node "$HARNESS/run-stress.js" $QUICK || fail=1
echo

if [ "$fail" -eq 0 ]; then
  echo -e "${C_G}PERF GATE GREEN — no regression vs the committed baseline/bar.${C_0}"
else
  echo -e "${C_R}PERF REGRESSION — one or more perf gates failed (see above).${C_0}" >&2
  echo -e "${C_Y}    If this is an intentional, justified shift (e.g. a new machine class), re-record:${C_0}" >&2
  echo    "      scripts/perf-regression-gate.sh --record   # then commit harness/bench-baseline.json" >&2
fi
exit "$fail"
