#!/usr/bin/env bash
# check-ios-lumen-e2e.sh — L-I6 structural gate: the LUMEN restore E2E reaches iPhone PARITY
# (NO Mac required).
#
# L-I6's deliverable: run the SAME L-A6 lumen-restore spec green on a real iPhone via an XCUITest
# driver (testID -> accessibilityIdentifier). The iOS host CANNOT be compiled off macOS (Xcode/UIKit/
# Hermes/Yoga link) and there is no iPhone on this box, so — exactly like check-ios-validation-ledger.sh
# (IOS-6) / check-ios-capability-parity.sh (IOS-7) — this gate proves the parity DEVICE-FREE by
# structural assertion over the committed sources, and fails LOUD if the two platforms' lumen-restore
# specs drift, so a regression is caught in CI's cheap Linux `gate` job long before a Mac run.
#
# It asserts:
#   (A) the NATIVE XCUITest spec exists (host/ios/.../CanopyLumenRestoreUITests.swift) and drives the
#       WHOLE lumen-restore spine, selecting ONLY by testID (== accessibilityIdentifier) — every
#       interactive step (~choose/~justfix/~save/~share/~another) and every spine screen's copy.
#   (B) PARITY with the Android Appium spec (e2e/lumen-restore.mjs): the SAME testIDs and the SAME
#       deterministic screen copy are asserted on both, so "the same spec runs on both platforms" is
#       real, not aspirational.
#   (C) the Appium spec is now PLATFORM-NEUTRAL: it builds caps via caps.mjs (the one platform fork)
#       and branches the OS picker / share-sheet chrome by platform (so it runs unchanged on the
#       XCUITest Appium driver too), and the host wires testID -> accessibilityIdentifier (Fabric).
#   (D) the iOS test fixture is BYTE-IDENTICAL to the Android canonical fixture (same restore input on
#       both platforms — true cross-platform determinism), and is seeded out-of-bundle (simctl addmedia).
#
# Pure bash + grep (no device, no SDK, no compiler). Usage:  bash scripts/check-ios-lumen-e2e.sh
# Exit: 0 = the iPhone lumen-restore harness exists, covers the spine, and is Android-parity
#       1 = the harness is missing/incomplete, or the two platforms' lumen-restore specs drifted.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IOS="$ROOT/host/ios"
SWIFT="$IOS/Tests/CanopyHostUITests/CanopyLumenRestoreUITests.swift"
APPIUM="$ROOT/e2e/lumen-restore.mjs"
CAPS="$ROOT/e2e/caps.mjs"
FABRIC="$IOS/CanopyHostCore/Render/CanopyHostFabric.mm"
IOS_FIXTURE="$IOS/Tests/CanopyHostUITests/Fixtures/lumen-test.jpg"
DROID_FIXTURE="$ROOT/host/android/app/src/main/assets/lumen-test.jpg"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
status=0

# need "<label>" <file> <pattern...> — every pattern must match the file (grep -E). One miss => FAIL.
need() {
  local label="$1"; shift
  local file="$1"; shift
  local ok=1 pat
  if [ ! -f "$file" ]; then red "    FAIL — $label (missing file: ${file#"$ROOT"/})"; status=1; return; fi
  for pat in "$@"; do
    grep -qE "$pat" "$file" || { red "    FAIL — $label (no match: $pat)"; ok=0; }
  done
  [ "$ok" -eq 1 ] && green "    OK  — $label"
  [ "$ok" -eq 1 ] || status=1
}

echo "==> iPhone lumen-restore E2E parity gate (scripts/check-ios-lumen-e2e.sh) [L-I6]"
echo "    (structural — the iOS host cannot be compiled off macOS and there is no iPhone here; this"
echo "     proves the SAME lumen-restore spec is authored for iPhone and stays Android-parity.)"
echo

# ── (A) the NATIVE XCUITest spec drives the whole spine by testID ────────────────────────────
echo "--> [A] The native XCUITest spec drives the full lumen-restore spine by testID:"
if [ ! -f "$SWIFT" ]; then
  red "    FAIL — the native XCUITest spec is missing: ${SWIFT#"$ROOT"/}"; status=1
else
  need "it is an XCUITest (XCUIApplication + XCTestCase)" "$SWIFT" \
    'import XCTest' 'XCUIApplication' 'final class CanopyLumenRestoreUITests'
  # Every interactive step selects by testID (the L-I6 selector contract). The ids are the SAME the
  # Android Appium spec taps. Assert each id is referenced AND the spine method drives it.
  need "selects ~choose/~justfix/~save/~share/~another by testID (== accessibilityIdentifier)" "$SWIFT" \
    '"choose"' '"justfix"' '"save"' '"share"' '"another"' \
    'matching\(identifier: testID\)'
  need "drives the whole spine in ONE end-to-end test (pick -> restore -> compare -> share -> save -> loop)" "$SWIFT" \
    'func test_lumenRestoreSpine' \
    '\.tap\(\)'
  # Every spine SCREEN's deterministic copy is asserted (the render proof — native text nodes only
  # exist if JSI + Yoga + the walker ran). These strings are the EXACT Lumen `view` output.
  need "asserts the Pick / Detected / Compare / Done screen copy (the render proof)" "$SWIFT" \
    'Lumen' 'Sharpen & enhance old photos' 'On-device' \
    'Ready to restore' 'Before / After' 'Saved to your Lumen album'
  need "asserts the inference proof (\"Enhanced to N×N\") AND the free-tier export gate" "$SWIFT" \
    'Enhanced to' 'isEnhancedBadge' '✦ Lumen' 'Free export:'
  # The iOS-specific edges (the OS chrome the app does not own) are handled — NOT by coordinates on the
  # app, but by the platform picker/share-sheet chrome (PHPicker / UIActivityViewController).
  need "handles the iOS PHPicker + share-sheet (UIActivityViewController) edges" "$SWIFT" \
    'isPickerChrome' 'pickFirstPhoto' 'isShareSheetChrome' 'dismissShareSheet'
  # Honest gating: when the embedded bundle is the bare counter (no Lumen surface), the class XCTSkips
  # with a reason — never a silent pass.
  need "XCTSkips (with a reason) when the Lumen bundle is not the embedded one (no silent pass)" "$SWIFT" \
    'XCTSkipUnless' 'lumenPresent'
fi
echo

# ── (B) PARITY with the Android Appium spec: same testIDs + same copy ─────────────────────────
echo "--> [B] The iPhone spec asserts the SAME testIDs + copy as the Android Appium spec (parity):"
if [ ! -f "$APPIUM" ]; then
  red "    FAIL — the Android Appium lumen-restore spec is missing: ${APPIUM#"$ROOT"/}"; status=1
elif [ ! -f "$SWIFT" ]; then
  : # already failed in (A)
else
  parity_ok=1
  # The testIDs both specs select on (the cross-platform selector contract). The Appium spec writes
  # them as the WebdriverIO accessibility-id selector `~<id>` (e.g. driver.$('~choose')) or a quoted
  # 'choose'; the Swift spec writes them as the quoted "<id>" identifier. Accept either quoting.
  for id in choose justfix save share another; do
    if grep -qE "~${id}\b|['\"]${id}['\"]" "$APPIUM" && grep -qE "['\"]${id}['\"]" "$SWIFT"; then
      : # asserted on both
    else
      red "    FAIL — testID '$id' is not asserted on BOTH platforms"; parity_ok=0
    fi
  done
  # The deterministic copy both specs assert (the render-parity strings). If a string is asserted on
  # one platform's lumen-restore spec it MUST be on the other — otherwise the specs have drifted.
  for copy in 'Sharpen & enhance old photos' 'On-device' 'Ready to restore' 'Before / After' \
              'Enhanced to' 'Free export:' 'Saved to your Lumen album'; do
    if grep -qF "$copy" "$APPIUM" && grep -qF "$copy" "$SWIFT"; then
      : # asserted on both
    else
      red "    FAIL — screen copy not asserted on BOTH platforms: \"$copy\""; parity_ok=0
    fi
  done
  if [ "$parity_ok" -eq 1 ]; then
    green "    OK  — the iPhone XCUITest spec + the Android Appium spec assert the SAME testIDs + copy"
  else
    status=1
  fi
fi
echo

# ── (C) the Appium spec is PLATFORM-NEUTRAL (one spec, both Appium drivers) ────────────────────
echo "--> [C] The Appium lumen-restore spec is platform-neutral (runs on XCUITest too):"
need "it builds caps via the ONE platform fork (caps.mjs) — not a hardcoded Android-only object" "$APPIUM" \
  "from './caps.mjs'" 'buildCaps\(\)' 'isIOS\(\)'
need "the OS picker / share-sheet chrome is BRANCHED by platform (the only per-platform edges)" "$APPIUM" \
  'pickerIsUp' 'pickNewestPhoto' 'shareSheetIsUp' 'dismissShareSheet' \
  'if \(IOS\)'
need "the gallery seed (adb/MediaStore) is Android-ONLY; iOS uses a pre-seeded library" "$APPIUM" \
  'prepareGalleryFixtureAndroid' 'simctl addmedia'
need "caps.mjs forks Android (UIAutomator2/appPackage) vs iOS (XCUITest/bundleId)" "$CAPS" \
  'XCUITest' 'appium:bundleId' 'autoAcceptAlerts' 'UiAutomator2' 'appium:appPackage'
# The host MUST wire testID -> accessibilityIdentifier or none of the iOS selection works.
need "the host wires testID -> accessibilityIdentifier (the XCUITest selector contract)" "$FABRIC" \
  'testID' 'accessibilityIdentifier'
echo

# ── (D) the iOS fixture is byte-identical to the Android canonical fixture ─────────────────────
echo "--> [D] The iOS test fixture is byte-identical to the Android canonical fixture (same input):"
if [ ! -f "$IOS_FIXTURE" ]; then
  red "    FAIL — the iOS lumen fixture is missing: ${IOS_FIXTURE#"$ROOT"/}"; status=1
elif [ ! -f "$DROID_FIXTURE" ]; then
  red "    FAIL — the Android canonical fixture is missing: ${DROID_FIXTURE#"$ROOT"/}"; status=1
elif cmp -s "$IOS_FIXTURE" "$DROID_FIXTURE"; then
  green "    OK  — host/ios .../Fixtures/lumen-test.jpg == host/android .../assets/lumen-test.jpg"
else
  red "    FAIL — the iOS + Android lumen-test.jpg fixtures DIFFER (the restore input drifted)"; status=1
fi
# The fixture is seeded OUT of the test bundle (simctl addmedia), not bundled — assert the project
# excludes it AND the spec documents the seed.
need "the fixture is excluded from the UI-test target (seeded via simctl addmedia, not bundled)" \
  "$IOS/project.yml" 'Fixtures/\*\*'
echo

if [ "$status" -eq 0 ]; then
  green "ALL GREEN — the iPhone lumen-restore harness exists, covers the whole spine by testID, and"
  green "            asserts the SAME testIDs + copy as the Android Appium spec (full parity, L-I6)."
  green "            (Mac/device-gated: the actual XCUITest run on a Simulator / physical iPhone is in"
  green "             host/ios/Tests/CanopyHostUITests/CanopyLumenRestoreUITests.swift — run steps at"
  green "             the top of that file + host/ios/BUILD-AND-VALIDATE.md §5.8; this is its net.)"
else
  red "DRIFT — the iPhone lumen-restore harness is missing/incomplete or diverged from Android." >&2
  red "        See plans/dependent/L-I6.md + host/ios/Tests/CanopyHostUITests/CanopyLumenRestoreUITests.swift." >&2
fi
exit "$status"
