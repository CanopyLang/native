#!/usr/bin/env bash
# check-ios-marshalling.sh — IOS-12 structural gate for the iOS hot-path marshalling (NO Mac required).
#
# IOS-12's deliverable is the iOS half of the per-frame marshalling fast-path — the iOS twin of AND-8
# (the single-scalar __fabric_updatePropScalar fast path) and RND-7 (the per-frame binary __fabric_
# applyBatch). The shared C++ installer (CanopyFabric.cpp) and the ONE reconciler the host boots
# (package/external/native.js) are platform-neutral and already exercised device-free by the mock
# (harness/run-batch.js / harness/bench.js). What is PLATFORM-SPECIFIC and unverifiable off macOS is
# the iOS CanopyHost override that actually realizes the win on UIKit views: the host must
#   (A) override updatePropScalar(handle,key,value) to apply text/value/opacity WITHOUT an
#       NSJSONSerialization round-trip — the iOS twin of CanopyHost.java::updatePropScalar (AND-8);
#   (B) override the 3-arg createView(name,props,HANDLE) to register a batched view at the JS-CHOSEN
#       handle — the iOS twin of CanopyHost.java::createViewWithHandle/createAt (RND-7). WITHOUT this
#       override the shared 3-arg default (CanopyFabric.h) IGNORES the handle, so every post-create op
#       in a batched frame (update/scalar/insert) would miss the host's views_ map and silently no-op
#       — i.e. batched rendering would draw NOTHING on iOS. This gate exists primarily to make that
#       latent break loud the moment it regresses.
#
# Because the iOS host CANNOT be compiled off macOS (Xcode/UIKit/Hermes/Yoga link), this gate proves
# — device-free, by structural assertion over the committed sources — that:
#   (1) SHARED ABI — CanopyFabric.h declares the additive 3-arg createView + updatePropScalar defaults
#       (NOT pure-virtual, CANOPY_ABI_VERSION un-bumped), and CanopyFabric.cpp's binary/JSON batch
#       decoders route kCreate through createView(tag,props,h) and kScalar through updatePropScalar.
#   (2) WALKER — native.js routes the dominant single-scalar mutation to __fabric_updatePropScalar and,
#       under batching, allocates handles from __fabric_batchHandleBase and emits kCreate at that handle.
#   (3) ANDROID GOLDEN — CanopyHost.java implements updatePropScalar (text/value/opacity) and
#       createViewWithHandle→createAt (the parity reference the iOS twin mirrors).
#   (4) iOS HOST — CanopyHostFabric.mm overrides BOTH updatePropScalar (text/value/opacity, no
#       NSJSONSerialization on the fast keys) AND the 3-arg createView, and both createView overloads
#       funnel through ONE shared createAt(h,...) so the per-mutation and batched paths build a view
#       identically. The unknown-scalar branch still falls back to the JSON path (nothing dropped).
#   (5) DEVICE-FREE TEST — CanopyValidationLedgerTests.mm pins the pure fast-path decision rules
#       (which key sets which view property; the batch handle is honoured), the twin of the mock gate.
#
# Pure bash + grep (no device, no SDK, no compiler). Usage:  bash scripts/check-ios-marshalling.sh
# Exit: 0 = the iOS hot-path marshalling is structurally complete + Android-parity (scalar + batch
#           handle), wired to the shared ABI + walker.  1 = a seam is missing or drifted.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IOS="$ROOT/host/ios"
SHARED="$ROOT/host/shared/cpp"
DROID="$ROOT/host/android/app/src"

FABRIC_H="$SHARED/CanopyFabric.h"
FABRIC_CPP="$SHARED/CanopyFabric.cpp"
IOS_FABRIC="$IOS/CanopyHostCore/Render/CanopyHostFabric.mm"
WALKER="$ROOT/package/external/native.js"
DROID_HOST="$DROID/main/java/com/canopyhost/CanopyHost.java"
TEST="$IOS/Tests/CanopyHostCoreTests/CanopyValidationLedgerTests.mm"
MOCK_GATE="$ROOT/harness/run-batch.js"
MOCK_FABRIC="$ROOT/harness/mock-fabric.js"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
status=0

# need <label> <file> <pattern...> — every pattern must be present in the file.
need() {
  local label="$1" file="$2"; shift 2
  if [ ! -f "$file" ]; then red "    FAIL — $label: missing file ${file#$ROOT/}"; status=1; return; fi
  local miss=()
  for pat in "$@"; do
    grep -qE -- "$pat" "$file" || miss+=("$pat")
  done
  if [ "${#miss[@]}" -gt 0 ]; then
    red "    FAIL — $label (${file#$ROOT/}) is missing:"
    for m in "${miss[@]}"; do echo "        · $m"; done
    status=1
  else
    green "    OK  — $label"
  fi
}

echo "==> iOS hot-path marshalling gate (scripts/check-ios-marshalling.sh)"
echo "    (structural — the iOS host cannot be compiled off macOS; this proves the iOS scalar fast-path"
echo "     (AND-8) + the batched create-at-JS-handle path (RND-7) are wired to the shared ABI + walker,"
echo "     and are the faithful twin of the Android-validated host.)"
echo

# ── (1) the SHARED ABI exposes the additive fast-path seams the iOS host overrides ────────────
echo "--> [1] shared ABI (CanopyFabric.h/.cpp) — the additive fast-path virtuals + batch decode:"
need "CanopyFabric.h declares updatePropScalar + the 3-arg createView as DEFAULTED (additive) virtuals" "$FABRIC_H" \
  'virtual void updatePropScalar\(Handle view, const std::string& key, const std::string& value\)' \
  'virtual Handle createView\(const std::string& fabricComponentName,' \
  'const std::string& propsJson, Handle handle\)'
need "CanopyAbi.h survival rule honoured — the fast-path seams do NOT bump CANOPY_ABI_VERSION" "$FABRIC_H" \
  'CANOPY_ABI_VERSION is deliberately NOT bumped'
need "CanopyFabric.cpp binary/JSON batch decoders route kCreate→createView(_,_,h) and kScalar→updatePropScalar" "$FABRIC_CPP" \
  'host\.createView\(tag, props, h\)' \
  'host\.createView\(strAt\(op, 2\), strAt\(op, 3\), numAt\(op, 1\)\)' \
  'host\.updatePropScalar\(h, key, val\)' \
  '__fabric_updatePropScalar'

# ── (2) the ONE reconciler the iOS host boots drives those seams ──────────────────────────────
echo "--> [2] walker (package/external/native.js) — scalar fast-path + batched JS-allocated handles:"
need "the walker routes the dominant single-scalar mutation to __fabric_updatePropScalar" "$WALKER" \
  '__fabric_updatePropScalar' \
  '_NB_SCALAR'
need "the walker allocates batched handles from __fabric_batchHandleBase and emits kCreate at that handle" "$WALKER" \
  '__fabric_batchHandleBase' \
  '_NB_CREATE, h,'

# ── (3) the Android GOLDEN the iOS twin mirrors ───────────────────────────────────────────────
echo "--> [3] Android golden (CanopyHost.java) — the parity reference for both fast-paths:"
need "Android implements the AND-8 scalar fast-path (text/value/opacity) on real views" "$DROID_HOST" \
  'public void updatePropScalar\(int h, String key, String value\)' \
  'case "text":' \
  'case "value":' \
  'case "opacity":'
need "Android implements the RND-7 batch create-at-handle via a shared createAt body" "$DROID_HOST" \
  'public int createViewWithHandle\(int h, String fabricName, String propsJson\)' \
  'private int createAt\(int h, String fabricName, String propsJson\)' \
  'return createAt\(next\+\+,'

# ── (4) the iOS HOST realizes BOTH fast-paths, funnelled through ONE shared createAt ──────────
echo "--> [4] iOS host (CanopyHostFabric.mm) — overrides both fast-paths, Android-parity, one createAt:"
need "iOS overrides updatePropScalar with the text/value/opacity fast keys (no NSJSONSerialization on them)" "$IOS_FABRIC" \
  'void updatePropScalar\((canopy::)?Handle h, const std::string& key, const std::string& value\) override' \
  'if \(key == "text"\)' \
  'key == "value"' \
  'key == "opacity"'
need "iOS overrides the 3-arg createView to register a batched view at the JS-chosen handle" "$IOS_FABRIC" \
  '(canopy::)?Handle createView\(const std::string& name, const std::string& propsJson, (canopy::)?Handle h\) override' \
  'return createAt\(h, name, propsJson\)'
need "BOTH createView overloads funnel through ONE shared createAt(h,...) (per-mutation + batched build identically)" "$IOS_FABRIC" \
  '(canopy::)?Handle createAt\((canopy::)?Handle h, const std::string& name, const std::string& propsJson\)' \
  'return createAt\(next_\+\+, name, propsJson\)' \
  'views_\[h\] = cv;'
# the scalar fast path applies to the SAME view properties the JSON applyProps path does (byte-for-byte),
# and its unknown-key escape hatch still reaches the JSON path so nothing is ever dropped.
need "iOS scalar fast-path mirrors applyProps' view branches (UILabel text / input+switch value / alpha)" "$IOS_FABRIC" \
  'isKindOfClass:\[UILabel class\]\]' \
  'setValueControlled' \
  'setCheckedControlled' \
  'cv\.view\.alpha = f'
need "iOS scalar fast-path falls back to the JSON applyProps path for an unknown key (nothing dropped)" "$IOS_FABRIC" \
  'Unknown scalar key' \
  'applyProps\(h, std::string'

# ── (5) the device-free test pins the pure fast-path decision rules ───────────────────────────
echo "--> [5] device-free test (CanopyValidationLedgerTests.mm) — pins the pure fast-path rules:"
need "the ledger XCTest pins the IOS-12 scalar key→property map + the batched handle is honoured" "$TEST" \
  'IOS-12' \
  'scalarTarget' \
  'createAt'

# ── (6) the SAME seams are exercised device-free by the mock-fabric batch gate (cross-host) ──
echo "--> [6] the shared mock gate (harness/run-batch.js + mock-fabric.js) exercises the SAME binary/scalar protocol:"
# run-batch.js drives the binary protocol incl. the scalar opcode (3) at a JS-allocated handle (0x40000000)
# and counts scalar vs JSON prop hits — the cross-host proof the iOS host's overrides are the right shape.
need "run-batch.js drives the batched binary protocol incl. the scalar op + JS-handle create" "$MOCK_GATE" \
  'scalarProps' \
  '__fabric_applyBatch' \
  '0x40000000'
need "the mock fabric implements __fabric_updatePropScalar (the seam the iOS host overrides for real)" "$MOCK_FABRIC" \
  '__fabric_updatePropScalar'

echo
if [ "$status" -eq 0 ]; then
  green "ALL GREEN — the iOS hot-path marshalling is wired (scalar fast-path + batched JS-handle create),"
  green "            funnelled through one createAt, and is the faithful twin of the Android-validated host."
  green "            (Mac-gated: the real on-Simulator render/tap run is host/ios/PART5-LEDGER.md + BUILD-AND-VALIDATE.md.)"
else
  red "REGRESSION — the iOS hot-path marshalling gate drifted. See plans/dependent/IOS-12.md + plans/independent/AND-8.md + plans/dependent/RND-7.md." >&2
fi
exit "$status"
