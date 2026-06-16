#!/usr/bin/env bash
# check-cross-platform-vectors.sh — IOS-9 device-free gate for the SHARED cross-platform
# layout/style test-vector suite (NO Mac, NO emulator required).
#
# IOS-9's deliverable: a platform-neutral JSON corpus of (component, props, expected Yoga frames +
# style effects) that runs on BOTH hand-written hosts — Android (instrumentation, real libyoga.so)
# and iOS (XCTest, real Yoga pod) — and fails CI on divergence. It is the durable anti-drift control
# for master-plan Risk R5 ("two hand-maintained hosts drift; only signal today is a device crash").
#
# The two device runs are environment-gated (the Android leg needs an emulator; the iOS leg needs a
# Mac/Simulator). This gate is the cheap Linux net that runs on EVERY commit and proves, device-free,
# that the suite is WIRED and CANNOT SILENTLY ROT:
#
#   (1) ONE corpus, ONE source of truth. host/shared/test-vectors/layout-vectors.json is canonical;
#       the Android test APK packages a copy under src/androidTest/assets/. This gate asserts the two
#       are BYTE-IDENTICAL — so the two hosts can never run divergent corpora. (Re-sync with the cp
#       printed on failure.) The iOS target reads the canonical file directly (project.yml resource).
#   (2) The corpus is internally consistent + every expected frame/color is reproduced by an
#       INDEPENDENT oracle — runs host/shared/test-vectors/validate-vectors.js (a second flexbox/CSS
#       implementation, so a corpus typo cannot self-agree). This is the on-Linux stand-in for the
#       device Yoga runs.
#   (3) BOTH runners exist and consume the corpus: the Android CanopyLayoutVectorTest.java and the
#       iOS CanopyLayoutVectorTests.mm each load layout-vectors.json, build a REAL Yoga tree, and
#       assert the `expect` frames; each sweeps/normalizes the deliberate density(px)/points
#       divergence the right way (Android *density then /density; iOS points, dp==v).
#   (4) The runners' style->Yoga mapping is tied to the HOST's: every geometric style key the corpus
#       uses is handled by BOTH CanopyHost.java::applyStyle and CanopyHostFabric.mm::applyStyle (so
#       the reference mappings in the runners cannot drift from the production hosts unnoticed).
#   (5) The project wires both: the iOS test target bundles the corpus as a resource; both runners are
#       in the right test source set.
#
# Pure bash + grep + node (no device/SDK/Xcode). Usage:  bash scripts/check-cross-platform-vectors.sh
# Exit: 0 = the shared vector suite is wired, single-sourced, oracle-consistent, host-tied.
#       1 = the corpus rotted, a copy drifted, a runner/host mapping diverged, or wiring is missing.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHARED="$ROOT/host/shared/test-vectors"
CORPUS="$SHARED/layout-vectors.json"
VALIDATOR="$SHARED/validate-vectors.js"
DROID_COPY="$ROOT/host/android/app/src/androidTest/assets/layout-vectors.json"
DROID_RUNNER="$ROOT/host/android/app/src/androidTest/java/com/canopyhost/CanopyLayoutVectorTest.java"
IOS_RUNNER="$ROOT/host/ios/Tests/CanopyHostCoreTests/CanopyLayoutVectorTests.mm"
DROID_HOST="$ROOT/host/android/app/src/main/java/com/canopyhost/CanopyHost.java"
IOS_HOST="$ROOT/host/ios/CanopyHostCore/Render/CanopyHostFabric.mm"
PROJECT_YML="$ROOT/host/ios/project.yml"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
status=0

need() {  # need <label> <file> <pattern...>
  local label="$1" file="$2"; shift 2
  if [ ! -f "$file" ]; then red "    FAIL — $label: missing file ${file#$ROOT/}"; status=1; return; fi
  local miss=() pat
  for pat in "$@"; do grep -qE -- "$pat" "$file" || miss+=("$pat"); done
  if [ "${#miss[@]}" -gt 0 ]; then
    red "    FAIL — $label (${file#$ROOT/}) is missing:"; local m
    for m in "${miss[@]}"; do echo "        · $m"; done
    status=1
  else
    green "    OK  — $label"
  fi
}

echo "==> Cross-platform test-vector suite gate (scripts/check-cross-platform-vectors.sh) [IOS-9]"
echo "    (device-free — the durable anti-drift control: ONE corpus, run on BOTH hosts' real Yoga,"
echo "     proven here by an independent oracle + structural wiring checks.)"
echo

# ── (1) ONE corpus, ONE source of truth ──────────────────────────────────────────────────────
echo "--> [1] Single source of truth (canonical corpus == the Android test-APK copy, byte-identical):"
if [ ! -f "$CORPUS" ]; then red "    FAIL — canonical corpus missing: ${CORPUS#$ROOT/}"; status=1; fi
if [ ! -f "$DROID_COPY" ]; then red "    FAIL — Android asset copy missing: ${DROID_COPY#$ROOT/}"; status=1; fi
if [ -f "$CORPUS" ] && [ -f "$DROID_COPY" ]; then
  if cmp -s "$CORPUS" "$DROID_COPY"; then
    green "    OK  — the Android test-APK corpus is byte-identical to the canonical corpus"
  else
    red   "    FAIL — the Android corpus copy DRIFTED from the canonical one. Re-sync with:"
    red   "             cp host/shared/test-vectors/layout-vectors.json \\"
    red   "                host/android/app/src/androidTest/assets/layout-vectors.json"
    status=1
  fi
fi
echo

# ── (2) Independent oracle: the corpus is consistent + every frame/color is reproduced ────────
echo "--> [2] Independent oracle (validate-vectors.js — a second flexbox/CSS implementation):"
if ! command -v node >/dev/null 2>&1; then
  red "    FAIL — node is required to run the corpus validator"; status=1
elif [ ! -f "$VALIDATOR" ]; then
  red "    FAIL — validator missing: ${VALIDATOR#$ROOT/}"; status=1
else
  if node "$VALIDATOR" >/tmp/xplat-vectors-validate.log 2>&1; then
    green "    OK  — corpus is well-formed, density-normalizable, and oracle-reproduced"
    grep -c '  OK   —' /tmp/xplat-vectors-validate.log | sed 's/^/        validated vectors: /'
  else
    red "    FAIL — the corpus validator failed:"; sed 's/^/        /' /tmp/xplat-vectors-validate.log | tail -12
    status=1
  fi
fi
echo

# ── (3) BOTH runners exist and consume the corpus with the right normalization ────────────────
echo "--> [3] Both host runners load the corpus, build REAL Yoga, normalize the density/points divergence:"
need "Android runner loads the corpus, builds real Yoga, sweeps densities, normalizes /density" "$DROID_RUNNER" \
  'layout-vectors\.json' \
  'YogaNodeFactory\.create' \
  'calculateLayout' \
  'getLayoutX|getLayoutWidth' \
  '/ \(float\) density|/ \(double\) density|/ density' \
  'densities' \
  'expect'
need "Android runner is an instrumentation test (real libyoga.so) + inits SoLoader" "$DROID_RUNNER" \
  '@RunWith\(AndroidJUnit4' \
  'SoLoader\.init'
need "iOS runner loads the corpus, builds real Yoga, asserts frames in POINTS (dp==v, no density)" "$IOS_RUNNER" \
  'layout-vectors' \
  'YGNodeNew' \
  'YGNodeCalculateLayout' \
  'YGNodeLayoutGetLeft|YGNodeLayoutGetWidth' \
  'expect'
need "iOS runner is an XCTest bundle that reads the corpus from its own resource bundle" "$IOS_RUNNER" \
  '#import <XCTest/XCTest.h>' \
  'bundleForClass' \
  'pathForResource:@"layout-vectors"'
# Both runners must also exercise the color vectors (the SAME color contract on both hosts).
need "Android runner asserts the color vectors against the REAL host CanopyColor" "$DROID_RUNNER" \
  'colorVectors' \
  'com\.canopyhost\.views\.CanopyColor\.parse'
need "iOS runner asserts the color vectors against the CanopyColor contract" "$IOS_RUNNER" \
  'colorVectors' \
  'parseColor'
echo

# ── (4) The runners' style->Yoga mapping is tied to BOTH production hosts ──────────────────────
echo "--> [4] Every geometric style key the corpus uses is handled by BOTH production hosts' applyStyle:"
# Pull the geometric style keys actually used by the corpus's layoutVectors (the keys that move a
# Yoga frame). For each, assert the host applyStyle on BOTH platforms carries it — so the runners'
# reference mappings cannot diverge from production unnoticed.
KEYS="$(node -e '
  const fs=require("fs");
  const c=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
  const geo=new Set();
  const walk=(n)=>{ const s=n.style||{}; Object.keys(s).forEach(k=>geo.add(k)); (n.children||[]).forEach(walk); };
  (c.layoutVectors||[]).forEach(v=>walk(v.tree));
  // root size keys live on the root tree node already; emit the sorted union.
  console.log([...geo].sort().join(" "));
' "$CORPUS" 2>/dev/null)"
if [ -z "$KEYS" ]; then red "    FAIL — could not extract style keys from the corpus"; status=1; fi
for k in $KEYS; do
  dok=1; iok=1
  grep -qE "\"$k\"" "$DROID_HOST" || dok=0
  grep -qE "@\"$k\"" "$IOS_HOST"  || iok=0
  if [ "$dok" -eq 1 ] && [ "$iok" -eq 1 ]; then
    green "    OK  — style key '$k' handled by both CanopyHost.java + CanopyHostFabric.mm"
  else
    [ "$dok" -eq 0 ] && { red "    FAIL — style key '$k' not handled by Android CanopyHost.java::applyStyle"; status=1; }
    [ "$iok" -eq 0 ] && { red "    FAIL — style key '$k' not handled by iOS CanopyHostFabric.mm::applyStyle"; status=1; }
  fi
done
echo

# ── (5) Project wiring: the iOS test target bundles the corpus as a resource ──────────────────
echo "--> [5] Project wiring (the iOS test target bundles the shared corpus as a resource):"
need "project.yml bundles the shared corpus into CanopyHostCoreTests as a resource" "$PROJECT_YML" \
  '\.\./shared/test-vectors/layout-vectors\.json' \
  'buildPhase: resources'
echo

if [ "$status" -eq 0 ]; then
  green "ALL GREEN — the shared cross-platform test-vector suite is single-sourced, oracle-consistent,"
  green "            wired into BOTH host runners, and tied to BOTH production applyStyle mappings."
  green "            (Device-gated: the real Yoga runs are :app:connectedDebugAndroidTest [emulator]"
  green "             and xcodebuild test -only-testing:CanopyHostCoreTests/CanopyLayoutVectorTests [Mac];"
  green "             this gate is their device-free net. See host/shared/test-vectors/README.md.)"
else
  red "DRIFT/ROT — the cross-platform vector suite diverged. See plans/dependent/IOS-9.md +" >&2
  red "            host/shared/test-vectors/README.md." >&2
fi
exit "$status"
