#!/usr/bin/env bash
# perf-android.sh — RND-4: drive a scripted fling on a real device/emulator, capture the
# Choreographer frame-drop metrics, and pull the dump.
#
# WHAT THIS MEASURES
# ------------------
# The one perf question only a device can answer: "does a windowed list fling at 60fps?". The host
# carries a Choreographer.FrameCallback (CanopyFrameMetrics) that times every vsync gap and counts
# frames that missed a vsync (jank). This script:
#   1. enables the instrumentation     (setprop debug.canopy.perf 1 — a DEBUG-only, opt-in flag),
#   2. pushes the list fixture bundle + launches the app (hot-reload path, like dev.sh),
#   3. starts a fresh "list-fling" capture segment (am broadcast … --es start list-fling),
#   4. flings the list a configurable number of times with `adb shell input swipe`,
#   5. asks the app to dump (am broadcast com.canopyhost.PERF_DUMP),
#   6. pulls the JSON dump and prints the jank ledger (via harness/perf-report.js if node is present,
#      else cats the raw JSON).
#
# WHY input-swipe (not uiautomator): this is a black-box driver runnable with nothing but adb — no
# instrumented test APK required — so it works against ANY installed debug build of the host. The
# instrumented suite (CanopyFixtureUiTest) already proves the list scrolls; THIS proves how smoothly.
#
# EMULATOR CAVEAT (the RND-4 "upper-bound-on-jank" requirement): on the x86_64 emulator these numbers
# are an UPPER BOUND on real-device jank — no GPU compositor parity, host-scheduler noise — never a
# floor. The caveat is also embedded IN the dumped JSON so a downstream gate can never mistake an
# emulator number for an arm64-device measurement. Re-run on real arm64 hardware for shippable figures.
#
# Usage:
#   scripts/perf-android.sh [--app <dir>] [--flings N] [--tab <testID>] [--no-build] [--no-report]
#
#   --app <dir>     Canopy app to build+push as the fixture (default: examples/uifixture).
#                   Must have a scrollable list screen reachable by tapping --tab.
#   --flings N      number of fling swipes (default 12).
#   --tab <id>      testID of the tab to open before flinging (default: tab-list; "" = none).
#   --no-build      skip the canopy-native build + push; use whatever bundle is already installed.
#   --no-report     skip the node report; just pull + cat the raw JSON dump.
#
# Requires: a DEBUG build of the host installed once (any `assembleDebug` + install), adb on PATH or
# at $ADB, and (for the build/push step) canopy-native on PATH.
set -euo pipefail

ADB="${ADB:-adb}"
command -v "$ADB" >/dev/null 2>&1 || ADB="/home/quinten/android-tools/sdk/platform-tools/adb"

PKG="${CANOPY_PKG:-org.canopy.echo}"
ACT="com.canopyhost.MainActivity"
ACTION="com.canopyhost.PERF_DUMP"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/examples/uifixture"
FLINGS=12
TAB="tab-list"
DO_BUILD=1
DO_REPORT=1

while [ $# -gt 0 ]; do
  case "$1" in
    --app)       APP="$2"; shift 2 ;;
    --flings)    FLINGS="$2"; shift 2 ;;
    --tab)       TAB="$2"; shift 2 ;;
    --no-build)  DO_BUILD=0; shift ;;
    --no-report) DO_REPORT=0; shift ;;
    -h|--help)   sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

say() { echo "==> $*"; }

# ---- 0. device sanity --------------------------------------------------------
if ! "$ADB" get-state >/dev/null 2>&1; then
  echo "no adb device. Boot an emulator or attach a device first." >&2
  exit 1
fi
DEVABI="$("$ADB" shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r')"
say "device abi: ${DEVABI:-unknown}"
case "$DEVABI" in
  x86*) echo "    NOTE: x86_64 emulator — frame timings are an UPPER BOUND on real-device jank." ;;
esac

# ---- 1. enable the instrumentation (DEBUG + opt-in flag) ---------------------
say "enabling frame instrumentation (setprop debug.canopy.perf 1)"
"$ADB" shell setprop debug.canopy.perf 1

# ---- 2. build + push the fixture bundle, launch the app ----------------------
DEV_BUNDLE=/data/local/tmp/canopy.bundle.js
if [ "$DO_BUILD" = "1" ]; then
  if ! command -v canopy-native >/dev/null 2>&1; then
    echo "canopy-native not on PATH; re-run with --no-build to use the installed bundle." >&2
    exit 1
  fi
  say "build $(basename "$APP")"
  canopy-native build "$APP" >/tmp/canopy-perf-build.log 2>&1 || { tail -20 /tmp/canopy-perf-build.log; exit 1; }
  BUNDLE="$APP/build/canopy.bundle.js"
  [ -f "$BUNDLE" ] || BUNDLE="$APP/build/canopy.bundle.js"
  say "push bundle -> $DEV_BUNDLE"
  "$ADB" push "$BUNDLE" "$DEV_BUNDLE" >/dev/null
  "$ADB" shell chmod 666 "$DEV_BUNDLE" >/dev/null 2>&1 || true
fi

say "launch $PKG/$ACT"
"$ADB" shell am force-stop "$PKG" || true
"$ADB" shell am start -n "$PKG/$ACT" >/dev/null
# Give boot + first render time (Hermes eval + Yoga first layout). The setprop must already be set
# BEFORE this launch so CanopyFrameMetrics.ENABLED is read true at onCreate.
sleep 4

# ---- 3. navigate to the list tab + start a fresh capture segment -------------
W="$("$ADB" shell wm size | sed -n 's/.*: \([0-9]*\)x\([0-9]*\).*/\1/p' | tr -d '\r')"
H="$("$ADB" shell wm size | sed -n 's/.*: \([0-9]*\)x\([0-9]*\).*/\2/p' | tr -d '\r')"
W="${W:-1080}"; H="${H:-2280}"
say "screen ${W}x${H}"

if [ -n "$TAB" ]; then
  # Tap the tab by finding its on-screen bounds via uiautomator dump (content-desc == testID).
  say "open tab '$TAB'"
  "$ADB" shell uiautomator dump /sdcard/window_dump.xml >/dev/null 2>&1 || true
  COORDS="$("$ADB" shell cat /sdcard/window_dump.xml 2>/dev/null | tr '>' '\n' \
    | grep "content-desc=\"$TAB\"" \
    | sed -n 's/.*bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]".*/\1 \2 \3 \4/p' | head -1)"
  if [ -n "$COORDS" ]; then
    set -- $COORDS
    CX=$(( ($1 + $3) / 2 )); CY=$(( ($2 + $4) / 2 ))
    "$ADB" shell input tap "$CX" "$CY"
    sleep 1
  else
    echo "    (tab '$TAB' not found in hierarchy; flinging the current screen instead)"
  fi
fi

say "start capture segment 'list-fling'"
"$ADB" shell am broadcast -a "$ACTION" --es start list-fling >/dev/null

# ---- 4. scripted fling -------------------------------------------------------
# Alternate up/down flings across the vertical middle so the list scrolls both ways under the
# scroller's momentum — the worst case for per-frame layout + recycling cost.
X=$(( W / 2 ))
Y_LO=$(( H * 75 / 100 ))
Y_HI=$(( H * 25 / 100 ))
say "flinging the list ${FLINGS}x"
for i in $(seq 1 "$FLINGS"); do
  if [ $(( i % 2 )) -eq 1 ]; then
    "$ADB" shell input swipe "$X" "$Y_LO" "$X" "$Y_HI" 120   # fling up
  else
    "$ADB" shell input swipe "$X" "$Y_HI" "$X" "$Y_LO" 120   # fling down
  fi
done
# Let the final fling's momentum settle so its tail frames are captured.
sleep 1

# ---- 5. ask the app to dump --------------------------------------------------
say "request perf dump"
"$ADB" shell am broadcast -a "$ACTION" >/dev/null
sleep 1

# ---- 6. pull the dump --------------------------------------------------------
# The app writes to its own external files dir; use run-as where possible, else logcat fallback.
OUT="/tmp/canopy-frame-metrics.json"
REMOTE="/sdcard/Android/data/$PKG/files/perf/frame-metrics.json"
rm -f "$OUT"
if "$ADB" shell test -f "$REMOTE" 2>/dev/null; then
  "$ADB" pull "$REMOTE" "$OUT" >/dev/null 2>&1 || true
fi
if [ ! -s "$OUT" ]; then
  # Fallback: scrape the last PERF_DUMP line from logcat (the app logs the full JSON there too).
  say "pulling dump from logcat (file path unavailable)"
  "$ADB" logcat -d -s CanopyPerf 2>/dev/null \
    | grep -o 'PERF_DUMP {.*}' | tail -1 | sed 's/^PERF_DUMP //' > "$OUT" || true
fi

if [ ! -s "$OUT" ]; then
  echo "FAILED to obtain a perf dump. Is this a DEBUG build with debug.canopy.perf set BEFORE launch?" >&2
  echo "  Check: $ADB logcat -d -s CanopyPerf" >&2
  exit 1
fi
say "dump -> $OUT"

# ---- 7. report ---------------------------------------------------------------
if [ "$DO_REPORT" = "1" ] && command -v node >/dev/null 2>&1; then
  node "$ROOT/harness/perf-report.js" "$OUT" || true
else
  cat "$OUT"
fi
