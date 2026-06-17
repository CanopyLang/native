#!/usr/bin/env bash
# check-fast-refresh-rides-bundle.sh — DXL-1: prove state-preserving Fast Refresh rides the REAL
# compiled bundle, not a harness simulation.
#
# State-preserving hot reload (DEV-8) keeps the TEA model across an edit ONLY when the new bundle's
# Model type is the same shape — decided by comparing a deterministic Model-type-hash the compiler
# stamps on the bundle as `globalThis.__canopy_model_typehash = "<hex>"`. native.js (the walker) READS
# that global on remount. For a long time the harness HAND-INJECTED the hash because the compiler
# didn't emit it; this gate proves the compiler now does, so the headline DX feature is real, and it
# fails LOUD if a compiler bump ever stops emitting it (which would silently turn every reload into a
# full state-reset).
#
# Device-free: greps the real assembled bundle for the ASSIGNMENT (not just native.js's reader ref).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${CANOPY_FAST_REFRESH_APP:-examples/counter}"
fail=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✗ %s\033[0m\n' "$*" >&2; fail=1; }

# The compiler EMITS an assignment; native.js only READS it. Require the assignment form so the
# native.js reader reference alone can never satisfy the gate.
ASSIGN_RE='(globalThis|scope|self)\.__canopy_model_typehash[[:space:]]*=[[:space:]]*"[0-9a-f]+"'
READER_RE='__canopy_model_typehash'

assert_bundle() {
  local b="$1" label="$2"
  [ -f "$b" ] || { bad "$label bundle not found: $b"; return; }
  if grep -aqE "$ASSIGN_RE" "$b"; then
    ok "$label bundle SETS globalThis.__canopy_model_typehash ($(grep -aoE "$ASSIGN_RE" "$b" | head -1 | grep -oE '"[0-9a-f]+"'))"
  else
    bad "$label bundle does NOT set __canopy_model_typehash — the compiler stopped emitting it; state-preserving Fast Refresh would silently degrade to full reset"
  fi
}

echo "==> the compiled bundle carries the Model-type-hash (DEV-8 anchor)"
CANON="$ROOT/$APP/build/canopy.bundle.js"
if [ ! -f "$CANON" ] && command -v canopy-native >/dev/null 2>&1; then
  echo "  (building $APP — no bundle present)"; ( cd "$ROOT" && canopy-native build "$APP" >/dev/null 2>&1 ) || true
fi
assert_bundle "$CANON" "canonical ($APP)"

# dist/app-bundle is a local artifact that CI's `bundle` job rebuilds from source each run; if a stale
# local copy lacks the assignment, warn (don't fail) — the canonical from-source bundle above is the
# authoritative proof, and the SHIPPED bundle's integrity is separately gated by assert-bundle-manifest.
if [ -f "$ROOT/dist/app-bundle/canopy.bundle.js" ] && ! grep -aqE "$ASSIGN_RE" "$ROOT/dist/app-bundle/canopy.bundle.js"; then
  printf '  \033[33m· note: dist/app-bundle bundle lacks the hash — stale local artifact; rebuild with `canopy-native build` / CI regenerates it\033[0m\n'
fi

# native.js must actually READ it (the consumer side of the contract).
if grep -aqE "\.$READER_RE\b" "$ROOT/package/external/native.js"; then
  ok "native.js reads __canopy_model_typehash on remount (the consumer)"
else
  bad "native.js no longer reads __canopy_model_typehash — the remount type-gate is gone"
fi

echo
if [ "$fail" -eq 0 ]; then echo "Fast Refresh rides the real bundle — Model-type-hash emitted + consumed."; else echo "Fast-refresh bundle check FAILED." >&2; fi
exit "$fail"
