#!/usr/bin/env bash
# check-hbc-shipped.sh — PERF-1 / RNV-7: prove a REAL Hermes .hbc rides the shipped bundle.
#
# WHY THIS EXISTS
# ---------------
# Booting precompiled Hermes bytecode (canopy.bundle.hbc) instead of parsing JS source is the cold-TTI
# win PERF-1 buys. Both hosts ALREADY prefer canopy.bundle.hbc over canopy.bundle.js and ride it
# (MainActivity.readBundleBytes + CanopyHostViewController.loadBundleData), and the build tool emits the
# .hbc + a manifest "bytecode" block WHEN a hermesc is locatable (CANOPY_HERMESC / PATH / CANOPY_RN_ROOT).
# The risk this gate closes: a .hbc that ships but is FAKE (no Hermes magic — hermesc emitted nothing),
# VERSION-MISMATCHED (built by a hermesc whose bytecode version != the vendored engine's pin, so the
# host's checkBundleBytecode load gate would reject it at boot), SHA-MISMATCHED vs the manifest (stale),
# or DEAD WEIGHT (the host no longer wired to ride it). All four are caught device-free here.
#
# It is offline-runnable: it ALWAYS asserts the host→.hbc ride wiring (pure grep), and verifies a real
# .hbc whenever one is reachable — a pre-staged dist, or a fresh build when canopy-native + a hermesc
# are present. With neither, it SKIPS the content checks cleanly (today's default gate runner has no
# hermesc, so the .hbc is simply absent and the host boots JS) — never a fail-on-absent.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ABIGATE="$ROOT/host/shared/cpp/CanopyAbiGate.h"
AND_ACT="$ROOT/host/android/app/src/main/java/com/canopyhost/MainActivity.java"
AND_JNI="$ROOT/host/android/app/src/main/jni/CanopyHostJni.cpp"
IOS_VC="$ROOT/host/ios/CanopyHostCore/Boot/CanopyHostViewController.mm"
fail=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✗ %s\033[0m\n' "$*" >&2; fail=1; }
note(){ printf '  \033[33m· %s\033[0m\n' "$*"; }

# Hermes .hbc on-disk header (mirror of CanopyAbiGate.h:107 kCanopyHermesBytecodeMagic 0x1F1903C103BC1FC6,
# little-endian → the first 8 bytes are C6 1F BC 03 C1 03 19 1F).
HBC_MAGIC="c61fbc03c103191f"

sha_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
hbc_magic_of()   { od -An -tx1 -N8 "$1" 2>/dev/null | tr -d ' \n'; }
hbc_version_of() { python3 -c 'import struct,sys;d=open(sys.argv[1],"rb").read(12);print(struct.unpack_from("<I",d,8)[0] if len(d)>=12 else -1)' "$1" 2>/dev/null; }
manifest_field() { # manifest_field <manifest> <block> <field>  (no jq) e.g. bytecode sha256
  grep -o "\"$2\":{[^}]*}" "$1" 2>/dev/null | grep -o "\"$3\":\"\?[0-9a-fx]*\"\?" | head -1 | sed 's/.*://; s/"//g'; }

# ---- 1. The pinned bytecode version (the engine's HBC version; the host load gate's expectation). ----
PIN="$(grep -oE 'kCanopyExpectedHermesBytecodeVersion[[:space:]]*=[[:space:]]*[0-9]+' "$ABIGATE" 2>/dev/null | grep -oE '[0-9]+$' | head -1)"
echo "==> [1/3] pinned Hermes bytecode version (CanopyAbiGate.h)"
if [ -n "$PIN" ]; then ok "pinned bytecode version = $PIN"; else bad "could not read kCanopyExpectedHermesBytecodeVersion from CanopyAbiGate.h"; fi

# ---- 2. BOTH hosts are wired to ride a .hbc (always runs; device-free structural parity). ----
echo "==> [2/3] both hosts prefer + gate canopy.bundle.hbc (so a shipped .hbc isn't dead weight)"
grep -qF 'assetExists("canopy.bundle.hbc") ? "canopy.bundle.hbc" : "canopy.bundle.js"' "$AND_ACT" \
  && ok "Android: MainActivity prefers canopy.bundle.hbc over .js" \
  || bad "Android: MainActivity no longer prefers canopy.bundle.hbc (the .hbc would never be ridden)"
grep -qF 'enforceBundleBytecodeGate' "$AND_JNI" \
  && ok "Android: boot path runs enforceBundleBytecodeGate (RNV-7 version gate before eval)" \
  || bad "Android: enforceBundleBytecodeGate missing (a wrong-version .hbc could reach Hermes)"
grep -qF 'pathForResource:@"canopy.bundle" ofType:@"hbc"' "$IOS_VC" \
  && ok "iOS: CanopyHostViewController prefers the canopy.bundle.hbc resource over .js" \
  || bad "iOS: the .hbc resource preference is missing (the .hbc would never be ridden)"
grep -qF 'checkBundleBytecode' "$IOS_VC" \
  && ok "iOS: boot path runs checkBundleBytecode (RNV-7 version gate before eval)" \
  || bad "iOS: checkBundleBytecode missing (a wrong-version .hbc could reach Hermes)"

# ---- 3. Verify a REAL .hbc whenever one is reachable; SKIP its content checks cleanly otherwise. ----
echo "==> [3/3] a real .hbc exists, is valid bytecode at the pinned version, and matches its manifest"
DIST="${CANOPY_BUNDLE_DIST:-$ROOT/dist/app-bundle}"
HBC=""; MANIFEST=""; TMP=""
if [ -f "$DIST/canopy.bundle.hbc" ] && [ -f "$DIST/canopy.manifest.json" ]; then
  HBC="$DIST/canopy.bundle.hbc"; MANIFEST="$DIST/canopy.manifest.json"
  note "verifying the staged dist .hbc ($DIST)"
elif command -v canopy-native >/dev/null 2>&1 && { [ -n "${CANOPY_HERMESC:-}" ] || command -v hermesc >/dev/null 2>&1; }; then
  APP="${CANOPY_HBC_APP:-examples/counter}"
  note "no staged .hbc; building $APP with the available hermesc to emit one"
  TMP="$(mktemp -d)"
  if ( cd "$ROOT" && rm -rf "$APP/build" "$APP/canopy-stuff" && canopy-native build "$APP" >"$TMP/build.log" 2>&1 ) \
     && [ -f "$ROOT/$APP/build/canopy.bundle.hbc" ]; then
    HBC="$ROOT/$APP/build/canopy.bundle.hbc"; MANIFEST="$ROOT/$APP/build/canopy.manifest.json"
  else
    bad "canopy-native + a hermesc were present but no .hbc was emitted (see $TMP/build.log) — hermesc broken?"
  fi
fi

if [ -z "$HBC" ]; then
  note "SKIP .hbc content checks: no staged dist .hbc and no hermesc to emit one (host boots the JS bundle)."
else
  # (a) real Hermes bytecode magic
  m="$(hbc_magic_of "$HBC")"
  [ "$m" = "$HBC_MAGIC" ] && ok "canopy.bundle.hbc carries the Hermes magic ($HBC_MAGIC) — real bytecode" \
                          || bad "canopy.bundle.hbc magic is '$m' not '$HBC_MAGIC' — NOT real Hermes bytecode"
  # (b) bytecode version == the engine pin (else the host load gate rejects it at boot)
  v="$(hbc_version_of "$HBC")"
  [ -n "$PIN" ] && [ "$v" = "$PIN" ] && ok "bytecode version $v == pinned engine ABI $PIN (host checkBundleBytecode will accept it)" \
                || bad "bytecode version $v != pinned engine ABI $PIN — built by a MISMATCHED hermesc; the host would reject this .hbc"
  # (c) manifest bytecode block matches the file (sha + version)
  msha="$(manifest_field "$MANIFEST" bytecode sha256)"
  fsha="$(sha_of "$HBC")"
  [ -n "$msha" ] && [ "$msha" = "$fsha" ] && ok "manifest bytecode.sha256 == the shipped .hbc ($fsha)" \
                 || bad "manifest bytecode.sha256 ($msha) != shipped .hbc sha ($fsha) — stale/mismatched .hbc"
  mver="$(manifest_field "$MANIFEST" bytecode version)"
  [ -n "$mver" ] && [ "$mver" = "$v" ] && ok "manifest bytecode.version ($mver) == the .hbc header version" \
                 || bad "manifest bytecode.version ($mver) != the .hbc header version ($v) — manifest lies about the bytecode"
fi
[ -n "$TMP" ] && rm -rf "$TMP"

echo
if [ "$fail" -eq 0 ]; then echo "hbc-shipped OK — the host rides a real, version-matched .hbc (or cleanly boots JS when none is built)."; else echo "hbc-shipped check FAILED." >&2; fi
exit "$fail"
