#!/usr/bin/env bash
# check-rtl-parity.sh — REACH-1: keep RTL / logical-edge layout at PARITY across the two hosts.
#
# WHY THIS EXISTS
# ---------------
# Logical, writing-direction-aware edges (paddingStart/paddingEnd, marginStart/marginEnd,
# start/end) + `direction` are the load-bearing primitive for right-to-left locales: ONE view
# definition must mirror itself on both Android and iOS. That only holds if BOTH hosts map every
# logical key onto the matching Yoga START/END edge (and `direction "rtl"` onto RTL) — and keep
# doing so as the hosts evolve. A drift where Android grows a key iOS lacks (or vice-versa), or
# where someone wires `paddingStart` to the LEFT edge instead of START, silently de-mirrors RTL
# users with no compile error. This device-free structural gate greps both hosts (and the public
# .can API) and fails CI on any asymmetry — no emulator/simulator required.
#
# It is STRUCTURAL, not behavioural: it proves the key→edge wiring exists and matches across hosts.
# Actual pixel mirroring is exercised by the on-device suites (VS-1); this gate is the always-on
# floor that keeps the two native mappings from drifting apart between device runs.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AND="$ROOT/host/android/app/src/main/java/com/canopyhost/CanopyHost.java"
IOS="$ROOT/host/ios/CanopyHostCore/Render/CanopyHostFabric.mm"
API="$ROOT/package/src/Native/Attributes.can"
fail=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✗ %s\033[0m\n' "$*" >&2; fail=1; }

for f in "$AND" "$IOS" "$API"; do
  [ -f "$f" ] || { bad "missing source file: ${f#$ROOT/}"; }
done
[ "$fail" -eq 0 ] || { echo; echo "rtl-parity check FAILED (sources moved)." >&2; exit "$fail"; }

# 1. The public API must EXPOSE every logical attribute (else app code can't reach it).
echo "==> [1/4] public API exposes the logical-edge + direction attributes"
for attr in paddingStart paddingEnd marginStart marginEnd start end direction; do
  if grep -qE "(^|[ ,(])$attr([ ,)]|$)" "$API" && grep -qE "^$attr :" "$API"; then
    ok "Native.Attributes exposes + defines \`$attr\`"
  else
    bad "Native.Attributes is missing \`$attr\` (exposing list + definition)"
  fi
done

# 2. Android host maps each logical edge onto the matching Yoga START/END edge.
echo "==> [2/4] Android host (CanopyHost.java) maps logical edges → YogaEdge.START/END"
and_has() { grep -qF "$1" "$AND" && ok "Android: $2" || bad "Android missing: $2  [$1]"; }
and_has 'case "paddingStart": if (f != null) y.setPadding(YogaEdge.START'  'paddingStart → YogaEdge.START'
and_has 'case "paddingEnd":   if (f != null) y.setPadding(YogaEdge.END'    'paddingEnd → YogaEdge.END'
and_has 'case "marginStart":  if (f != null) y.setMargin(YogaEdge.START'   'marginStart → YogaEdge.START'
and_has 'case "marginEnd":    if (f != null) y.setMargin(YogaEdge.END'     'marginEnd → YogaEdge.END'
and_has 'case "start":  if (f != null) y.setPosition(YogaEdge.START'       'start → YogaEdge.START'
and_has 'case "end":    if (f != null) y.setPosition(YogaEdge.END'         'end → YogaEdge.END'
grep -qF 'y.setDirection("rtl".equals(s) ? YogaDirection.RTL' "$AND" \
  && ok 'Android: direction "rtl" → YogaDirection.RTL' || bad 'Android missing: direction "rtl" → YogaDirection.RTL'
grep -qF 'import com.facebook.yoga.YogaDirection;' "$AND" \
  && ok 'Android: imports YogaDirection' || bad 'Android missing: import com.facebook.yoga.YogaDirection;'
grep -qF 'if (key.endsWith("Start")) return YogaEdge.START;' "$AND" \
  && ok 'Android: edgeFor() resets Start → START' || bad 'Android: edgeFor() does not map Start (reset would clear the wrong edge)'
grep -qF 'if (key.endsWith("End")) return YogaEdge.END;' "$AND" \
  && ok 'Android: edgeFor() resets End → END' || bad 'Android: edgeFor() does not map End'

# 3. iOS host maps each logical edge onto the matching YGEdgeStart/End (mirror of Android).
echo "==> [3/4] iOS host (CanopyHostFabric.mm) maps logical edges → YGEdgeStart/End"
ios_has() { grep -qF "$1" "$IOS" && ok "iOS: $2" || bad "iOS missing: $2  [$1]"; }
ios_has 'isEqualToString:@"paddingStart"]) { if (hasF) YGNodeStyleSetPadding(y, YGEdgeStart' 'paddingStart → YGEdgeStart'
ios_has 'isEqualToString:@"paddingEnd"]) { if (hasF) YGNodeStyleSetPadding(y, YGEdgeEnd'      'paddingEnd → YGEdgeEnd'
ios_has 'isEqualToString:@"marginStart"]) { if (hasF) YGNodeStyleSetMargin(y, YGEdgeStart'    'marginStart → YGEdgeStart'
ios_has 'isEqualToString:@"marginEnd"]) { if (hasF) YGNodeStyleSetMargin(y, YGEdgeEnd'        'marginEnd → YGEdgeEnd'
ios_has 'isEqualToString:@"start"]) { if (hasF) YGNodeStyleSetPosition(y, YGEdgeStart'        'start → YGEdgeStart'
ios_has 'isEqualToString:@"end"]) { if (hasF) YGNodeStyleSetPosition(y, YGEdgeEnd'            'end → YGEdgeEnd'
grep -qF '[s isEqualToString:@"rtl"] ? YGDirectionRTL' "$IOS" \
  && ok 'iOS: direction "rtl" → YGDirectionRTL' || bad 'iOS missing: direction "rtl" → YGDirectionRTL'
grep -qF 'if ([key hasSuffix:@"Start"]) return YGEdgeStart;' "$IOS" \
  && ok 'iOS: edgeFor() resets Start → YGEdgeStart' || bad 'iOS: edgeFor() does not map Start (reset would clear the wrong edge)'
grep -qF 'if ([key hasSuffix:@"End"]) return YGEdgeEnd;' "$IOS" \
  && ok 'iOS: edgeFor() resets End → YGEdgeEnd' || bad 'iOS: edgeFor() does not map End'

# 4. The corpus documents (and so compile-verifies, via check-llms-corpus.sh) the RTL idiom.
echo "==> [4/4] the idiom corpus carries the RTL example (kept compile-verified by AAG-1)"
CORPUS="$ROOT/corpus/src/Main.can"
if grep -qE 'A\.(paddingStart|direction)' "$CORPUS" 2>/dev/null; then
  ok "corpus/src/Main.can uses the logical-edge / direction idiom"
else
  bad "corpus/src/Main.can no longer shows the RTL idiom (AAG-1 would stop compile-verifying it)"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "rtl-parity OK — logical edges + direction are wired identically on both hosts."
else
  echo "rtl-parity check FAILED — the two hosts have drifted on RTL/logical-edge layout." >&2
fi
exit "$fail"
