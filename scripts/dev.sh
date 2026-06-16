#!/usr/bin/env bash
# dev.sh — Canopy Native hot-reload dev loop (the Metro fast-refresh equivalent).
#
# Three modes:
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
#     This mode dials the host over `adb reverse` (USB/emulator), so the device reaches the
#     server at its loopback (127.0.0.1 / the emulator alias 10.0.2.2).
#
#  3. WS DEV SERVER OVER LAN / WI-FI (--lan [--host IP], DEV-7): the same WS dev server, but
#     reachable over the local network instead of through `adb reverse`. The owner's box often
#     runs remote (a desktop on the LAN, a remote build box), and a Metro-class loop must work
#     over Wi-Fi, not just USB/emulator. This mode:
#       - resolves the box's LAN IP (auto-detected, or `--host IP` to pin it),
#       - binds the WS server to 0.0.0.0 so a device on the LAN can reach it,
#       - bakes that IP:PORT into every attached device via
#           `adb shell setprop debug.canopy.devhost <IP>:<PORT>`,
#         which CanopyDevBootstrap reads first — so the on-device CanopyDevClient dials the box
#         straight over Wi-Fi (NO `adb reverse` tunnel),
#       - does NOT run `adb reverse` (the whole point: no USB tether needed).
#     The on-device cleartext allowlist (CanopyDevClient.isCleartextAllowed) + the debug
#     network_security_config still scope the ws:// to localhost/private-LAN only, so a public
#     IP is refused even if one were mis-passed.
#
# Usage:  ./scripts/dev.sh <app-dir>                       one-shot build + push-to-device
#         ./scripts/dev.sh <app-dir> --watch               rebuild+push-to-device on every src change
#         ./scripts/dev.sh <app-dir> --server [...]         WS dev server over adb-reverse (USB/emulator)
#                                                           extra args pass through to the server,
#                                                           e.g. --server --port 8099
#         ./scripts/dev.sh <app-dir> --lan [--host IP] [--port N] [...]
#                                                           WS dev server over LAN/Wi-Fi (DEV-7):
#                                                           binds 0.0.0.0, setprops the device with the
#                                                           box's LAN IP, no adb reverse
#         adb shell rm /data/local/tmp/canopy.bundle.js     # stop hot-reload, return to baked bundle
set -euo pipefail
APP="${1:?usage: dev.sh <app-dir> [--watch|--server|--lan]}"
MODE="${2:-}"
PKG=org.canopy.echo
ACT=com.canopyhost.MainActivity

HERE="$(cd "$(dirname "$0")" && pwd)"
SERVER="$HERE/../tool/canopy-dev-server.js"
# Prefer the env-provided adb, then the project's pinned platform-tools, then PATH.
ADB="${ADB:-}"
if [ -z "$ADB" ]; then
  if [ -x "/home/quinten/android-tools/sdk/platform-tools/adb" ]; then
    ADB="/home/quinten/android-tools/sdk/platform-tools/adb"
  else
    ADB="adb"
  fi
fi

# --- LAN IP resolution (DEV-7) ----------------------------------------------
# Resolve the box's primary LAN (RFC-1918) IPv4 address — the one a device on the same Wi-Fi
# would route to. `ip route get` picks the source address of the default route (the interface
# that reaches the internet), which is exactly the address a LAN peer dials. Falls back to the
# first private address from `hostname -I`. Prints the IP on stdout, or exits non-zero if none.
resolve_lan_ip() {
  local ip=""
  if command -v ip >/dev/null 2>&1; then
    ip="$(ip route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}' | head -1 || true)"
  fi
  if [ -z "$ip" ] && command -v hostname >/dev/null 2>&1; then
    # Pick the first RFC-1918 address from the space-separated list `hostname -I` prints.
    for cand in $(hostname -I 2>/dev/null || true); do
      case "$cand" in
        10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) ip="$cand"; break ;;
      esac
    done
  fi
  if [ -z "$ip" ]; then return 1; fi
  printf '%s\n' "$ip"
}

# True iff $1 is a private/loopback IPv4 the dev loop's cleartext allowlist accepts (mirrors
# CanopyDevClient.isCleartextAllowed so the script refuses a public IP before setprop'ing it).
is_private_ip() {
  case "$1" in
    127.*|10.*|192.168.*|169.254.*) return 0 ;;
    172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0 ;;
    *) return 1 ;;
  esac
}

# --- WS dev-server modes ----------------------------------------------------
# --server : reach the server through adb reverse (USB/emulator loopback).
if [ "$MODE" = "--server" ]; then
  shift 2 || shift $#   # drop <app-dir> + --server; the rest are server flags
  echo "==> canopy dev server on $(basename "$APP")  (adb-reverse / USB+emulator, Ctrl-C to stop)"
  exec node "$SERVER" "$APP" "$@"
fi

# --lan : reach the server over the LAN/Wi-Fi (DEV-7). Bind 0.0.0.0, setprop the device, no reverse.
if [ "$MODE" = "--lan" ]; then
  shift 2 || shift $#   # drop <app-dir> + --lan; parse the LAN-specific flags, pass the rest through
  PORT=8099
  LAN_IP=""
  PASS=()               # flags forwarded to the dev server (everything that isn't --host)
  while [ $# -gt 0 ]; do
    case "$1" in
      --host) LAN_IP="${2:?--host needs an IP}"; shift 2 ;;
      --port) PORT="${2:?--port needs a value}"; PASS+=(--port "$2"); shift 2 ;;
      *)      PASS+=("$1"); shift ;;
    esac
  done

  # Resolve the IP the device should dial: explicit --host, else auto-detect this box's LAN IP.
  if [ -z "$LAN_IP" ]; then
    if ! LAN_IP="$(resolve_lan_ip)"; then
      echo "dev.sh --lan: could not auto-detect a LAN IP; pass one explicitly with --host <ip>" >&2
      exit 1
    fi
    echo "==> auto-detected LAN IP: $LAN_IP  (override with --host <ip>)"
  fi

  if ! is_private_ip "$LAN_IP"; then
    echo "dev.sh --lan: '$LAN_IP' is not a private/LAN address — the dev loop only dials" >&2
    echo "             localhost/RFC-1918 hosts (matches CanopyDevClient.isCleartextAllowed)." >&2
    exit 1
  fi

  DEVHOST="$LAN_IP:$PORT"

  # Bake the LAN endpoint into every attached device so CanopyDevBootstrap dials it over Wi-Fi.
  # (setprop is read FIRST in CanopyDevBootstrap.resolveDevHost, ahead of the manifest meta-data,
  #  so this overrides the baked-in/default 10.0.2.2 with no rebuild.) Non-fatal if no device is
  #  attached over adb — a Wi-Fi-only device can still pick the value up if it was setprop'd once,
  #  or the manifest meta-data can carry it.
  DEVICES="$("$ADB" devices 2>/dev/null | awk 'NR>1 && $2=="device"{print $1}' || true)"
  if [ -n "$DEVICES" ]; then
    for d in $DEVICES; do
      echo "==> point $d at the LAN dev server: debug.canopy.devhost=$DEVHOST"
      "$ADB" -s "$d" shell setprop debug.canopy.devhost "$DEVHOST" >/dev/null 2>&1 || \
        echo "    (setprop on $d failed — non-fatal; the device can still read CANOPY_DEV_HOST meta-data)"
    done
  else
    echo "==> no adb-attached device; the device must read debug.canopy.devhost=$DEVHOST itself"
    echo "    (e.g. \`adb -s <device> shell setprop debug.canopy.devhost $DEVHOST\`, or bake it via"
    echo "     \`canopy-native run --host $LAN_IP\`)."
  fi

  echo "==> canopy dev server on $(basename "$APP")  (LAN/Wi-Fi @ $DEVHOST, bind 0.0.0.0, Ctrl-C to stop)"
  # Bind 0.0.0.0 so a device on the LAN can reach the WS server (loopback bind would be unreachable).
  exec node "$SERVER" "$APP" --host 0.0.0.0 "${PASS[@]}"
fi

# --- push-to-device mode ----------------------------------------------------
reload() {
  echo "==> build $(basename "$APP")"
  if ! canopy-native build "$APP" >/tmp/canopy-dev.log 2>&1; then tail -20 /tmp/canopy-dev.log; return 1; fi
  # RNV-7: prefer the real Hermes .hbc bundle when the build emitted one (hermesc available) — the
  # host boots its bytecode directly. Push to the matching override name; clear the other so a stale
  # one doesn't shadow it (readBundleBytes prefers .hbc, then .js). Fall back to the JS bundle.
  if [ -f "$APP/build/canopy.bundle.hbc" ]; then
    "$ADB" push "$APP/build/canopy.bundle.hbc" /data/local/tmp/canopy.bundle.hbc >/dev/null
    "$ADB" shell rm -f /data/local/tmp/canopy.bundle.js >/dev/null 2>&1 || true
  else
    "$ADB" push "$APP/build/canopy.bundle.js" /data/local/tmp/canopy.bundle.js >/dev/null
    "$ADB" shell rm -f /data/local/tmp/canopy.bundle.hbc >/dev/null 2>&1 || true
  fi
  "$ADB" shell am force-stop "$PKG"
  "$ADB" shell am start -n "$PKG/$ACT" >/dev/null
  echo "==> reloaded $(date +%H:%M:%S)"
}

reload
if [ "$MODE" = "--watch" ]; then
  echo "==> watching $APP/src (Ctrl-C to stop)"
  while inotifywait -e modify,create,delete -r "$APP/src" >/dev/null 2>&1; do reload || true; done
fi
