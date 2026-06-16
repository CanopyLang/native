#!/usr/bin/env bash
# run-matrix.sh — the cross-PLATFORM device sweep: run the Appium E2E suite against each device in
# DEVICES and aggregate Android + iOS into ONE matrix report.
#
# E2E-2: the matrix now spans BOTH platforms. Each DEVICES entry is "<platform>:<device>" —
#   android:<AVD name>     boot the AVD (headless), drive it with the UIAutomator2 driver
#   ios:<simulator name>   boot the iOS simulator, drive it with the XCUITest driver  (NEEDS a Mac)
# A bare entry (no "<platform>:" prefix) defaults to android: for backward compatibility, so the old
# `DEVICES="canopy_echo Pixel_7_API_34"` invocation still means "those two AVDs". The SAME spec file
# runs on both platforms unchanged — selectors are the testID->accessibility-id contract (caps.mjs),
# never coordinates — which is the cross-platform thesis this sweep proves at the e2e layer.
#
# Examples:
#   DEVICES="android:canopy_echo" ./run-matrix.sh                       # one AVD (default)
#   DEVICES="android:canopy_echo ios:iPhone 15" ./run-matrix.sh         # Android + iOS (Mac)
#   SPEC=smoke.mjs DEVICES="ios:iPhone 15" ./run-matrix.sh              # the CI smoke flow on iOS
#
# For the default lumen-restore spec the Android leg also deploys the REAL Lumen app to the host's
# dev-override path so the installed host boots the actual Lumen program the spec drives. Set
# LUMEN_APP="" to skip that deploy (run against whatever bundle is already installed). The iOS leg
# drives whatever app is installed in the simulator (build it on the Mac first — see README/docs).
#
# Output: a per-entry line is appended to $MATRIX_JSONL and a human MATRIX REPORT (Markdown) is
# written to $MATRIX_REPORT at the end. The exit code is the number of failed device entries.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
DEVICES="${DEVICES:-android:canopy_echo}"
LUMEN_APP="${LUMEN_APP:-/home/quinten/projects/apps/lumen/app}"
SPEC="${SPEC:-lumen-restore.mjs}"
PKG=org.canopy.echo
ACT=com.canopyhost.MainActivity
ADB="${ADB:-adb}"
APPIUM_PORT="${APPIUM_PORT:-4723}"
# iOS: the built CanopyHost.app to (re)install in the simulator before the run (built on a Mac).
# Optional — leave empty to drive whatever app is already installed in the booted simulator.
IOS_APP="${IOS_APP:-}"
IOS_BUNDLE_ID="${IOS_BUNDLE_ID:-com.canopyhost.app}"

# The aggregated matrix outputs.
MATRIX_DIR="${MATRIX_DIR:-$ROOT/matrix-out}"
MATRIX_JSONL="${MATRIX_JSONL:-$MATRIX_DIR/results.jsonl}"
MATRIX_REPORT="${MATRIX_REPORT:-$MATRIX_DIR/matrix-report.md}"
mkdir -p "$MATRIX_DIR"
: > "$MATRIX_JSONL"

fails=0
total=0

# Resolve the appium binary: prefer the project-local install (npm ci), fall back to npx.
APPIUM_BIN="$ROOT/node_modules/.bin/appium"
[ -x "$APPIUM_BIN" ] || APPIUM_BIN="npx appium"

# Append one result row to the JSONL ledger the report is built from.
record() { # platform device spec rc started ended
  printf '{"platform":"%s","device":"%s","spec":"%s","rc":%s,"started":"%s","ended":"%s"}\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" >> "$MATRIX_JSONL"
}

start_appium() { # log-file
  $APPIUM_BIN --address 127.0.0.1 --port "$APPIUM_PORT" --relaxed-security >"$1" 2>&1 &
  APPIUM_PID=$!
  local ready=0
  for _ in $(seq 1 60); do
    if curl -fsS "http://127.0.0.1:$APPIUM_PORT/status" 2>/dev/null | grep -q '"ready"[[:space:]]*:[[:space:]]*true'; then
      ready=1; break
    fi
    sleep 1
  done
  [ "$ready" = "1" ] || { echo "    appium never became ready (see $1)"; return 1; }
}
stop_appium() { kill "${APPIUM_PID:-0}" 2>/dev/null || true; }

# --- one ANDROID device entry ---------------------------------------------------------------
run_android() { # avd
  local avd="$1" started ended rc
  started="$(date -u +%FT%TZ)"
  echo "==> android device: $avd"
  emulator -avd "$avd" -no-window -no-snapshot -gpu swiftshader_indirect >/dev/null 2>&1 &
  local EMU=$!
  "$ADB" wait-for-device
  until [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do sleep 2; done

  # Deploy the real Lumen bundle to the host's dev-override (only for the default lumen-restore spec).
  if [ -n "$LUMEN_APP" ] && [ "$SPEC" = "lumen-restore.mjs" ] && command -v canopy-native >/dev/null 2>&1; then
    echo "--> deploy Lumen bundle from $LUMEN_APP"
    if canopy-native build "$LUMEN_APP" >"/tmp/lumen-build-${avd}.log" 2>&1; then
      "$ADB" push "$LUMEN_APP/build/canopy.bundle.js" /data/local/tmp/canopy.bundle.js >/dev/null
      "$ADB" shell am force-stop "$PKG"; "$ADB" shell am start -n "$PKG/$ACT" >/dev/null
    else
      echo "    (Lumen build failed; see /tmp/lumen-build-${avd}.log — running against installed bundle)"
    fi
  fi

  start_appium "/tmp/appium-android-${avd}.log" || { record android "$avd" "$SPEC" 1 "$started" "$(date -u +%FT%TZ)"; kill "$EMU" 2>/dev/null; return 1; }
  echo "--> spec: $SPEC"
  ( cd "$ROOT" && E2E_PLATFORM=Android E2E_AUTOMATION=UiAutomator2 E2E_PORT="$APPIUM_PORT" node "$SPEC" )
  rc=$?
  # optional Maestro smoke: MAESTRO=1 with `maestro` on PATH.
  if [ "${MAESTRO:-0}" = "1" ] && command -v maestro >/dev/null 2>&1; then
    ( cd "$ROOT" && maestro test flows/lumen-restore.yaml ) || rc=$((rc + 1))
  fi
  ended="$(date -u +%FT%TZ)"
  stop_appium
  kill "$EMU" 2>/dev/null; "$ADB" kill-server 2>/dev/null || true
  record android "$avd" "$SPEC" "$rc" "$started" "$ended"
  return "$rc"
}

# --- one iOS device entry (XCUITest driver on a simulator) — NEEDS a Mac --------------------------
run_ios() { # simulator-name
  local sim="$1" started ended rc udid
  started="$(date -u +%FT%TZ)"
  echo "==> ios simulator: $sim"
  if ! command -v xcrun >/dev/null 2>&1; then
    echo "    xcrun not found — the iOS leg of the matrix needs a Mac with Xcode (skipping, recorded as failed)."
    record ios "$sim" "$SPEC" 1 "$started" "$(date -u +%FT%TZ)"
    return 1
  fi
  # Ensure the XCUITest driver is installed for Appium (idempotent — a no-op when already present).
  $APPIUM_BIN driver list --installed 2>/dev/null | grep -q xcuitest || \
    $APPIUM_BIN driver install xcuitest || true

  # Boot the simulator by name; capture its UDID so Appium targets exactly this device.
  udid="$(xcrun simctl list devices available | grep -F "$sim (" | head -1 | sed -E 's/.*\(([0-9A-Fa-f-]+)\).*/\1/')"
  if [ -z "$udid" ]; then
    echo "    no available simulator named '$sim' (xcrun simctl list devices) — recorded as failed."
    record ios "$sim" "$SPEC" 1 "$started" "$(date -u +%FT%TZ)"
    return 1
  fi
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b || true

  # (Re)install the freshly-built .app so the simulator runs THIS commit's host + bundle.
  if [ -n "$IOS_APP" ]; then
    echo "--> install $IOS_APP into $sim ($udid)"
    xcrun simctl install "$udid" "$IOS_APP" || true
  fi

  # L-I6: for the lumen-restore spec, seed the draw-safe fixture into the Simulator's photo library —
  # the iOS twin of the Android leg's gallery seed (prepareGalleryFixtureAndroid). It is the
  # byte-identical fixture; the picker is newest-first so this makes the pick step deterministic AND
  # keeps the restore output under the on-screen compositor's draw limit. (Embedding the actual LUMEN
  # bundle as canopy.bundle.js is a build-time step done before $IOS_APP is built — see
  # host/ios/BUILD-AND-VALIDATE.md §5.8; this leg only seeds the runtime photo fixture.)
  if [ "$SPEC" = "lumen-restore.mjs" ]; then
    LUMEN_FIXTURE="${LUMEN_FIXTURE:-$ROOT/../host/ios/Tests/CanopyHostUITests/Fixtures/lumen-test.jpg}"
    if [ -f "$LUMEN_FIXTURE" ]; then
      echo "--> seed lumen fixture into $sim photo library: $LUMEN_FIXTURE"
      xcrun simctl addmedia "$udid" "$LUMEN_FIXTURE" || true
    else
      echo "    (lumen fixture not found at $LUMEN_FIXTURE — running against the pre-seeded library)"
    fi
  fi

  start_appium "/tmp/appium-ios-${sim// /_}.log" || { record ios "$sim" "$SPEC" 1 "$started" "$(date -u +%FT%TZ)"; xcrun simctl shutdown "$udid" 2>/dev/null || true; return 1; }
  echo "--> spec: $SPEC"
  ( cd "$ROOT" && E2E_PLATFORM=iOS E2E_AUTOMATION=XCUITest E2E_UDID="$udid" E2E_DEVICE="$sim" \
      E2E_BUNDLE_ID="$IOS_BUNDLE_ID" ${IOS_APP:+E2E_APP="$IOS_APP"} E2E_PORT="$APPIUM_PORT" node "$SPEC" )
  rc=$?
  # optional Maestro smoke on iOS (maestro speaks XCUITest too).
  if [ "${MAESTRO:-0}" = "1" ] && command -v maestro >/dev/null 2>&1; then
    ( cd "$ROOT" && maestro test flows/lumen-restore.yaml ) || rc=$((rc + 1))
  fi
  ended="$(date -u +%FT%TZ)"
  stop_appium
  xcrun simctl shutdown "$udid" 2>/dev/null || true
  record ios "$sim" "$SPEC" "$rc" "$started" "$ended"
  return "$rc"
}

# --- the sweep -----------------------------------------------------------------------------------
# DEVICES is a space list of "<platform>:<device>"; an iOS simulator name may itself contain spaces
# (e.g. "iPhone 15"), so we segment on the platform-token boundaries rather than plain word-splitting.
# A PREFIXED entry ("ios:iPhone 15") absorbs following bare tokens as its multi-word device name; a
# BARE token that is not a continuation is its own android entry — which preserves the legacy form
# `DEVICES="canopy_echo Pixel_7_API_34"` meaning "two AVDs", not one two-word name.
read -r -a TOKENS <<< "$DEVICES"
entry=""
platform=""
prefixed=0     # 1 once an explicit android:/ios: prefix opened the current entry (enables continuation)
flush() {
  [ -n "$platform" ] || return 0
  total=$((total + 1))
  local dev="${entry# }"
  case "$platform" in
    android) run_android "$dev" || fails=$((fails + 1)) ;;
    ios)     run_ios "$dev"     || fails=$((fails + 1)) ;;
    *)       echo "!! unknown platform '$platform' for '$dev' — skipping"; fails=$((fails + 1)) ;;
  esac
  entry=""; platform=""; prefixed=0
}
for tok in "${TOKENS[@]}"; do
  case "$tok" in
    android:*) flush; platform=android; entry="${tok#android:}"; prefixed=1 ;;
    ios:*)     flush; platform=ios;     entry="${tok#ios:}";     prefixed=1 ;;
    *)
      if [ "$prefixed" = "1" ]; then
        # A continuation of an explicitly-prefixed multi-word device name (e.g. "ios:iPhone 15").
        entry="$entry $tok"
      else
        # A bare token (legacy form) => its OWN android entry; each AVD name stands alone.
        flush; platform=android; entry="$tok"; prefixed=0
      fi
      ;;
  esac
done
flush

# --- aggregate into ONE matrix report ------------------------------------------------------------
# Build the Markdown report from the JSONL ledger with a tiny Node reader (no jq dependency). This is
# the E2E-2 deliverable: Android + iOS results in one table, with a combined PASS/FAIL verdict.
node "$ROOT/matrix-report.mjs" "$MATRIX_JSONL" "$MATRIX_REPORT" || true

echo
echo "==> matrix done: $((total - fails))/$total device entries passed"
echo "==> report: $MATRIX_REPORT"
[ -f "$MATRIX_REPORT" ] && cat "$MATRIX_REPORT"
exit "$fails"
