#!/usr/bin/env bash
# check-reproducible-build.sh — REPRO-1: prove the bundle is byte-for-byte reproducible.
#
# The content-addressed buildId is the trust anchor for BOTH the crash-free metric (REL-4 keys crash
# reports by buildId) and OTA (DXL-4 refuses a bundle whose sha != buildId). That trust is only real
# if the SAME source at the SAME pinned compiler always produces the SAME bytes. This gate builds the
# canonical app TWICE from a clean tree and asserts the bundle sha256 (== the manifest buildId) is
# identical — so a non-deterministic change (timestamp/ordering/PRNG leaking into output) fails CI.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${CANOPY_REPRO_APP:-examples/counter}"
fail=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✗ %s\033[0m\n' "$*" >&2; fail=1; }

if ! command -v canopy-native >/dev/null 2>&1; then
  echo "  · SKIP reproducible-build gate: canopy-native not on PATH (toolchain absent)"; exit 0
fi

sha_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
# Build the app from a clean tree. Retry ONCE on a transient build FAILURE (e.g. a build-cache
# "resource busy (file is locked)" hiccup) — clearing canopy-stuff first. This retries only when the
# build COMMAND fails, never on an output difference, so determinism detection is untouched: a real
# non-deterministic build still produces two differing artifacts and fails the sha compare below.
build_once() {
  rm -rf "$ROOT/$APP/build"
  if ( cd "$ROOT" && canopy-native build "$APP" >/dev/null 2>&1 ); then return 0; fi
  rm -rf "$ROOT/$APP/build" "$ROOT/$APP/canopy-stuff"
  ( cd "$ROOT" && canopy-native build "$APP" >/dev/null 2>&1 )
}
buildid_of() { grep -o '"buildId":"[0-9a-f]\{64\}"' "$1" 2>/dev/null | head -1 | sed 's/.*:"//; s/"//'; }

hbc_sha() { [ -f "$ROOT/$APP/build/canopy.bundle.hbc" ] && sha_of "$ROOT/$APP/build/canopy.bundle.hbc" || echo ""; }

echo "==> build $APP twice from a clean tree and compare the content address"
build_once || { bad "first build failed"; exit "$fail"; }
A="$(sha_of "$ROOT/$APP/build/canopy.bundle.js")"
idA="$(buildid_of "$ROOT/$APP/build/canopy.manifest.json")"
hbcA="$(hbc_sha)"
build_once || { bad "second build failed"; exit "$fail"; }
B="$(sha_of "$ROOT/$APP/build/canopy.bundle.js")"
idB="$(buildid_of "$ROOT/$APP/build/canopy.manifest.json")"
hbcB="$(hbc_sha)"

[ "$A" = "$B" ] && ok "bundle byte-identical across two clean builds ($A)" \
                || bad "bundle NON-deterministic: $A != $B (a timestamp/ordering/PRNG is leaking into the output)"
# RNV-7/PERF-1: when a hermesc is reachable (CANOPY_HERMESC / PATH) the build also emits a Hermes .hbc.
# It must be byte-identical too — the buildId trust anchor (and any future .hbc OTA) covers the bytecode.
if [ -n "$hbcA" ] || [ -n "$hbcB" ]; then
  [ -n "$hbcA" ] && [ "$hbcA" = "$hbcB" ] && ok "Hermes .hbc byte-identical across two clean builds ($hbcA)" \
                 || bad "Hermes .hbc NON-deterministic across builds: '$hbcA' != '$hbcB'"
else
  echo "  · no .hbc emitted (no hermesc) — bytecode reproducibility check skipped"
fi
[ -n "$idA" ] && [ "$idA" = "$A" ] && ok "manifest buildId == bundle sha256 (content address is honest)" \
                || bad "manifest buildId ($idA) != bundle sha256 ($A)"
[ -n "$idA" ] && [ "$idA" = "$idB" ] && ok "buildId stable across builds ($idA)" \
                || bad "buildId changed across builds: $idA != $idB"

echo
if [ "$fail" -eq 0 ]; then echo "reproducible-build OK — same source + pinned compiler ⇒ same bytes."; else echo "reproducible-build check FAILED." >&2; fi
exit "$fail"
