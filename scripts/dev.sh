#!/usr/bin/env bash
# dev.sh — Canopy Native hot-reload dev loop (the Metro fast-refresh equivalent).
#
# Edit a .can file, see it on the device in ~3s with NO gradle/install (the slow part): rebuild
# the JS bundle, push it to the device's dev-override path (/data/local/tmp), and restart the app
# — MainActivity.readBundle() boots the pushed bundle when present. Requires the host APK already
# installed once (any build). A release build ignores the override.
#
# Usage:  ./scripts/dev.sh <app-dir>           one-shot reload
#         ./scripts/dev.sh <app-dir> --watch   rebuild+push on every src change (needs inotifywait)
#         adb shell rm /data/local/tmp/canopy.bundle.js   # stop hot-reload, return to baked bundle
set -euo pipefail
APP="${1:?usage: dev.sh <app-dir> [--watch]}"
PKG=org.canopy.echo
ACT=com.canopyhost.MainActivity

reload() {
  echo "==> build $(basename "$APP")"
  if ! canopy-native build "$APP" >/tmp/canopy-dev.log 2>&1; then tail -20 /tmp/canopy-dev.log; return 1; fi
  adb push "$APP/build/canopy.bundle.js" /data/local/tmp/canopy.bundle.js >/dev/null
  adb shell am force-stop "$PKG"
  adb shell am start -n "$PKG/$ACT" >/dev/null
  echo "==> reloaded $(date +%H:%M:%S)"
}

reload
if [ "${2:-}" = "--watch" ]; then
  echo "==> watching $APP/src (Ctrl-C to stop)"
  while inotifywait -e modify,create,delete -r "$APP/src" >/dev/null 2>&1; do reload || true; done
fi
