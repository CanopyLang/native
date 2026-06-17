#!/usr/bin/env bash
# check-autolink-zero-edit.sh — CAP-0: prove the compatibility north star device-free — "a stranger
# ships a native capability as a package and it autolinks into an app with ZERO host edits."
#
# examples/pingtest depends on the sibling capability package canopy/ping, which it does NOT author;
# canopy/ping declares its native module in native.json. A real autolink must, from the dependency
# graph alone:
#   (1) emit reg.registerModule(...Ping...) into the host's GENERATED registrant (the capability is
#       wired without anyone editing the host), and
#   (2) leave every TRACKED file under host/ and package/ untouched (the generated registrant +
#       canopy-autolink.* are gitignored) — i.e. NO fork of the host, and
#   (3) resolve to exactly ONE registration per module (deterministic; no duplicate).
#
# Device-free: drives `canopy-native build` (which runs runAutolink) with the host-android + monorepo
# env pointed at this repo; asserts the registrant + a clean tree. The on-device boot of the Ping
# capability is the device-gated half (CAP-1).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="examples/pingtest"
MONOREPO="${CANOPY_MONOREPO:-$(cd "$ROOT/.." && pwd)}"
REG="host/android/app/src/main/jni/generated/CanopyGeneratedRegistrant.h"
fail=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✗ %s\033[0m\n' "$*" >&2; fail=1; }

if ! command -v canopy-native >/dev/null 2>&1; then
  echo "  · SKIP autolink zero-edit gate: canopy-native not on PATH (toolchain absent)"; exit 0
fi
if [ ! -d "$MONOREPO/ping" ]; then
  echo "  · SKIP autolink zero-edit gate: sibling capability package '$MONOREPO/ping' not present (CI fetches it; bare checkout skips)"; exit 0
fi

# Pre-state: host/ + package/ must be clean so a NON-empty diff afterward is attributable to the build.
PRE="$(git -C "$ROOT" status --porcelain host/ package/)"
if [ -n "$PRE" ]; then echo "  · note: host//package/ already dirty before the gate; asserting the build adds nothing NEW"; fi

echo "==> autolink a stranger capability (canopy/ping) into $APP with zero host edits"
out="$(cd "$ROOT" && CANOPY_HOST_ANDROID="$ROOT/host/android" CANOPY_MONOREPO="$MONOREPO" canopy-native build "$APP" 2>&1)"
rc=$?
[ $rc -eq 0 ] && ok "build + autolink ran (rc=0)" || { bad "build failed (rc=$rc): $(echo "$out" | tail -3 | tr '\n' ' ')"; }
echo "$out" | grep -q 'autolinked' && ok "autolinker reported it wired package(s): $(echo "$out" | grep 'autolinked' | head -1)" || bad "autolinker did not report 'autolinked …' — runAutolink did not fire (check CANOPY_HOST_ANDROID)"

# (1) the generated registrant registers Ping.
if grep -qE 'registerModule\([^)]*"Ping"' "$ROOT/$REG" 2>/dev/null; then
  ok "(1) generated registrant registers the stranger module: $(grep -oE 'registerModule\([^;]*"Ping"[^;]*' "$ROOT/$REG" | head -1)"
else
  bad "(1) generated registrant does NOT register Ping — autolink from the dep graph did not wire the capability"
fi

# (2) zero host edits: no NEW tracked changes under host/ or package/ (generated files are gitignored).
POST="$(git -C "$ROOT" status --porcelain host/ package/)"
NEW="$(comm -13 <(printf '%s\n' "$PRE" | sort) <(printf '%s\n' "$POST" | sort) | sed '/^$/d')"
if [ -z "$NEW" ]; then
  ok "(2) ZERO new tracked edits under host/ or package/ — the capability wired without forking the host"
else
  bad "(2) autolink introduced tracked changes under host//package/ (should be gitignored generated files only):"; printf '%s\n' "$NEW" >&2
fi

# (3) deterministic: exactly one Ping registration.
n=$(grep -c '"Ping"' "$ROOT/$REG" 2>/dev/null || echo 0)
if [ "$n" = "1" ]; then ok "(3) exactly one Ping registration (deterministic resolution, no duplicate)"; else bad "(3) expected 1 Ping registration, found $n (non-deterministic / duplicate)"; fi

echo
if [ "$fail" -eq 0 ]; then echo "autolink zero-edit OK — a stranger capability autolinks with no host fork."; else echo "autolink zero-edit check FAILED." >&2; fi
exit "$fail"
