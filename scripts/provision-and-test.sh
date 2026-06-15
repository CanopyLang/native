#!/usr/bin/env bash
# provision-and-test.sh — the one command to take a fresh box (you give it by IP) all the way to a
# screenshot of your Canopy app running natively.
#
#   ./scripts/provision-and-test.sh <android|ios> <user@ip> [--release] [--device] [options] [-- <app-dir>]
#
# It does, in order:
#   1. derive the remote env from <user@ip>  (no hand-editing of .remote-build.env required)
#   2. build the JS bundle LOCALLY            (canopy-native build <app-dir>  ->  build/canopy.bundle.js)
#   3. dispatch to the platform harness:      remote.sh <platform> provision   (install the box toolchain)
#                                             remote.sh <platform> all         (sync -> build -> run)
#   4. print the pulled screen.png path + tail the canopy log
#
# Examples:
#   ./scripts/provision-and-test.sh android ubuntu@10.0.0.5
#   ./scripts/provision-and-test.sh ios     ci@192.168.1.9  --release -- examples/counter
#   ./scripts/provision-and-test.sh android ubuntu@10.0.0.5 --port 2222 --key ~/.ssh/box --device
#
# Flags:
#   --release           build the Release configuration (default: Debug)
#   --device            prefer a physically connected device over booting the AVD/simulator
#   --port <n>          SSH port (default 22)
#   --key <path>        SSH identity file
#   --remote-dir <dir>  override the remote checkout path (default derived from the user in user@ip)
#   --force             also write .remote-build.env on disk (default: env is only exported, never written)
#   --no-provision      skip the one-time provision step (box is already set up)
#   -- <app-dir>        the Canopy app to bundle (default: examples/counter)
#   -h, --help          this help
#
# Env naming is unified with host/{android,ios}/remote-build.sh: it exports LINUX_SSH (android) /
# MAC_SSH (ios), REMOTE_DIR, CONFIG and CANOPY_BUNDLE into the harness's process, so the harness
# picks them up at source-time without trampling any git-ignored .remote-build.env you already have.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

c_blue=$'\033[34m'; c_green=$'\033[32m'; c_red=$'\033[31m'; c_off=$'\033[0m'
say()  { printf '%s==>%s %s\n' "$c_blue" "$c_off" "$*"; }
ok()   { printf '%s OK %s %s\n' "$c_green" "$c_off" "$*"; }
die()  { printf '%s !! %s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

usage() { sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; }

# ------------------------------------------------------------------------------------------
# 1. Arg parse
# ------------------------------------------------------------------------------------------
PLATFORM=""; SSH_TARGET=""; APP_DIR=""
CONFIG="Debug"; PREFER_DEVICE=0; SSH_PORT="22"; SSH_KEY=""; REMOTE_DIR_OVERRIDE=""
FORCE_WRITE=0; DO_PROVISION=1
positional=()

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)      usage; exit 0 ;;
    --release)      CONFIG="Release"; shift ;;
    --device)       PREFER_DEVICE=1; shift ;;
    --force)        FORCE_WRITE=1; shift ;;
    --no-provision) DO_PROVISION=0; shift ;;
    --port)         SSH_PORT="${2:?--port needs a value}"; shift 2 ;;
    --key)          SSH_KEY="${2:?--key needs a value}"; shift 2 ;;
    --remote-dir)   REMOTE_DIR_OVERRIDE="${2:?--remote-dir needs a value}"; shift 2 ;;
    --)             shift; [ $# -gt 0 ] && APP_DIR="$1" && shift; break ;;
    -*)             usage >&2; die "unknown flag '$1'" ;;
    *)              positional+=("$1"); shift ;;
  esac
done

PLATFORM="${positional[0]:-}"
SSH_TARGET="${positional[1]:-}"

[ -n "$PLATFORM" ]   || { usage; echo; die "missing <platform> (android|ios)"; }
[ -n "$SSH_TARGET" ] || { usage; echo; die "missing <user@ip>"; }
case "$PLATFORM" in android|ios) ;; *) die "unknown platform '$PLATFORM' — use 'android' or 'ios'" ;; esac
case "$SSH_TARGET" in *@*) ;; *) die "second arg must be user@ip (got '$SSH_TARGET')" ;; esac

SSH_USER="${SSH_TARGET%@*}"
[ -n "$SSH_USER" ] || die "could not parse a user from '$SSH_TARGET' (expected user@ip)"

APP_DIR="${APP_DIR:-$ROOT/examples/counter}"
# Normalise app-dir to an absolute path (a relative app-dir is resolved against the repo root).
case "$APP_DIR" in /*) ;; *) APP_DIR="$ROOT/$APP_DIR" ;; esac
[ -d "$APP_DIR" ] || die "app-dir '$APP_DIR' does not exist"

# ------------------------------------------------------------------------------------------
# 2. Derive + export the remote env (unify with remote-build.sh var names)
# ------------------------------------------------------------------------------------------
if [ "$PLATFORM" = "android" ]; then
  SSH_VAR="LINUX_SSH"; PORT_VAR="LINUX_SSH_PORT"; KEY_VAR="LINUX_SSH_KEY"
  DEFAULT_REMOTE_DIR="/home/$SSH_USER/canopy-android-build"
else
  SSH_VAR="MAC_SSH";   PORT_VAR="MAC_SSH_PORT";   KEY_VAR="MAC_SSH_KEY"
  DEFAULT_REMOTE_DIR="/Users/$SSH_USER/canopy-ios-build"
fi
REMOTE_DIR="${REMOTE_DIR_OVERRIDE:-$DEFAULT_REMOTE_DIR}"

# Export so the harness (which `source`s .remote-build.env then applies `: "${VAR:=default}"`)
# sees these already-set values and uses them — without us writing/overwriting the env file.
export "$SSH_VAR"="$SSH_TARGET"
export "$PORT_VAR"="$SSH_PORT"
[ -n "$SSH_KEY" ] && export "$KEY_VAR"="$SSH_KEY"
export REMOTE_DIR
export CONFIG
[ "$PREFER_DEVICE" = "1" ] && export PREFER_DEVICE=1   # hint; android harness already prefers a connected device

say "platform   = $PLATFORM"
say "$SSH_VAR = $SSH_TARGET   (port $SSH_PORT)"
say "REMOTE_DIR = $REMOTE_DIR"
say "CONFIG     = $CONFIG"
say "app-dir    = $APP_DIR"

# Optional disk write of the env file (alternative to the export-only default). Non-destructive:
# back up any existing file first, since .remote-build.env is git-ignored user state.
if [ "$FORCE_WRITE" = "1" ]; then
  env_file="$ROOT/host/$PLATFORM/.remote-build.env"
  if [ -f "$env_file" ]; then
    cp -f "$env_file" "$env_file.bak"
    say "backed up existing env -> $env_file.bak"
  fi
  {
    echo "# written by provision-and-test.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ) from $SSH_TARGET"
    echo "$SSH_VAR=\"$SSH_TARGET\""
    echo "$PORT_VAR=\"$SSH_PORT\""
    [ -n "$SSH_KEY" ] && echo "$KEY_VAR=\"$SSH_KEY\""
    echo "REMOTE_DIR=\"$REMOTE_DIR\""
    echo "CONFIG=\"$CONFIG\""
  } > "$env_file"
  ok "wrote $env_file"
fi

# ------------------------------------------------------------------------------------------
# 3. Build the JS bundle LOCALLY
# ------------------------------------------------------------------------------------------
CANOPY_NATIVE="${CANOPY_NATIVE:-canopy-native}"
command -v "$CANOPY_NATIVE" >/dev/null 2>&1 || CANOPY_NATIVE="$HOME/.local/bin/canopy-native"
command -v "$CANOPY_NATIVE" >/dev/null 2>&1 || [ -x "$CANOPY_NATIVE" ] || die "canopy-native not found on PATH (build the bundle needs it)"

# outputDir from native.config.json (default 'build').
out_dir="build"
cfg="$APP_DIR/native.config.json"
if [ -f "$cfg" ] && command -v python3 >/dev/null 2>&1; then
  out_dir="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("outputDir","build"))' "$cfg" 2>/dev/null || echo build)"
fi
case "$out_dir" in /*) BUNDLE="$out_dir/canopy.bundle.js" ;; *) BUNDLE="$APP_DIR/$out_dir/canopy.bundle.js" ;; esac

build_release_flag=""
[ "$CONFIG" = "Release" ] && build_release_flag="--release"

say "building bundle: $CANOPY_NATIVE build $APP_DIR $build_release_flag"
"$CANOPY_NATIVE" build "$APP_DIR" $build_release_flag || die "canopy-native build failed"
[ -f "$BUNDLE" ] || die "expected bundle not found at $BUNDLE after build"
export CANOPY_BUNDLE="$BUNDLE"
ok "bundle: $CANOPY_BUNDLE ($(wc -c < "$CANOPY_BUNDLE") bytes)"

# ------------------------------------------------------------------------------------------
# 4. Dispatch to the platform harness via remote.sh (provision, then all)
# ------------------------------------------------------------------------------------------
REMOTE_SH="${REMOTE_SH:-$ROOT/scripts/remote.sh}"

if [ "$DO_PROVISION" = "1" ]; then
  say "provisioning the box (one-time, idempotent)…"
  "$REMOTE_SH" "$PLATFORM" provision
else
  say "skipping provision (--no-provision)"
fi

say "running the full pipeline (sync -> build -> run)…"
"$REMOTE_SH" "$PLATFORM" all

# ------------------------------------------------------------------------------------------
# 5. Print the pulled artifacts
# ------------------------------------------------------------------------------------------
ARTIFACTS="$ROOT/host/$PLATFORM/remote-artifacts"
SCREEN="$ARTIFACTS/screen.png"
# iOS emits canopy.log; Android currently emits logcat.txt — accept either so the contract holds.
LOG=""
for cand in "$ARTIFACTS/canopy.log" "$ARTIFACTS/logcat.txt"; do
  [ -f "$cand" ] && { LOG="$cand"; break; }
done

echo
say "artifacts in $ARTIFACTS:"
if [ -f "$SCREEN" ]; then ok "screenshot: $SCREEN"; else die "no screen.png pulled — see the harness output above"; fi
if [ -n "$LOG" ]; then
  ok "log: $LOG"
  say "last log lines:"
  tail -20 "$LOG"
else
  say "no canopy.log / logcat.txt pulled (the run may not have produced one)"
fi
