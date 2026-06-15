#!/usr/bin/env bash
# bench-compare.sh — RND-5 on-device head-to-head: run the SAME scripted fling/tap/mount on the
# Canopy bench app and its byte-identical RN 0.76.9 sibling, capture the SAME gfxinfo/meminfo on
# each, and emit a side-by-side table + the proposed perf-bar verdict (via compare-report.js).
#
# THE CANONICAL WORKLOADS (from ../spec.json), driven identically on BOTH apps:
#   list1000  — fling a 1000-row list; `dumpsys gfxinfo` gives per-frame jank% + frame-time pctls.
#   counter   — tap `increment` N times; we time tap→repaint from the gfxinfo frame stats.
#   depth30   — toggle a 30-deep subtree on/off; cold-mount cost shows in the frame + TTI numbers.
# Plus, per side: cold TTI (am start -W TotalTime) and peak RSS (`dumpsys meminfo` TOTAL PSS).
#
# WHY gfxinfo (not the host's Choreographer dump): gfxinfo is framework-agnostic — it reads the
# SAME SurfaceFlinger frame pipeline for the Canopy host AND the RN app, so the two numbers are
# directly comparable. (perf-android.sh's CanopyFrameMetrics is canopy-only and can't measure RN.)
#
# TWO SIDES, TWO INSTALL PATHS:
#   • canopy : reuses the installed Canopy host (org.canopy.echo / com.canopyhost.MainActivity),
#              pushing THIS bench's bundle to /data/local/tmp (the dev hot-reload path, like
#              scripts/perf-android.sh). Build it first:  canopy-native build ../canopy
#   • rn     : a standalone RN 0.76.9 APK scaffolded by init-rn-project.sh (--rn-dir points at it).
#
# DEVICE / RN-VERSION GATING (the honesty note): an apples-to-apples result needs the SAME device
# AND RN 0.76.9 (the version Canopy/native is ABI-pinned to). On THIS sandbox RN 0.76.9 is NOT
# installed, so the RN side cannot run here. Run `--side canopy` to capture the Canopy device
# numbers today; run the full compare on a box that has the RN toolchain + the same device.
# For a device-free canopy signal RIGHT NOW, use:  node ../harness/bench-walker.js  (no RN, no device).
#
# Usage:
#   bench-compare.sh [--side both|canopy|rn] [--rn-dir DIR] [--flings N] [--taps N]
#                    [--app DIR] [--out-dir DIR] [--no-build]
#
#     --side       which side(s) to measure (default: both).
#     --rn-dir     the scaffolded RN 0.76.9 project dir (from init-rn-project.sh). Required for the rn side.
#     --app        the Canopy bench app dir (default: ../canopy).
#     --flings N   fling swipes for list1000 (default 12, matching spec.json).
#     --taps N     taps for counter (default 50, matching spec.json).
#     --out-dir    where to write canopy.json / rn.json + the report (default: /tmp/rnd5-bench).
#     --no-build   skip (re)building/pushing; measure what is already installed.
set -euo pipefail

# Force a C numeric locale so awk/printf emit a DOT decimal separator (a comma-decimal locale,
# e.g. nl_NL, produces "19,48" which is invalid JSON and breaks compare-report.js).
export LC_ALL=C
export LC_NUMERIC=C

ADB="${ADB:-adb}"
command -v "$ADB" >/dev/null 2>&1 || ADB="/home/quinten/android-tools/sdk/platform-tools/adb"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/canopy"
RN_DIR=""
SIDE="both"
FLINGS=12
TAPS=50
OUT_DIR="/tmp/rnd5-bench"
DO_BUILD=1

CANOPY_PKG="${CANOPY_PKG:-org.canopy.echo}"
CANOPY_ACT="com.canopyhost.MainActivity"

while [ $# -gt 0 ]; do
  case "$1" in
    --side)     SIDE="$2"; shift 2 ;;
    --rn-dir)   RN_DIR="$2"; shift 2 ;;
    --app)      APP="$2"; shift 2 ;;
    --flings)   FLINGS="$2"; shift 2 ;;
    --taps)     TAPS="$2"; shift 2 ;;
    --out-dir)  OUT_DIR="$2"; shift 2 ;;
    --no-build) DO_BUILD=0; shift ;;
    -h|--help)  sed -n '2,48p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

say() { echo "==> $*"; }
mkdir -p "$OUT_DIR"

# ---- device sanity -----------------------------------------------------------
if ! "$ADB" get-state >/dev/null 2>&1; then
  echo "no adb device. Boot an emulator or attach a device first." >&2
  echo "For a device-free canopy signal: node $ROOT/harness/bench-walker.js" >&2
  exit 1
fi
ABI="$("$ADB" shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r')"
say "device abi: ${ABI:-unknown}"
case "$ABI" in
  x86*) echo "    NOTE: x86_64 emulator — frame/jank numbers are an UPPER BOUND on real-device jank." ;;
esac

# Screen geometry for the fling math (fraction-of-screen so it is resolution-independent).
W="$("$ADB" shell wm size | sed -n 's/.*: \([0-9]*\)x\([0-9]*\).*/\1/p' | tr -d '\r')"; W="${W:-1080}"
H="$("$ADB" shell wm size | sed -n 's/.*: \([0-9]*\)x\([0-9]*\).*/\2/p' | tr -d '\r')"; H="${H:-2280}"
X=$(( W / 2 )); Y_LO=$(( H * 75 / 100 )); Y_HI=$(( H * 25 / 100 ))

# ---- helpers -----------------------------------------------------------------

# tap a node by its content-desc (== testID on both apps) via a uiautomator dump.
tap_desc() {
  local desc="$1"
  "$ADB" shell uiautomator dump /sdcard/wd.xml >/dev/null 2>&1 || true
  local coords
  coords="$("$ADB" shell cat /sdcard/wd.xml 2>/dev/null | tr '>' '\n' \
    | grep "content-desc=\"$desc\"" \
    | sed -n 's/.*bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]".*/\1 \2 \3 \4/p' | head -1)"
  if [ -n "$coords" ]; then
    set -- $coords
    "$ADB" shell input tap $(( ($1 + $3) / 2 )) $(( ($2 + $4) / 2 ))
    return 0
  fi
  return 1
}

# Pull `dumpsys gfxinfo <pkg>` into a jank% + frame p95 (ms). Resets stats first so we only see
# the capture window's frames.
capture_gfx() {  # pkg -> echoes "jankPct framep95Ms totalFrames"
  local pkg="$1"
  local raw janky total p95 hist
  raw="$("$ADB" shell dumpsys gfxinfo "$pkg" 2>/dev/null | tr -d '\r')"
  total="$(echo "$raw" | sed -n 's/.*Total frames rendered: \([0-9]*\).*/\1/p' | head -1)"
  janky="$(echo "$raw" | sed -n 's/.*Janky frames: \([0-9]*\) .*/\1/p' | head -1)"
  p95="$(echo "$raw" | sed -n 's/.*95th percentile: \([0-9]*\)ms.*/\1/p' | head -1)"
  total="${total:-0}"; janky="${janky:-0}"; p95="${p95:-0}"
  local jankpct=0
  if [ "$total" -gt 0 ]; then jankpct=$(awk "BEGIN{printf \"%.2f\", 100*$janky/$total}"); fi
  echo "$jankpct $p95 $total"
}

# peak RSS (TOTAL PSS, MB) from meminfo.
capture_rss() {  # pkg -> echoes MB
  local pkg="$1" kb
  kb="$("$ADB" shell dumpsys meminfo "$pkg" 2>/dev/null | tr -d '\r' \
    | sed -n 's/.*TOTAL PSS:[[:space:]]*\([0-9]*\).*/\1/p' | head -1)"
  [ -z "$kb" ] && kb="$("$ADB" shell dumpsys meminfo "$pkg" 2>/dev/null | tr -d '\r' \
    | sed -n 's/^[[:space:]]*TOTAL[[:space:]]*\([0-9]*\).*/\1/p' | head -1)"
  awk "BEGIN{printf \"%.0f\", ${kb:-0}/1024}"
}

# cold TTI: force-stop, then `am start -W` reports TotalTime (ms to first frame).
capture_tti() {  # pkg activity -> echoes ms
  local pkg="$1" act="$2"
  "$ADB" shell am force-stop "$pkg" >/dev/null 2>&1 || true
  sleep 1
  "$ADB" shell am start -W -n "$pkg/$act" 2>/dev/null | tr -d '\r' \
    | sed -n 's/^TotalTime: \([0-9]*\).*/\1/p' | head -1
}

# Drive one side's three workloads and write its metrics JSON.
#   $1 side name, $2 pkg, $3 activity, $4 out.json
drive_side() {
  local side="$1" pkg="$2" act="$3" out="$4"
  say "[$side] cold TTI"
  local tti; tti="$(capture_tti "$pkg" "$act")"; tti="${tti:-0}"
  sleep 3   # let first render settle

  # --- list1000: open the list tab, reset gfx, fling, capture ---
  say "[$side] list1000 — open tab + fling ${FLINGS}x"
  tap_desc "tab-list" || true; sleep 1
  "$ADB" shell dumpsys gfxinfo "$pkg" reset >/dev/null 2>&1 || true
  for i in $(seq 1 "$FLINGS"); do
    if [ $(( i % 2 )) -eq 1 ]; then "$ADB" shell input swipe "$X" "$Y_LO" "$X" "$Y_HI" 120
    else "$ADB" shell input swipe "$X" "$Y_HI" "$X" "$Y_LO" 120; fi
  done
  sleep 1
  read -r LIST_JANK LIST_P95 LIST_FRAMES <<<"$(capture_gfx "$pkg")"

  # --- counter: open the counter tab, reset gfx, tap, capture ---
  say "[$side] counter — open tab + tap ${TAPS}x"
  tap_desc "tab-counter" || true; sleep 1
  "$ADB" shell dumpsys gfxinfo "$pkg" reset >/dev/null 2>&1 || true
  for i in $(seq 1 "$TAPS"); do tap_desc "increment" || true; done
  sleep 1
  read -r CNT_JANK CNT_P95 CNT_FRAMES <<<"$(capture_gfx "$pkg")"
  # tap-to-paint proxy: the p95 frame time during the tap burst (each tap forces one repaint).
  local tap_ms="$CNT_P95"

  # --- depth30: open the depth tab, reset gfx, toggle, capture ---
  say "[$side] depth30 — open tab + toggle subtree"
  tap_desc "tab-depth" || true; sleep 1
  "$ADB" shell dumpsys gfxinfo "$pkg" reset >/dev/null 2>&1 || true
  for i in $(seq 1 20); do tap_desc "toggle-depth" || true; done
  sleep 1
  read -r DEP_JANK DEP_P95 DEP_FRAMES <<<"$(capture_gfx "$pkg")"

  say "[$side] peak RSS"
  local rss; rss="$(capture_rss "$pkg")"

  cat > "$out" <<JSON
{
  "schema": "rnd5-bench/1",
  "side": "$side",
  "lane": "device-fps",
  "device": true,
  "abi": "$ABI",
  "pkg": "$pkg",
  "recordedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "specVersion": $(node -e "console.log(require('$ROOT/spec.json').specVersion)"),
  "rnTarget": "$(node -e "console.log(require('$ROOT/spec.json').rnTarget)")",
  "caveat": "${ABI} device-fps via dumpsys gfxinfo; on an x86_64 emulator these are an UPPER BOUND on real-device jank. tap-to-paint is the p95 frame-time during the tap burst (a proxy, not an input-latency trace).",
  "tti": { "coldMs": $tti },
  "rss": { "peakMb": $rss },
  "workloads": {
    "list1000": { "jankPct": $LIST_JANK, "frameP95Ms": $LIST_P95, "frames": $LIST_FRAMES },
    "counter":  { "tapToPaintMs": $tap_ms, "jankPct": $CNT_JANK, "frames": $CNT_FRAMES },
    "depth30":  { "jankPct": $DEP_JANK, "frameP95Ms": $DEP_P95, "frames": $DEP_FRAMES }
  }
}
JSON
  say "[$side] metrics → $out"
}

# ---- CANOPY side -------------------------------------------------------------
run_canopy() {
  if [ "$DO_BUILD" = "1" ]; then
    command -v canopy-native >/dev/null 2>&1 || { echo "canopy-native not on PATH" >&2; exit 1; }
    say "[canopy] build $APP"
    canopy-native build "$APP" >/tmp/rnd5-canopy-build.log 2>&1 || { tail -20 /tmp/rnd5-canopy-build.log; exit 1; }
    say "[canopy] push bundle (dev hot-reload path)"
    "$ADB" shell setprop debug.canopy.perf 1 || true
    "$ADB" push "$APP/build/canopy.bundle.js" /data/local/tmp/canopy.bundle.js >/dev/null
    "$ADB" shell chmod 666 /data/local/tmp/canopy.bundle.js >/dev/null 2>&1 || true
  fi
  drive_side "canopy" "$CANOPY_PKG" "$CANOPY_ACT" "$OUT_DIR/canopy.json"
}

# ---- RN side -----------------------------------------------------------------
run_rn() {
  if [ -z "$RN_DIR" ]; then
    echo "the rn side needs --rn-dir <scaffolded RN 0.76.9 project> (see init-rn-project.sh)." >&2
    echo "RN 0.76.9 is not installed in this sandbox; author once on a box with the RN toolchain." >&2
    exit 1
  fi
  local rn_pkg rn_act
  rn_pkg="$(sed -n "s/.*applicationId[ =\"']*\([a-zA-Z0-9_.]*\).*/\1/p" "$RN_DIR/android/app/build.gradle" | head -1)"
  rn_pkg="${rn_pkg:-com.canopybenchrn}"
  rn_act="$rn_pkg.MainActivity"
  if [ "$DO_BUILD" = "1" ]; then
    say "[rn] assemble + install debug APK ($rn_pkg)"
    ( cd "$RN_DIR/android" && ./gradlew :app:installDebug ) >/tmp/rnd5-rn-build.log 2>&1 \
      || { tail -30 /tmp/rnd5-rn-build.log; exit 1; }
  fi
  drive_side "rn" "$rn_pkg" "$rn_act" "$OUT_DIR/rn.json"
}

case "$SIDE" in
  canopy) run_canopy ;;
  rn)     run_rn ;;
  both)   run_canopy; run_rn ;;
  *) echo "unknown --side: $SIDE" >&2; exit 2 ;;
esac

# ---- report ------------------------------------------------------------------
say "report"
if [ -f "$OUT_DIR/canopy.json" ] && [ -f "$OUT_DIR/rn.json" ]; then
  node "$ROOT/scripts/compare-report.js" "$OUT_DIR/canopy.json" "$OUT_DIR/rn.json"
elif [ -f "$OUT_DIR/canopy.json" ]; then
  node "$ROOT/scripts/compare-report.js" "$OUT_DIR/canopy.json"
elif [ -f "$OUT_DIR/rn.json" ]; then
  node "$ROOT/scripts/compare-report.js" "$OUT_DIR/rn.json"
fi
