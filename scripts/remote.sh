#!/usr/bin/env bash
# remote.sh — one entry point to build + test Canopy Native on a remote box you give by IP.
#
#   ./scripts/remote.sh android <subcommand> [args]   ->  host/android/remote-build.sh
#   ./scripts/remote.sh ios     <subcommand> [args]   ->  host/ios/remote-build.sh
#
# First time on a new box (installs EVERYTHING on the remote, then builds + runs):
#   1. edit host/<platform>/.remote-build.env   (set LINUX_SSH/MAC_SSH = user@<IP>, REMOTE_DIR)
#   2. ./scripts/remote.sh <platform> provision
#   3. ./scripts/remote.sh <platform> doctor
#   4. CANOPY_BUNDLE=<app>/build/canopy.bundle.js  ./scripts/remote.sh <platform> all
#
# Build the bundle locally first:  canopy-native build examples/counter
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLAT="${1:?usage: remote.sh <android|ios> <subcommand> [args]}"; shift
case "$PLAT" in
  android) exec "$ROOT/host/android/remote-build.sh" "$@" ;;
  ios)     exec "$ROOT/host/ios/remote-build.sh" "$@" ;;
  *) echo "unknown platform '$PLAT' — use 'android' or 'ios'" >&2; exit 1 ;;
esac
