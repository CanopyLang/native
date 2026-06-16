#!/usr/bin/env bash
# run-appium-ios.sh — the iOS twin of run-appium-ci.sh: boot a simulator, install the built
# CanopyHost.app, start Appium with the XCUITest driver, run an e2e spec, tear Appium down. This is
# the body of the E2E-2 iOS Appium leg, factored out of ci.yml so it runs UNCHANGED on a Mac dev box
# and inside the macOS CI job. NEEDS a Mac with Xcode (xcrun/simctl + the XCUITest driver) — there is
# no Mac on the Linux dev box, so this script is authored + shellcheck-clean here and runs on a Mac.
#
# It drives the SAME spec the Android CI leg runs (default smoke.mjs — the canonical examples/counter
# flow) purely through the testID->accessibility-id contract, so a green run here proves the iOS host
# boot path (Scene -> host VC -> Hermes -> bundle eval -> first render -> a real tap dispatching a TEA
# update) the same way the Android emulator leg proves it — the cross-platform thesis at the e2e layer.
#
# PRECONDITIONS (the caller provides these):
#   • a Mac with Xcode (xcrun simctl, the iOS runtime for $SIM_NAME);
#   • the app is built for the simulator — pass its .app via APP=… (this script installs it), or have
#     it already installed in the booted simulator;
#   • node + the e2e npm deps (npm ci in e2e/) with appium + the xcuitest driver.
#
# Env:
#   APP          path to CanopyHost.app to (re)install before the run            (optional)
#   SIM_NAME     simulator device name to boot                  (default: "iPhone 15")
#   BUNDLE_ID    the app's bundle id                       (default: com.canopyhost.app)
#   SPEC         the e2e spec to run                              (default: smoke.mjs)
#   APPIUM_LOG   where to tee the Appium server log              (default: /tmp/appium-ios.log)
#   APPIUM_PORT  Appium server port                                       (default: 4723)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SIM_NAME="${SIM_NAME:-iPhone 15}"
BUNDLE_ID="${BUNDLE_ID:-com.canopyhost.app}"
SPEC="${SPEC:-smoke.mjs}"
APPIUM_LOG="${APPIUM_LOG:-/tmp/appium-ios.log}"
APPIUM_PORT="${APPIUM_PORT:-4723}"

cd "$HERE"

if ! command -v xcrun >/dev/null 2>&1; then
  echo "::error::xcrun not found — run-appium-ios.sh needs a Mac with Xcode (the iOS e2e leg, E2E-2)."
  exit 1
fi

# Resolve the appium binary: prefer the project-local install (npm ci), fall back to npx.
APPIUM_BIN="$HERE/node_modules/.bin/appium"
[ -x "$APPIUM_BIN" ] || APPIUM_BIN="npx appium"

echo "==> ios-e2e: installed appium drivers"
$APPIUM_BIN driver list --installed || true
# Ensure the XCUITest driver is present (idempotent — a no-op when already installed).
$APPIUM_BIN driver list --installed 2>/dev/null | grep -q xcuitest || $APPIUM_BIN driver install xcuitest

# Boot the simulator by name and capture its UDID so Appium targets exactly this device.
UDID="$(xcrun simctl list devices available | grep -F "$SIM_NAME (" | head -1 | sed -E 's/.*\(([0-9A-Fa-f-]+)\).*/\1/')"
if [ -z "$UDID" ]; then
  echo "::error::no available simulator named '$SIM_NAME' — create it or set SIM_NAME (xcrun simctl list devices)."
  exit 1
fi
echo "==> ios-e2e: booting simulator $SIM_NAME ($UDID)"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b || true

# (Re)install the freshly-built .app so the simulator runs THIS commit's host + bundle.
if [ -n "${APP:-}" ]; then
  echo "==> ios-e2e: installing $APP"
  xcrun simctl install "$UDID" "$APP"
fi

# L-I6: for the lumen-restore spec, seed the draw-safe fixture into the photo library (the iOS twin of
# the Android gallery seed). Byte-identical fixture; newest-first picker → a deterministic, draw-safe
# pick. (Embedding the LUMEN bundle as canopy.bundle.js is a build-time step before APP is built — see
# host/ios/BUILD-AND-VALIDATE.md §5.8.) Override the fixture path via LUMEN_FIXTURE=…
if [ "$SPEC" = "lumen-restore.mjs" ]; then
  LUMEN_FIXTURE="${LUMEN_FIXTURE:-$HERE/../host/ios/Tests/CanopyHostUITests/Fixtures/lumen-test.jpg}"
  if [ -f "$LUMEN_FIXTURE" ]; then
    echo "==> ios-e2e: seeding lumen fixture into the photo library: $LUMEN_FIXTURE"
    xcrun simctl addmedia "$UDID" "$LUMEN_FIXTURE" || true
  else
    echo "==> ios-e2e: lumen fixture not found at $LUMEN_FIXTURE — running against the pre-seeded library"
  fi
fi

# Start the Appium server, tee its log for the artifact, wait until it is ready.
echo "==> ios-e2e: starting appium on 127.0.0.1:$APPIUM_PORT (log → $APPIUM_LOG)"
$APPIUM_BIN --address 127.0.0.1 --port "$APPIUM_PORT" --relaxed-security >"$APPIUM_LOG" 2>&1 &
APPIUM_PID=$!
# shellcheck disable=SC2317  # reached only via the EXIT trap below, not inline.
cleanup() { kill "$APPIUM_PID" 2>/dev/null || true; xcrun simctl shutdown "$UDID" 2>/dev/null || true; }
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
echo "==> ios-e2e: appium ready"

# Run the spec with the iOS capabilities (caps.mjs reads these env vars). forceAppLaunch in the caps
# gives a clean foreground launch each run.
echo "==> ios-e2e: running spec $SPEC on $SIM_NAME"
set +e
E2E_PLATFORM=iOS E2E_AUTOMATION=XCUITest E2E_UDID="$UDID" E2E_DEVICE="$SIM_NAME" \
  E2E_BUNDLE_ID="$BUNDLE_ID" ${APP:+E2E_APP="$APP"} E2E_PORT="$APPIUM_PORT" node "$SPEC"
rc=$?
set -e

echo "==> ios-e2e: spec exit $rc (appium log tail follows)"
tail -n 25 "$APPIUM_LOG" || true
exit "$rc"
