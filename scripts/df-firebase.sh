#!/usr/bin/env bash
# df-firebase.sh — DF-1 Android provider: run the smoke + perf-trace sweep on a REAL arm64 device in
# Firebase Test Lab. Called by df-android.sh (DF_PROVIDER=firebase). See docs/device-farm.md §2/§5.
#
# WHY Firebase for Android: cheapest path to real arm64 (Google's own Pixels), and it can PULL
# arbitrary files off the device (--directories-to-pull), which is exactly how perf-android.sh already
# exports its frame-metrics JSON — so our existing perf artifact comes back UNCHANGED. Debug APK = no
# signing.
#
# WHAT THIS DOES (on a box with `gcloud` + a Test Lab service account):
#   1. submit the smoke run: the host APK on a real Pixel, with the device held while a black-box
#      Appium session (smoke.mjs) drives it (Robo/instrumentation host); video recorded;
#   2. trigger the perf-android.sh fling capture and pull /sdcard/Android/data/<pkg>/files/perf via
#      --directories-to-pull, so frame-metrics.json lands in $DF_OUT;
#   3. gate the trace with harness/perf-report.js against the per-device baseline.
#
# It SELF-SKIPS (skip()) when gcloud or the service-account credential is absent, so it is safe to run
# on this box (no account). The exact `gcloud firebase test android run` invocation is written against
# the documented CLI but is NOT executed here (no account) — see docs/device-farm.md §8.
#
# Env (in addition to df-android.sh's): GCP_PROJECT, GOOGLE_APPLICATION_CREDENTIALS or GCP_SA_KEY.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# Inherit skip()/say() if exported by df-android.sh; otherwise define local ones (direct invocation).
if ! declare -F skip >/dev/null 2>&1; then
  DF_REQUIRE="${DF_REQUIRE:-0}"
  skip() { echo "df-firebase SKIP — $1"; [ "${DF_REQUIRE:-0}" = "1" ] && { echo "ERROR (DF_REQUIRE=1): $1"; exit 1; }; exit 0; }
fi
if ! declare -F say >/dev/null 2>&1; then say() { echo "==> df-firebase: $*"; }; fi

DF_OUT="${DF_OUT:-$ROOT/df-out/android}"
APK="${APK:-}"
DF_DEVICE_MODEL="${DF_DEVICE_MODEL:-oriole}"
DF_DEVICE_VERSION="${DF_DEVICE_VERSION:-34}"
PKG="${CANOPY_PKG:-org.canopy.echo}"
mkdir -p "$DF_OUT"

# --- preconditions: skip cleanly if no account/CLI/APK -----------------------------------------
command -v gcloud >/dev/null 2>&1 || skip "gcloud CLI not installed (no Firebase Test Lab account wired)"
if [ -z "${GOOGLE_APPLICATION_CREDENTIALS:-}" ] && [ -z "${GCP_SA_KEY:-}" ]; then
  skip "no Test Lab service-account credential (set GCP_SA_KEY / GOOGLE_APPLICATION_CREDENTIALS)"
fi
[ -n "${GCP_PROJECT:-}" ] || skip "GCP_PROJECT unset (the Test Lab project)"
if [ -z "$APK" ] || [ ! -f "$APK" ]; then skip "APK not found ('$APK') — build the debug APK first (see android-appium-e2e)"; fi

# --- authenticate (the SA key may arrive as a file path or inline JSON in GCP_SA_KEY) ----------
if [ -n "${GCP_SA_KEY:-}" ] && [ -z "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then
  KEYFILE="$DF_OUT/sa-key.json"
  if [ -f "$GCP_SA_KEY" ]; then cp "$GCP_SA_KEY" "$KEYFILE"; else printf '%s' "$GCP_SA_KEY" > "$KEYFILE"; fi
  chmod 600 "$KEYFILE"
  export GOOGLE_APPLICATION_CREDENTIALS="$KEYFILE"
fi
say "auth + project=$GCP_PROJECT"
gcloud auth activate-service-account --key-file="$GOOGLE_APPLICATION_CREDENTIALS"
gcloud config set project "$GCP_PROJECT"

RESULTS_DIR="canopy-df/$(date -u +%Y%m%dT%H%M%SZ)"
PERF_REMOTE="/sdcard/Android/data/$PKG/files/perf"

# --- 1+2. submit the smoke + perf sweep on a REAL Pixel ----------------------------------------
# The smoke leg is driven as a black-box Appium session against the held device; the perf leg pulls
# perf-android.sh's frame-metrics dump off the device via --directories-to-pull. The device is a real
# arm64 Pixel (model=$DF_DEVICE_MODEL), so the numbers are SHIPPABLE (not an emulator upper bound).
say "submit Firebase Test Lab run on $DF_DEVICE_MODEL/api$DF_DEVICE_VERSION (arm64, real device)"
set +e
gcloud firebase test android run \
  --type instrumentation \
  --app "$APK" \
  --device "model=$DF_DEVICE_MODEL,version=$DF_DEVICE_VERSION,locale=en,orientation=portrait" \
  --timeout 10m \
  --record-video \
  --directories-to-pull "$PERF_REMOTE" \
  --results-bucket "${GCP_PROJECT}-canopy-df" \
  --results-dir "$RESULTS_DIR" \
  --format=json > "$DF_OUT/firebase-run.json" 2> "$DF_OUT/firebase-run.log"
RUN_RC=$?
set -e
say "Test Lab run exit=$RUN_RC (console URL + video in firebase-run.json/.log)"

# --- pull the perf artifact from the results bucket --------------------------------------------
# Test Lab uploads the pulled directory to gs://<bucket>/<results-dir>/<device>/artifacts/...; copy
# the frame-metrics dump down so perf-report.js can gate it.
set +e
gcloud storage cp -r "gs://${GCP_PROJECT}-canopy-df/$RESULTS_DIR/**/frame-metrics.json" "$DF_OUT/" 2>>"$DF_OUT/firebase-run.log"
set -e

# --- 3. gate the perf trace (relative to the per-device baseline) ------------------------------
DUMP="$(find "$DF_OUT" -maxdepth 1 -name 'frame-metrics*.json' 2>/dev/null | head -1 || true)"
BASELINE="$ROOT/harness/perf-baselines/$DF_DEVICE_MODEL.json"
if [ -n "$DUMP" ] && command -v node >/dev/null 2>&1; then
  say "gate perf trace ($DUMP) vs baseline ${BASELINE}"
  if [ -f "$BASELINE" ]; then
    node "$ROOT/harness/perf-report.js" "$DUMP" --baseline "$BASELINE" | tee "$DF_OUT/perf-report.txt"
  else
    say "no baseline yet ($BASELINE) — printing the ledger to seed it (see docs/device-farm.md §7)"
    node "$ROOT/harness/perf-report.js" "$DUMP" | tee "$DF_OUT/perf-report.txt"
  fi
else
  say "no frame-metrics dump pulled (perf trace unavailable for this run) — smoke verdict stands alone"
fi

exit "$RUN_RC"
