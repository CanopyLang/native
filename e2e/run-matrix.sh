#!/usr/bin/env bash
# run-matrix.sh — boot each AVD and run the Appium E2E suite against it (the device sweep).
# Usage: DEVICES="canopy_echo Pixel_7_API_34" ./run-matrix.sh
#
# For the default lumen-restore spec this also deploys the REAL Lumen app onto the host: it builds
# the Lumen bundle and pushes it to the host's dev-override path (/data/local/tmp/canopy.bundle.js),
# so the installed org.canopy.echo host boots the actual Lumen program the spec drives. Set
# LUMEN_APP="" to skip the deploy (run against whatever bundle is already installed).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
DEVICES="${DEVICES:-canopy_echo}"
LUMEN_APP="${LUMEN_APP:-/home/quinten/projects/apps/lumen/app}"
PKG=org.canopy.echo
ACT=com.canopyhost.MainActivity
fails=0
for avd in $DEVICES; do
  echo "==> device: $avd"
  emulator -avd "$avd" -no-window -no-snapshot -gpu swiftshader_indirect >/dev/null 2>&1 &
  EMU=$!
  adb wait-for-device
  until [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do sleep 2; done
  # Deploy the real Lumen bundle to the host's dev-override so the spec drives the actual app.
  if [ -n "$LUMEN_APP" ] && command -v canopy-native >/dev/null 2>&1; then
    echo "--> deploy Lumen bundle from $LUMEN_APP"
    if canopy-native build "$LUMEN_APP" >/tmp/lumen-build-$avd.log 2>&1; then
      adb push "$LUMEN_APP/build/canopy.bundle.js" /data/local/tmp/canopy.bundle.js >/dev/null
      adb shell am force-stop "$PKG"; adb shell am start -n "$PKG/$ACT" >/dev/null
    else
      echo "    (Lumen build failed; see /tmp/lumen-build-$avd.log — running against installed bundle)"
    fi
  fi
  nohup npx appium --address 127.0.0.1 --port 4723 --relaxed-security >/tmp/appium-$avd.log 2>&1 &
  AP=$!
  until curl -s http://127.0.0.1:4723/status 2>/dev/null | grep -q '"ready"'; do sleep 1; done
  # Which spec(s) to run this sweep. Default = the real Lumen restore flow.
  SPEC="${SPEC:-lumen-restore.mjs}"
  for spec in $SPEC; do
    echo "--> spec: $spec"
    ( cd "$ROOT" && node "$spec" ) || fails=$((fails+1))
  done
  # optional Maestro smoke: MAESTRO=1 with `maestro` on PATH
  if [ "${MAESTRO:-0}" = "1" ] && command -v maestro >/dev/null 2>&1; then
    ( cd "$ROOT" && maestro test flows/lumen-restore.yaml ) || fails=$((fails+1))
  fi
  kill $AP $EMU 2>/dev/null; adb kill-server 2>/dev/null
done
echo "==> matrix done; $fails device(s) failed"
exit $fails
