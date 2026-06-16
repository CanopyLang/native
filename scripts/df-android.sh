#!/usr/bin/env bash
# df-android.sh — DF-1: submit the Android nightly device-farm sweep (smoke + perf trace) on a REAL
# arm64 device, dispatching to the configured provider. This is the real-device complement to the
# emulator job android-appium-e2e (E2E-1): it runs the SAME e2e/smoke.mjs spec body, plus the
# perf-android.sh frame-metrics capture, but on physical arm64 silicon in a managed farm — because an
# x86_64 emulator is an UPPER BOUND on jank, never a floor (no GPU-compositor parity). See
# docs/device-farm.md for the full strategy.
#
# Provider dispatch (DF_PROVIDER):
#   firebase  (default)  -> df-firebase.sh   — Firebase Test Lab (real Pixel/arm64, --directories-to-pull)
#   aws                  -> df-aws.sh android — AWS Device Farm (unified fallback)
#
# This script is the stable entry point the CI job (device-farm-android) and a dev box both call; the
# provider scripts carry the provider-specific CLI. It SELF-SKIPS with a clear, non-fatal message when
# the provider CLI/credential is absent, so it is safe to invoke on a box with no farm account (this
# sandbox) — the CI job is continue-on-error + secret-gated for the same reason.
#
# Env:
#   DF_PROVIDER        firebase | aws                              (default: firebase)
#   APK                path to the debug APK to install on the device   (required for a real run)
#   DF_DEVICE_MODEL    farm device model id (Firebase: e.g. oriole=Pixel 6)   (default: oriole)
#   DF_DEVICE_VERSION  Android API level on the device                  (default: 34)
#   DF_OUT             output dir for artifacts                  (default: df-out/android)
#   DF_REQUIRE         "1" => a missing provider CLI/credential is a HARD failure (CI flip; default 0)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

DF_PROVIDER="${DF_PROVIDER:-firebase}"
DF_OUT="${DF_OUT:-$ROOT/df-out/android}"
DF_REQUIRE="${DF_REQUIRE:-0}"
export DF_OUT DF_REQUIRE

mkdir -p "$DF_OUT"

say() { echo "==> df-android: $*"; }

# A clean, non-fatal skip when no account is wired (unless DF_REQUIRE=1 — the CI flip to required).
skip() {
  echo "::notice::df-android SKIP — $1" 2>/dev/null || echo "df-android SKIP — $1"
  if [ "$DF_REQUIRE" = "1" ]; then
    echo "::error::DF_REQUIRE=1 but the device farm could not run: $1" 2>/dev/null || echo "ERROR (DF_REQUIRE=1): $1"
    exit 1
  fi
  exit 0
}
export -f skip
export -f say

say "provider=$DF_PROVIDER device=${DF_DEVICE_MODEL:-oriole}/api${DF_DEVICE_VERSION:-34} out=$DF_OUT"

case "$DF_PROVIDER" in
  firebase) exec bash "$HERE/df-firebase.sh" ;;
  aws)      exec bash "$HERE/df-aws.sh" android ;;
  *) echo "::error::unknown DF_PROVIDER='$DF_PROVIDER' (want: firebase|aws)"; exit 2 ;;
esac
