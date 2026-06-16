#!/usr/bin/env bash
# check-ios-command-seam.sh — IOS-8 structural gate for the imperative-command seam (NO Mac required).
#
# IOS-8's deliverable is the iOS half of the ONE shared imperative-command seam — reconciled with
# AND-3 so there is exactly one global (__fabric_command), one shared host virtual (CanopyHost::
# command), and one JS routing path (__callId → __commandResult), shared by BOTH platforms. The iOS
# host's command() override (focus/blur/measure/scrollTo/scrollToIndex) is the line-for-line twin of
# Android's AND-4 CanopyHost.java::command. Its UIKit behaviours (becomeFirstResponder, the keyboard,
# setContentOffset) need a Simulator and are driven by CanopyHostValidationTests.swift; the pure JSON
# marshalling (parseCallId/measureResultJson/mergeCallId) is pinned device-free by an XCTest.
#
# Because the iOS host CANNOT be compiled off macOS (Xcode/UIKit/Hermes/Yoga link), this gate proves
# — device-free, by structural assertion over the committed sources — that:
#   (A) ONE seam — the shared C++ exposes exactly ONE imperative global (__fabric_command) and ONE
#                  host virtual (command()); IOS-8 did NOT add a second __fabric_callMethod global.
#   (B) JS routing — the walker splices __callId into the outgoing args and routes the async
#                    __commandResult by __callId (with the AND-3 per-handle fallback).
#   (C) Android ref — the AND-4 Java host implements the five ops + the three pure helpers (the
#                     parity reference the iOS twin mirrors).
#   (D) iOS host — CanopyHostFabric.mm overrides command(), dispatches the SAME five ops, defers the
#                  layout-sensitive ones, echoes __callId, and emits via the __commandResult path; and
#                  carries the SAME three pure helpers (parseCallId/measureResultJson/mergeCallId).
#   (E) device-free test — CanopyValidationLedgerTests.mm pins the pure marshalling (twin of the
#                          Java CanopyHostCommandTest).
#
# Pure bash + grep (no device, no SDK, no compiler). Usage:  bash scripts/check-ios-command-seam.sh
# Exit: 0 = the iOS command seam is structurally complete + Android-parity, reconciled to ONE seam.
#       1 = a seam is missing/drifted, or a second imperative global crept in.

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
UITEST="$IOS/Tests/CanopyHostUITests/CanopyHostValidationTests.swift"
LEDGER_DOC="$IOS/PART5-LEDGER.md"
DROID_TEST="$DROID/test/java/com/canopyhost/CanopyHostCommandTest.java"

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

# absent <label> <file> <pattern> — the pattern must NOT appear (it would be a second seam).
absent() {
  local label="$1" file="$2" pat="$3"
  if [ -f "$file" ] && grep -qE -- "$pat" "$file"; then
    red "    FAIL — $label: forbidden pattern present in ${file#$ROOT/}: $pat"; status=1
  else
    green "    OK  — $label"
  fi
}

echo "==> iOS imperative-command seam gate (scripts/check-ios-command-seam.sh)"
echo "    (structural — the iOS host cannot be compiled off macOS; this proves the ONE seam exists + matches Android)"
echo

# ── (A) ONE shared seam: __fabric_command + CanopyHost::command, NO second global ────────────────
echo "--> [A] the shared C++ exposes exactly ONE imperative seam (reconciled with AND-3):"
need "the shared host virtual command() exists + documents the reconciliation" "$FABRIC_H" \
  'virtual void command\(Handle view, const std::string& name, const std::string& argsJson\)' \
  'RECONCILED INTO THIS'
need "exactly one imperative global is installed (__fabric_command)" "$FABRIC_CPP" \
  'installFn\(runtime, "__fabric_command", 3' \
  'host->command\(asInt\(rt, a\[0\]\), name, args\)'
# IOS-8 reconciles its proposed __fabric_callMethod INTO __fabric_command; a second global would
# fork the seam. Assert it never appears as an installed/forwarded global on any side.
absent "no second __fabric_callMethod global in the shared C++"  "$FABRIC_CPP" 'installFn\(runtime, "__fabric_callMethod"'
absent "no second __fabric_callMethod global in the JS walker"   "$WALKER"     'h\.__fabric_callMethod'
absent "no second callViewMethod virtual in the iOS host"        "$IOS_FABRIC" 'callViewMethod'
echo

# ── (B) JS routing — __callId splice + __commandResult dispatch ──────────────────────────────────
echo "--> [B] the walker threads __callId and routes the async __commandResult by it:"
need "walker splices __callId out + invokes the ONE global + routes the result back" "$WALKER" \
  'outArgs\.__callId = callId' \
  'h\.__fabric_command\(handle, name, outArgs\)' \
  "eventName === '__commandResult'" \
  '_Native_dispatchCommandResult'
echo

# ── (C) Android AND-4 reference (the parity twin the iOS host mirrors) ────────────────────────────
echo "--> [C] the Android AND-4 host is the parity reference (five ops + three pure helpers):"
need "CanopyHost.java::command dispatches the five ops + echoes __callId" "$DROID_HOST" \
  'public void command\(int h, String name, String argsJson\)' \
  'case "focus":' 'case "blur":' 'case "measure":' 'case "scrollTo":' 'case "scrollToIndex":' \
  'parseCallId' 'measureResultJson' 'mergeCallId' \
  'emitEvent\(h, "__commandResult"'
echo

# ── (D) the iOS host override (IOS-8) — same ops, deferred, __callId echo, __commandResult emit ──
echo "--> [D] CanopyHostFabric.mm overrides command() as the faithful iOS twin of AND-4:"
need "the override + the five op dispatch arms are present" "$IOS_FABRIC" \
  'void command\(Handle h, const std::string& name, const std::string& argsJson\) override' \
  'isEqualToString:@"focus"\]\)' \
  'isEqualToString:@"blur"\]\)' \
  'isEqualToString:@"measure"\]\)' \
  'isEqualToString:@"scrollTo"\]\)' \
  'isEqualToString:@"scrollToIndex"\]\)'
need "focus/measure DEFER to the next runloop turn (the RN focus-timing fix)" "$IOS_FABRIC" \
  'commandFocus' 'commandMeasure' 'commandScrollTo' 'commandScrollToIndex' \
  'becomeFirstResponder' 'resignFirstResponder' \
  'dispatch_async\(dispatch_get_main_queue\(\)' \
  'convertRect:v\.bounds toView:nil' \
  'setContentOffset:'
need "the iOS host carries the SAME three pure marshalling helpers + emits __commandResult" "$IOS_FABRIC" \
  'static std::string parseCallId\(NSDictionary\* args\)' \
  'static std::string measureResultJson\(' \
  'static std::string mergeCallId\(' \
  'emit_\(h, "__commandResult", mergeCallId\(callId, resultBody\)\)'
echo

# ── (E) device-free test — the pure marshalling pinned on the build host ─────────────────────────
echo "--> [E] device-free XCTest pins the pure marshalling (twin of CanopyHostCommandTest.java):"
need "CanopyValidationLedgerTests covers parseCallId/measureResultJson/mergeCallId" "$TEST" \
  'testCommandParseCallIdNumericEchoesAsBareNumber' \
  'testCommandParseCallIdStringEchoesAsQuotedLiteral' \
  'testCommandParseCallIdAbsentOrNullIsNullLiteral' \
  'testCommandMeasureResultJsonEmitsRnContractCompacted' \
  'testCommandMeasureResultKeepsFractionalLengths' \
  'testCommandMergeCallIdInjectsCallIdFirstAndKeepsBody' \
  'testCommandMergeCallIdEmptyBodyStillValid' \
  'testCommandMergeCallIdOverMeasureResultRoundTrips'
# the same three pure helpers are unit-tested on the Android side — keep both alive.
need "the Android CanopyHostCommandTest still pins the parity contract" "$DROID_TEST" \
  'parseCallId_numericEchoesAsBareNumber' \
  'measureResultJson_emitsRnMeasureContract' \
  'mergeCallId_injectsCallIdFirstAndKeepsBody'
echo

# ── (F) the Simulator (Mac-gated) legs — authored, exercise the real UIKit behaviours ────────────
echo "--> [F] the XCUITest legs drive the real UIKit behaviours on a Simulator [MAC-REQUIRED]:"
need "CanopyHostValidationTests covers focus/measure/scroll command legs" "$UITEST" \
  'func test_5_3b_command_focusBlur' \
  'func test_5_3b_command_measure' \
  'func test_5_3b_command_scrollTo' \
  'app\.keyboards\.firstMatch' \
  'requireSurface\("gallery-command'
need "the ledger documents the IOS-8 imperative-command seam section" "$LEDGER_DOC" \
  'Imperative-command seam \(IOS-8\)' \
  'check-ios-command-seam\.sh'
echo

if [ "$status" -eq 0 ]; then
  green "ALL GREEN — the iOS imperative-command seam is structurally complete, reconciled to ONE"
  green "            __fabric_command seam, and is the faithful twin of Android's AND-4 host."
  green "            (Mac-gated: a real Simulator focus/measure/scroll run is in CanopyHostValidationTests.swift.)"
else
  red "REGRESSION — the iOS command seam drifted from the ONE-seam / Android contract. See plans/dependent/IOS-8.md." >&2
fi
exit "$status"
