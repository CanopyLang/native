#!/usr/bin/env bash
# run-appium-ci.sh — boot Appium and run the smoke spec against an ALREADY-BOOTED emulator/app, then
# tear Appium down — the body of the E2E-1 CI emulator job, factored out of ci.yml so it can be run
# unchanged on the dev box (against the live AVD) and in CI (inside android-emulator-runner's
# `script:`, where the AVD is up). It captures the Appium server log to $APPIUM_LOG so a failing run
# is diagnosable from the uploaded artifact.
#
# PRECONDITIONS (the caller provides these):
#   • an Android emulator is booted and `adb` sees it (the emulator-runner action guarantees this);
#   • the host debug APK (org.canopy.echo) is installed — this script installs $APK if it is set;
#   • node + the e2e npm deps are installed (npm ci in e2e/), with appium + uiautomator2 driver.
#
# Env:
#   APK         path to the debug APK to (re)install before the run            (optional)
#   SPEC        the e2e spec to run                       (default: smoke.mjs)
#   APPIUM_LOG  where to tee the Appium server log         (default: /tmp/appium.log)
#   ADB         adb binary                                          (default: adb)
#   APPIUM_PORT Appium server port                                  (default: 4723)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SPEC="${SPEC:-smoke.mjs}"
APPIUM_LOG="${APPIUM_LOG:-/tmp/appium.log}"
ADB="${ADB:-adb}"
APPIUM_PORT="${APPIUM_PORT:-4723}"

cd "$HERE"

# Resolve the appium binary: prefer the project-local install (npm ci), fall back to npx.
APPIUM_BIN="$HERE/node_modules/.bin/appium"
[ -x "$APPIUM_BIN" ] || APPIUM_BIN="npx appium"

echo "==> e2e: installed appium drivers"
$APPIUM_BIN driver list --installed || true

# (Re)install the freshly-built debug APK so the emulator runs THIS commit's host + bundle.
if [ -n "${APK:-}" ]; then
  echo "==> e2e: installing APK $APK"
  "$ADB" install -r -g "$APK"
fi

# Start the Appium server, tee its log for the artifact, wait until it is ready.
echo "==> e2e: starting appium on 127.0.0.1:$APPIUM_PORT (log → $APPIUM_LOG)"
$APPIUM_BIN --address 127.0.0.1 --port "$APPIUM_PORT" --relaxed-security >"$APPIUM_LOG" 2>&1 &
APPIUM_PID=$!
# shellcheck disable=SC2317  # reached only via the EXIT trap below, not inline.
cleanup() { kill "$APPIUM_PID" 2>/dev/null || true; }
trap cleanup EXIT

ready=0
for _ in $(seq 1 60); do
  if curl -fsS "http://127.0.0.1:$APPIUM_PORT/status" 2>/dev/null | grep -q '"ready"[[:space:]]*:[[:space:]]*true'; then
    ready=1; break
  fi
  sleep 1
done
if [ "$ready" != "1" ]; then
  echo "::error::Appium server never became ready — see $APPIUM_LOG"
  tail -n 60 "$APPIUM_LOG" || true
  exit 1
fi
echo "==> e2e: appium ready"

# Run the smoke spec. forceAppLaunch in the spec gives a clean foreground launch each run.
echo "==> e2e: running spec $SPEC"
set +e
E2E_PORT="$APPIUM_PORT" node "$SPEC"
rc=$?
set -e

echo "==> e2e: spec exit $rc (appium log tail follows)"
tail -n 25 "$APPIUM_LOG" || true
exit "$rc"
