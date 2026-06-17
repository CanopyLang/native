#!/usr/bin/env bash
# ios-device.sh — PATH B: the LINUX half of on-device iOS testing.
#
# Compiling + signing an iOS .ipa needs a Mac (GitHub macOS CI, or a Mac driven by
# host/ios/remote-build.sh). Everything AFTER that — discovering the iPhone, registering it
# with Apple, installing the .ipa, and reading device logs — runs on THIS Linux box via
# libimobiledevice. This script is that half. See docs/ios-device-testing-linux.md.
#
# Subcommands:
#   doctor                 check the toolchain + that a trusted iPhone is connected
#   udid                   print the connected iPhone's UDID (what Apple needs to provision it)
#   register [--name N]    register the UDID with Apple via the App Store Connect API (one-time)
#   fetch [--lane L] [--run ID]
#                          download the signed .ipa artifact from the latest GitHub Actions run
#   install [IPA]          install an .ipa onto the connected iPhone (default: the fetched one)
#   logs [--bundle ID]     stream device syslog, filtered to the app (Ctrl-C to stop)
#   run [--lane L] [IPA]   fetch (if no IPA) + install + tail logs — the one-shot loop
#
# Lanes (match the CI/remote-build export methods):
#   adhoc        release-testing signed (production entitlements) — installs, idevicesyslog logs
#   development  development signed (get-task-allow=true) — also lldb-attachable
#
# Env (for `register` and `fetch`):
#   ASC_KEY_ID, ASC_ISSUER_ID   App Store Connect API key id + issuer (same as CI secrets)
#   ASC_API_KEY_P8              path to the AuthKey_<KeyID>.p8 (or its PEM contents)
#   IOS_BUNDLE_ID              app bundle id for log filtering (default: com.canopyhost.app)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_ROOT="$(cd "$HERE/.." && pwd)"
IPA_CACHE="${IOS_IPA_CACHE:-$NATIVE_ROOT/dist/ios-device}"
BUNDLE_ID="${IOS_BUNDLE_ID:-com.canopyhost.app}"
ASC_API_BASE="https://api.appstoreconnect.apple.com/v1"

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_dim=$'\033[2m'; c_rst=$'\033[0m'
say()  { printf '%s\n' "$*" >&2; }
ok()   { printf '%s%s%s\n' "$c_grn" "$*" "$c_rst" >&2; }
warn() { printf '%s%s%s\n' "$c_ylw" "$*" "$c_rst" >&2; }
die()  { printf '%s%s%s\n' "$c_red" "$*" "$c_rst" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------------------------------------
# doctor — is the Linux side ready?
# ------------------------------------------------------------------------------------------
cmd_doctor() {
  local fail=0
  say "== iOS device tooling (libimobiledevice) =="
  for t in idevice_id ideviceinfo ideviceinstaller idevicesyslog; do
    if have "$t"; then printf '  %s✓%s %s\n' "$c_grn" "$c_rst" "$t" >&2
    else printf '  %s✗%s %s — missing\n' "$c_red" "$c_rst" "$t" >&2; fail=1; fi
  done
  if [ "$fail" = 1 ]; then
    warn "Install: sudo apt install libimobiledevice-utils ideviceinstaller   # Debian/Ubuntu"
    warn "         (Arch: pacman -S libimobiledevice + AUR ideviceinstaller)"
  fi
  say "== optional (register/fetch) =="
  have openssl && printf '  %s✓%s openssl (JWT signing for register)\n' "$c_grn" "$c_rst" >&2 || { printf '  %s✗%s openssl\n' "$c_ylw" "$c_rst" >&2; }
  have curl    && printf '  %s✓%s curl\n' "$c_grn" "$c_rst" >&2 || { printf '  %s✗%s curl\n' "$c_ylw" "$c_rst" >&2; }
  have gh      && printf '  %s✓%s gh (fetch CI artifacts)\n' "$c_grn" "$c_rst" >&2 || printf '  %s~%s gh CLI (only needed for `fetch`)\n' "$c_dim" "$c_rst" >&2
  say "== device =="
  if ! have idevice_id; then die "libimobiledevice not installed (see above)"; fi
  local ids; ids="$(idevice_id -l 2>/dev/null || true)"
  if [ -z "$ids" ]; then
    warn "No iPhone seen. Plug it in via USB, unlock it, and tap 'Trust This Computer'."
    warn "If usbmuxd is not running: sudo systemctl start usbmuxd"
    return 1
  fi
  local udid; udid="$(printf '%s\n' "$ids" | head -1)"
  local name ver
  name="$(ideviceinfo -u "$udid" -k DeviceName 2>/dev/null || echo '?')"
  ver="$(ideviceinfo -u "$udid" -k ProductVersion 2>/dev/null || echo '?')"
  if [ "$name" = '?' ]; then
    warn "Device $udid is connected but not TRUSTED yet — unlock it and tap 'Trust'."
    return 1
  fi
  ok "Connected + trusted: \"$name\"  iOS $ver  UDID $udid"
}

# ------------------------------------------------------------------------------------------
# udid — the value Apple needs to add the device to a development/ad-hoc profile.
# ------------------------------------------------------------------------------------------
require_device() {
  have idevice_id || die "libimobiledevice not installed — run: $0 doctor"
  local ids; ids="$(idevice_id -l 2>/dev/null || true)"
  [ -n "$ids" ] || die "no iPhone connected (USB + unlocked + Trusted). Run: $0 doctor"
  printf '%s\n' "$ids" | head -1
}
cmd_udid() { require_device; }

# ------------------------------------------------------------------------------------------
# register — add this iPhone's UDID to the Apple Developer account via the ASC API.
#
# A development/ad-hoc profile only signs for devices registered under the account. CI cannot
# register a device (none is attached to the runner), so we register it here, once, from Linux —
# then CI's -allowProvisioningUpdates picks it up into the generated profile. Uses the SAME ASC
# API key as the TestFlight upload (ASC_KEY_ID / ASC_ISSUER_ID / ASC_API_KEY_P8).
#
# Falls back to printing the manual portal steps if openssl/curl are missing or the call fails.
# ------------------------------------------------------------------------------------------
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# DER ECDSA signature (SEQ{ INTEGER r, INTEGER s }) -> raw 64-byte r||s for a JWS ES256 sig.
der2raw() {
  local der_hex r s
  # stdin is the RAW BINARY DER signature (from `openssl dgst -binary`); hex-dump it.
  der_hex="$(xxd -p -c 100000 | tr -d '\n')"
  # Parse: 30 LL 02 Lr <r> 02 Ls <s>
  local i=0
  # skip 30 and length
  i=4
  # 02 Lr
  local lr; lr=$((16#${der_hex:$((i+2)):2})); i=$((i+4))
  r="${der_hex:$i:$((lr*2))}"; i=$((i+lr*2))
  local ls; ls=$((16#${der_hex:$((i+2)):2})); i=$((i+4))
  s="${der_hex:$i:$((ls*2))}"
  # strip leading sign byte / left-pad to 32 bytes (64 hex)
  r="$(printf '%064s' "${r: -64}" | tr ' ' 0)"
  s="$(printf '%064s' "${s: -64}" | tr ' ' 0)"
  printf '%s%s' "$r" "$s" | xxd -r -p | b64url
}

asc_jwt() {
  local key="$1"
  [ -n "${ASC_KEY_ID:-}" ]    || die "ASC_KEY_ID is unset (the App Store Connect API Key ID)"
  [ -n "${ASC_ISSUER_ID:-}" ] || die "ASC_ISSUER_ID is unset (the API key Issuer UUID)"
  local now exp header payload signing_input sig
  now="$(date +%s)"; exp=$((now + 1140))   # < 20 min, ASC's max
  header="$(printf '{"alg":"ES256","kid":"%s","typ":"JWT"}' "$ASC_KEY_ID" | b64url)"
  payload="$(printf '{"iss":"%s","iat":%s,"exp":%s,"aud":"appstoreconnect-v1"}' "$ASC_ISSUER_ID" "$now" "$exp" | b64url)"
  signing_input="${header}.${payload}"
  sig="$(printf '%s' "$signing_input" | openssl dgst -sha256 -sign "$key" -binary | der2raw)"
  printf '%s.%s' "$signing_input" "$sig"
}

manual_register_help() {
  local udid="$1"
  warn "Register the device manually instead (1 minute):"
  warn "  1. https://developer.apple.com/account/resources/devices/add"
  warn "  2. Platform: iOS, Device ID (UDID): $udid"
  warn "  3. Re-run the signed build (CI/remote-build) so the profile picks it up."
}

cmd_register() {
  local name="Quinten iPhone (Path B)"
  while [ $# -gt 0 ]; do case "$1" in --name) name="$2"; shift 2;; *) die "register: unknown arg $1";; esac; done
  local udid; udid="$(require_device)"
  ok "Device UDID: $udid"
  if ! have openssl || ! have curl || ! have xxd; then
    warn "openssl/curl/xxd needed for API registration."
    manual_register_help "$udid"; return 0
  fi
  if [ -z "${ASC_API_KEY_P8:-}" ]; then
    warn "ASC_API_KEY_P8 is unset (path to AuthKey_<KeyID>.p8, or its PEM contents)."
    manual_register_help "$udid"; return 0
  fi
  # Materialize the key to a temp file (accept either a path or inline PEM contents).
  local keyfile; keyfile="$(mktemp)"; trap 'rm -f "$keyfile"' RETURN
  if [ -f "$ASC_API_KEY_P8" ]; then cp "$ASC_API_KEY_P8" "$keyfile"; else printf '%s' "$ASC_API_KEY_P8" > "$keyfile"; fi
  local jwt body http
  jwt="$(asc_jwt "$keyfile")" || { manual_register_help "$udid"; return 0; }
  body="$(printf '{"data":{"type":"devices","attributes":{"name":%s,"platform":"IOS","udid":"%s"}}}' \
            "$(printf '%s' "$name" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')" "$udid")"
  say "POST $ASC_API_BASE/devices  (name=\"$name\")"
  local resp; resp="$(mktemp)"; trap 'rm -f "$keyfile" "$resp"' RETURN
  http="$(curl -sS -o "$resp" -w '%{http_code}' -X POST "$ASC_API_BASE/devices" \
          -H "Authorization: Bearer $jwt" -H 'Content-Type: application/json' -d "$body" || echo 000)"
  case "$http" in
    201) ok "Registered \"$name\" ($udid) with Apple." ;;
    409) warn "Already registered (409) — nothing to do." ;;
    *)   warn "ASC API returned HTTP $http:"; cat "$resp" >&2 || true
         # A common, benign case: device already present but disabled — surface it, then manual help.
         manual_register_help "$udid" ;;
  esac
}

# ------------------------------------------------------------------------------------------
# fetch — pull the signed .ipa artifact off the latest GitHub Actions run via the gh CLI.
# ------------------------------------------------------------------------------------------
artifact_for_lane() { case "$1" in adhoc) echo ios-device-ipa-adhoc;; development|dev) echo ios-device-ipa-development;; "") echo ios-app-ipa;; *) die "unknown lane: $1";; esac; }

cmd_fetch() {
  local lane=adhoc run=""
  while [ $# -gt 0 ]; do case "$1" in --lane) lane="$2"; shift 2;; --run) run="$2"; shift 2;; *) die "fetch: unknown arg $1";; esac; done
  have gh || die "gh CLI not installed (needed to download CI artifacts). Or build via remote-build.sh and use \`install <ipa>\`."
  local art; art="$(artifact_for_lane "$lane")"
  mkdir -p "$IPA_CACHE"
  rm -rf "$IPA_CACHE/$art"; mkdir -p "$IPA_CACHE/$art"
  if [ -n "$run" ]; then
    gh run download "$run" -n "$art" -D "$IPA_CACHE/$art"
  else
    say "Downloading latest \"$art\" artifact…"
    gh run download -n "$art" -D "$IPA_CACHE/$art"
  fi
  local ipa; ipa="$(find "$IPA_CACHE/$art" -name '*.ipa' | head -1)"
  [ -n "$ipa" ] || die "no .ipa inside artifact $art (was the lane built? is APPLE_TEAM_ID set in CI?)"
  cp -f "$ipa" "$IPA_CACHE/CanopyHost-$lane.ipa"
  ok "Fetched: $IPA_CACHE/CanopyHost-$lane.ipa"
  printf '%s\n' "$IPA_CACHE/CanopyHost-$lane.ipa"
}

# ------------------------------------------------------------------------------------------
# install — push the .ipa to the connected iPhone.
# ------------------------------------------------------------------------------------------
default_ipa() { ls -t "$IPA_CACHE"/*.ipa 2>/dev/null | head -1 || true; }

cmd_install() {
  local ipa="${1:-$(default_ipa)}"
  [ -n "$ipa" ] || die "no .ipa given and none cached in $IPA_CACHE. Run \`$0 fetch\` or pass a path."
  [ -f "$ipa" ] || die "no such .ipa: $ipa"
  local udid; udid="$(require_device)"
  say "Installing $(basename "$ipa") onto $udid …"
  if ideviceinstaller --udid "$udid" install "$ipa"; then
    ok "Installed. Launch it on the phone (or: $0 logs)."
  else
    warn "Install failed. The usual causes:"
    warn "  • device UDID not in the signing profile  → $0 register, then rebuild"
    warn "  • free-account 7-day profile expired       → rebuild + reinstall"
    warn "  • simulator (not device) .ipa              → build the adhoc/development device lane"
    die  "ideviceinstaller install failed"
  fi
}

# ------------------------------------------------------------------------------------------
# logs — device syslog, filtered to the app (the Linux stand-in for the Xcode console).
# ------------------------------------------------------------------------------------------
cmd_logs() {
  local bid="$BUNDLE_ID"
  while [ $# -gt 0 ]; do case "$1" in --bundle) bid="$2"; shift 2;; *) die "logs: unknown arg $1";; esac; done
  local udid; udid="$(require_device)"
  say "Streaming syslog for $bid on $udid (Ctrl-C to stop)…"
  # --process filters to the app's process; CanopyHost is the executable name (PRODUCT_NAME).
  idevicesyslog -u "$udid" --process CanopyHost 2>/dev/null \
    || idevicesyslog -u "$udid" | grep --line-buffered -iE 'canopy|lumen|hermes'
}

# ------------------------------------------------------------------------------------------
# run — the one-shot loop: fetch (unless an .ipa is given) -> install -> logs.
# ------------------------------------------------------------------------------------------
cmd_run() {
  local lane=adhoc ipa=""
  while [ $# -gt 0 ]; do case "$1" in --lane) lane="$2"; shift 2;; *.ipa) ipa="$1"; shift;; *) die "run: unknown arg $1";; esac; done
  [ -n "$ipa" ] || ipa="$(cmd_fetch --lane "$lane")"
  cmd_install "$ipa"
  cmd_logs
}

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; }

case "${1:-}" in
  doctor)   shift; cmd_doctor "$@";;
  udid)     shift; cmd_udid "$@";;
  register) shift; cmd_register "$@";;
  fetch)    shift; cmd_fetch "$@";;
  install)  shift; cmd_install "$@";;
  logs)     shift; cmd_logs "$@";;
  run)      shift; cmd_run "$@";;
  -h|--help|help|"") usage;;
  *) die "unknown subcommand: $1  (try: $0 --help)";;
esac
