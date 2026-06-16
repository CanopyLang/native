#!/usr/bin/env bash
# check-beforeafter-parity.sh — L-I4 device-free gate for the SHARED before/after wipe-compositor
# parity test-vector suite (NO Mac, NO emulator required).
#
# L-I4's deliverable: the iOS Before/After compositor (CanopyBeforeAfterView in CanopyHostFabric.mm,
# the port of the Android BeforeAfterView from L-A1) + a platform-neutral parity test-vector corpus so
# the two hand-written hosts cannot silently drift on the wipe interaction (master-plan Risk R5 — the
# same risk the IOS-9 layout-vector suite covers, here for the compositor). The anti-drift design: both
# hosts delegate the wipe's pure MATH to ONE shared header host/shared/cpp/CanopyBeforeAfter.h (the iOS
# view calls canopy::beforeafter::*; the Android view calls CanopyBeforeAfterMath, the line-for-line
# Java twin), and ONE corpus host/shared/test-vectors/beforeafter-vectors.json asserts that math on
# BOTH hosts (iOS XCTest CanopyBeforeAfterVectorTests.mm on a Simulator; Android JVM unit test
# CanopyBeforeAfterMathTest on the build host).
#
# The two on-device/Simulator runs are environment-gated; this gate is the cheap Linux net that runs on
# every commit and proves, device-free, that the suite is WIRED and CANNOT SILENTLY ROT:
#
#   (1) The corpus is internally consistent + every expected value is reproduced by an INDEPENDENT
#       oracle (validate-beforeafter.js — a second from-scratch implementation, incl. a from-scratch %g
#       formatter, so a corpus typo cannot self-agree). The on-Linux stand-in for the device runs.
#   (2) BOTH hosts' compositors delegate to the SINGLE source of truth: the iOS CanopyBeforeAfterView
#       calls canopy::beforeafter::* (not inline math) and the Android BeforeAfterView calls
#       CanopyBeforeAfterMath — so a fix on one host lands on both.
#   (3) The shared C++ header and its Java twin carry the SAME rule set (clamp/split/drag/snap-target/
#       snap-eased/snap-value/cover/commit-payload + the snap duration), so the twin cannot drift from
#       the header unnoticed.
#   (4) BOTH runners exist and consume the corpus: the iOS CanopyBeforeAfterVectorTests.mm includes the
#       shared header and asserts every set; the Android CanopyBeforeAfterMathTest reads the corpus and
#       asserts CanopyBeforeAfterMath against every set.
#   (5) Project wiring: the iOS test target bundles the corpus as a resource (project.yml); the shared
#       header is in the iOS-portable C++ compile gate (check-portable-cpp.sh).
#
# Pure bash + grep + node (no device/SDK/Xcode). Usage:  bash scripts/check-beforeafter-parity.sh
# Exit: 0 = the suite is oracle-consistent, both hosts delegate to the shared math, both runners + the
#           project wiring are present. 1 = the corpus rotted, a host stopped delegating, the twin
#           diverged, a runner stopped consuming the corpus, or wiring is missing.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHARED="$ROOT/host/shared/test-vectors"
CORPUS="$SHARED/beforeafter-vectors.json"
VALIDATOR="$SHARED/validate-beforeafter.js"
HEADER="$ROOT/host/shared/cpp/CanopyBeforeAfter.h"
JAVA_MIRROR="$ROOT/host/android/app/src/main/java/com/canopyhost/views/CanopyBeforeAfterMath.java"
IOS_VIEW="$ROOT/host/ios/CanopyHostCore/Render/CanopyHostFabric.mm"
DROID_VIEW="$ROOT/host/android/app/src/main/java/com/canopyhost/views/BeforeAfterView.java"
IOS_RUNNER="$ROOT/host/ios/Tests/CanopyHostCoreTests/CanopyBeforeAfterVectorTests.mm"
DROID_RUNNER="$ROOT/host/android/app/src/test/java/com/canopyhost/views/CanopyBeforeAfterMathTest.java"
PROJECT_YML="$ROOT/host/ios/project.yml"
PORTABLE_GATE="$ROOT/host/ios/check-portable-cpp.sh"

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

echo "==> Before/After wipe-compositor parity gate (scripts/check-beforeafter-parity.sh) [L-I4]"
echo "    (device-free — both hosts delegate the wipe math to ONE shared header; ONE corpus asserts it"
echo "     on both, proven here by an independent oracle + delegation/wiring checks.)"
echo

# ── (1) Independent oracle: the corpus is consistent + every value reproduced ─────────────────
echo "--> [1] Independent oracle (validate-beforeafter.js — a second from-scratch implementation):"
if ! command -v node >/dev/null 2>&1; then
  red "    FAIL — node is required to run the corpus validator"; status=1
elif [ ! -f "$VALIDATOR" ]; then
  red "    FAIL — validator missing: ${VALIDATOR#$ROOT/}"; status=1
else
  if node "$VALIDATOR" >/tmp/ba-vectors-validate.log 2>&1; then
    green "    OK  — corpus is well-formed and every expected value is oracle-reproduced"
    grep -c '  OK   —' /tmp/ba-vectors-validate.log | sed 's/^/        validated vectors+sets: /'
  else
    red "    FAIL — the corpus validator failed:"; sed 's/^/        /' /tmp/ba-vectors-validate.log | tail -12
    status=1
  fi
fi
echo

# ── (2) BOTH hosts' compositors delegate to the single source of truth ────────────────────────
echo "--> [2] Both production compositors delegate the wipe math to the shared source of truth:"
need "iOS CanopyBeforeAfterView delegates to the shared header (canopy::beforeafter::*)" "$IOS_VIEW" \
  'CanopyBeforeAfter\.h' \
  'canopy::beforeafter::clampFraction' \
  'canopy::beforeafter::splitColumn' \
  'canopy::beforeafter::dragFraction' \
  'canopy::beforeafter::snapTarget' \
  'canopy::beforeafter::snapValue' \
  'canopy::beforeafter::commitPayloadJson'
need "Android BeforeAfterView delegates to the Java twin (CanopyBeforeAfterMath)" "$DROID_VIEW" \
  'CanopyBeforeAfterMath\.clampFraction' \
  'CanopyBeforeAfterMath\.splitColumn' \
  'CanopyBeforeAfterMath\.dragFraction' \
  'CanopyBeforeAfterMath\.snapTarget' \
  'CanopyBeforeAfterMath\.coverRect' \
  'CanopyBeforeAfterMath\.commitPayloadJson'
# The inline float-toString commit payload (the OLD drift) must be GONE from the Android view.
if grep -qE '"\\?\{\\?"fraction\\?":" \+ wipe' "$DROID_VIEW" 2>/dev/null; then
  red "    FAIL — Android BeforeAfterView still concatenates the commit payload inline (the drift L-I4 removed)"
  status=1
else
  green "    OK  — the old inline commit-payload concatenation is gone (shared formatter only)"
fi
echo

# ── (3) The shared header and its Java twin carry the SAME rule set ────────────────────────────
echo "--> [3] The shared C++ header and its Java twin carry the same rules (cannot drift apart):"
RULES="clampFraction splitColumn dragFraction snapTarget snapEased snapValue coverRect commitPayloadJson"
for r in $RULES; do
  hok=1; jok=1
  grep -qE "[ *]$r\b" "$HEADER" || hok=0
  grep -qE "[ .]$r\b" "$JAVA_MIRROR" || jok=0
  if [ "$hok" -eq 1 ] && [ "$jok" -eq 1 ]; then
    green "    OK  — rule '$r' present in BOTH CanopyBeforeAfter.h and CanopyBeforeAfterMath.java"
  else
    [ "$hok" -eq 0 ] && { red "    FAIL — rule '$r' missing from the shared header CanopyBeforeAfter.h"; status=1; }
    [ "$jok" -eq 0 ] && { red "    FAIL — rule '$r' missing from the Java twin CanopyBeforeAfterMath.java"; status=1; }
  fi
done
# The snap duration must be the SAME constant on both sides (260ms / 0.26s).
need "shared header declares the 0.26s snap duration" "$HEADER" 'snapDurationSeconds' '0\.26'
need "Java twin declares the 0.26s snap duration" "$JAVA_MIRROR" 'SNAP_DURATION_SECONDS' '0\.26'
echo

# ── (4) BOTH runners exist and consume the corpus ─────────────────────────────────────────────
echo "--> [4] Both host runners load the corpus and assert the production math:"
need "iOS runner includes the shared header + asserts every vector set" "$IOS_RUNNER" \
  '#import <XCTest/XCTest.h>' \
  'CanopyBeforeAfter\.h' \
  'pathForResource:@"beforeafter-vectors"' \
  'clampVectors' 'splitVectors' 'dragVectors' 'snapTargetVectors' \
  'snapEasedVectors' 'snapTweenVectors' 'coverVectors' 'payloadVectors' \
  'canopy::beforeafter::commitPayloadJson'
need "Android runner reads the canonical corpus + asserts CanopyBeforeAfterMath over every set" "$DROID_RUNNER" \
  'beforeafter-vectors\.json' \
  'CanopyBeforeAfterMath' \
  'clampVectors' 'splitVectors' 'dragVectors' 'snapTargetVectors' \
  'snapEasedVectors' 'snapTweenVectors' 'coverVectors' 'payloadVectors' \
  'commitPayloadJson'
echo

# ── (5) Project wiring: iOS bundles the corpus; the header is in the portable compile gate ─────
echo "--> [5] Project wiring (iOS resource bundle + the shared header in the portable C++ gate):"
need "project.yml bundles the before/after corpus into CanopyHostCoreTests as a resource" "$PROJECT_YML" \
  '\.\./shared/test-vectors/beforeafter-vectors\.json' \
  'buildPhase: resources'
need "check-portable-cpp.sh syntax-checks the shared header in the iOS (non-Android) config" "$PORTABLE_GATE" \
  'CanopyBeforeAfter\.h'
echo

if [ "$status" -eq 0 ]; then
  green "ALL GREEN — the before/after wipe-compositor parity suite is oracle-consistent, both hosts"
  green "            delegate to ONE shared math (header + Java twin, rule-for-rule), both runners"
  green "            consume the corpus, and the project is wired."
  green "            (Device-gated: the real runs are :app:testDebugUnitTest --tests CanopyBeforeAfterMathTest"
  green "             [JVM, runnable here] and xcodebuild test -only-testing:CanopyHostCoreTests/"
  green "             CanopyBeforeAfterVectorTests [Mac/Simulator]. See host/shared/test-vectors/README.md.)"
else
  red "DRIFT/ROT — the before/after parity suite diverged. See plans/dependent/L-I4.md +" >&2
  red "            host/shared/test-vectors/README.md." >&2
fi
exit "$status"
