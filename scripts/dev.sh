#!/usr/bin/env bash
# dev.sh — Canopy Native hot-reload dev loop (the Metro fast-refresh equivalent).
#
# Two modes:
#
#  1. PUSH-TO-DEVICE (default): edit a .can file, see it on the device in ~3s with NO
#     gradle/install (the slow part): rebuild the JS bundle, push it to the device's
#     dev-override path (/data/local/tmp), and restart the app — MainActivity.readBundle()
#     boots the pushed bundle when present. Requires the host APK already installed once
#     (any build). A release build ignores the override.
#
#  2. WS DEV SERVER (--server): run tool/canopy-dev-server.js — a zero-dependency Node
#     dev server (DEV-5) that watches the app's .can/native.js sources, debounces a burst
#     of saves, runs `canopy-native build`, and PUSHES the freshly-assembled bundle over a
#     WebSocket to every connected host. Content-addressed: an edit whose output buildId is
#     unchanged short-circuits (no bundle re-sent). This is the push side a host attaches to
#     for live reload, replacing the per-edit adb-push poll loop with a single warm server.
#
# Usage:  ./scripts/dev.sh <app-dir>                 one-shot build + push-to-device
#         ./scripts/dev.sh <app-dir> --watch         rebuild+push-to-device on every src change
#         ./scripts/dev.sh <app-dir> --server [...]   start the WS dev server (watch + WS push)
#                                                      extra args pass through to the server,
#                                                      e.g. --server --port 8099 --host 0.0.0.0
#         adb shell rm /data/local/tmp/canopy.bundle.js   # stop hot-reload, return to baked bundle
set -euo pipefail
APP="${1:?usage: dev.sh <app-dir> [--watch|--server]}"
MODE="${2:-}"
PKG=org.canopy.echo
ACT=com.canopyhost.MainActivity

# --- WS dev-server mode -----------------------------------------------------
if [ "$MODE" = "--server" ]; then
  HERE="$(cd "$(dirname "$0")" && pwd)"
  SERVER="$HERE/../tool/canopy-dev-server.js"
  shift 2 || shift $#   # drop <app-dir> + --server; the rest are server flags
  echo "==> canopy dev server on $(basename "$APP")  (Ctrl-C to stop)"
  exec node "$SERVER" "$APP" "$@"
fi

# --- push-to-device mode ----------------------------------------------------
reload() {
  echo "==> build $(basename "$APP")"
  if ! canopy-native build "$APP" >/tmp/canopy-dev.log 2>&1; then tail -20 /tmp/canopy-dev.log; return 1; fi
  # RNV-7: prefer the real Hermes .hbc bundle when the build emitted one (hermesc available) — the
  # host boots its bytecode directly. Push to the matching override name; clear the other so a stale
  # one doesn't shadow it (readBundleBytes prefers .hbc, then .js). Fall back to the JS bundle.
  if [ -f "$APP/build/canopy.bundle.hbc" ]; then
    adb push "$APP/build/canopy.bundle.hbc" /data/local/tmp/canopy.bundle.hbc >/dev/null
    adb shell rm -f /data/local/tmp/canopy.bundle.js >/dev/null 2>&1 || true
  else
    adb push "$APP/build/canopy.bundle.js" /data/local/tmp/canopy.bundle.js >/dev/null
    adb shell rm -f /data/local/tmp/canopy.bundle.hbc >/dev/null 2>&1 || true
  fi
  adb shell am force-stop "$PKG"
  adb shell am start -n "$PKG/$ACT" >/dev/null
  echo "==> reloaded $(date +%H:%M:%S)"
}

reload
if [ "$MODE" = "--watch" ]; then
  echo "==> watching $APP/src (Ctrl-C to stop)"
  while inotifywait -e modify,create,delete -r "$APP/src" >/dev/null 2>&1; do reload || true; done
fi
