#!/usr/bin/env bash
# check-ios-validation-ledger.sh — IOS-6 structural gate for the FULL Part-5 iOS validation ledger
# (NO Mac required).
#
# IOS-6's deliverable is the iOS validation checklist/harness mirroring the Android device-validated
# ledger — every Part-5 gate (render, events, ScrollView/TextInput/Image/Switch/Modal/BeforeAfter,
# the anim driver, every C1 capability, streaming) driven on a Simulator via XCUITest + ObjC++ XCTest
# until the ledger is green. The Simulator run itself is [MAC-REQUIRED] and is authored in
# Tests/CanopyHostUITests/CanopyHostValidationTests.swift (+ the device-free legs in
# Tests/CanopyHostCoreTests/CanopyValidationLedgerTests.mm); the exact run steps are in
# host/ios/BUILD-AND-VALIDATE.md §5 and host/ios/PART5-LEDGER.md.
#
# Because the iOS host CANNOT be compiled off macOS (Xcode/UIKit/Hermes/Yoga link), this gate proves
# — device-free, by structural assertion over the committed iOS sources — that EVERY Part-5 gate has
# its load-bearing seam present in the host AND that the validation harness (the XCUITest + the
# ObjC++ XCTest) actually exercises it. It is the IOS-6 twin of check-ios-devloop.sh (DEV-12), but
# covers the whole Part-5 checklist instead of just the dev loop. It fails LOUD if a gate's seam is
# missing or its harness coverage drifted, so a regression is caught in CI's cheap Linux `gate` job
# long before a Mac build runs — exactly the role check-rn-coupling.sh / check-ios-devloop.sh play.
#
# What it asserts, gate-family by gate-family (mirrors BUILD-AND-VALIDATE.md §5.1–§5.7):
#   (1) Render   — root pinned to surface_, Yoga in POINTS (no density multiply), boot-time ABI canary,
#                  CanopyColor CSS parser, styling (per-corner masks/shadow/transform), diff-null reset.
#   (2) Events   — exact-token `press`, the gesture set ({dx,dy,vx,vy} in points), setEvents idempotency.
#   (3) Components— ScrollView (separate content root), TextInput (single+multiline), Image (declarative
#                  + blob), Switch, Modal (own root, keyWindow present, visible-last), BeforeAfter wipe.
#   (4) Animation— the CADisplayLink driver, base opacity/transform cache, remove-during-anim safety.
#   (5) Caps     — every C1 module is PACKAGE-RESIDENT (its native.json declares it + native/ios ships
#                  it), autolinked via the generated CanopyGeneratedCaps() and routed through the
#                  by-name bridge (immutable dispatcher, no per-cap boot edit). Echo + Photos stay
#                  host-resident by design (first-light bridge / host-driven picker).
#   (6) Link/thread — exactly ONE globalBlobRegistry(), runtime touched only on main (postToJs hop).
#   (H) Harness  — the XCUITest validation suite + the ObjC++ XCTest exist and name every gate family,
#                  and the parity-with-Android claims (testID->accessibilityIdentifier, both-platform
#                  package impls) hold so "the SAME spec body runs on both platforms" is real.
#
# Pure bash + grep (no device, no SDK, no compiler). Usage:  bash scripts/check-ios-validation-ledger.sh
# Exit: 0 = every Part-5 gate's seam + its validation-harness coverage is present and Android-parity
#       1 = a gate seam is missing/drifted, or the harness stopped covering it.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IOS="$ROOT/host/ios"
DROID="$ROOT/host/android/app/src/main/java/com/canopyhost"

FABRIC="$IOS/CanopyHostCore/Render/CanopyHostFabric.mm"
VC="$IOS/CanopyHostCore/Boot/CanopyHostViewController.mm"
MODHOST="$IOS/CanopyHostCore/Boot/CanopyModuleHost.mm"
BLOBHOST="$IOS/CanopyHostCore/Bridge/CanopyBlobRegistryHost.mm"
NATIVEBRIDGE="$IOS/CanopyHostCore/Bridge/CanopyNativeModule.mm"
STREAMBASE="$IOS/CanopyHostCore/Bridge/CanopyStreamingModuleBase.mm"
UITEST="$IOS/Tests/CanopyHostUITests/CanopyHostValidationTests.swift"
SMOKE_UITEST="$IOS/Tests/CanopyHostUITests/CanopyHostUITests.swift"
ENGTEST="$IOS/Tests/CanopyHostCoreTests/CanopyEngineTests.mm"
LEDGERTEST="$IOS/Tests/CanopyHostCoreTests/CanopyValidationLedgerTests.mm"
LEDGER_DOC="$IOS/PART5-LEDGER.md"
# Android counterparts the ledger must stay parity with.
DROID_FABRIC_DIR="$DROID/views"
DROID_MODHOST="$ROOT/host/android/app/src/main/jni/CanopyHostJni.cpp"

# Monorepo root holding the canopy/* capability PACKAGES. After AUTO-E-DELETE (plan §5 Phase E),
# every capability is package-resident — it declares itself in its package's native.json and ships
# its native/ios + native/android impl — so the ledger checks the PACKAGE, not a hardcoded boot list.
# Resolve like the rest of the toolchain (Autolink.hs resolveMonorepo): $CANOPY_MONOREPO, else the
# canopy/native repo's parent (…/canopy), else ~/projects/canopy.
MONOREPO="${CANOPY_MONOREPO:-}"
if [ -z "$MONOREPO" ]; then
  cand="$(cd "$ROOT/.." && pwd)"
  if [ -d "$cand/image/native" ]; then MONOREPO="$cand"; else MONOREPO="$HOME/projects/canopy"; fi
fi
# Map a capability NAME to the package dir that ships it (the iOS module file is Canopy<Name>Module.mm
# under <pkg>/native/ios; the native.json declares "<Name>"). Navigation ships Lifecycle + AppShell.
capPkg() {
  case "$1" in
    Image) echo image ;; Album) echo album ;; ShareImage) echo share-image ;;
    StorageSecure) echo storage-secure ;; Notify) echo notify ;; Http) echo http ;;
    Platform) echo platform ;; Vibration) echo vibration ;; Haptics) echo haptics ;;
    Battery) echo battery ;; DeviceInfo) echo device-info ;; NetInfo) echo net-info ;;
    Brightness) echo brightness ;; Lifecycle|AppShell) echo navigation ;; Billing) echo billing ;;
    *) echo "" ;;
  esac
}
# capInPackage <Name> — true if the capability is package-resident: its package's native.json names
# it (declared module) AND the package ships a native/ios impl. This is the post-Phase-E source of
# truth (mirrors how the web compiler reads each package's external/*.js, never a central list).
capInPackage() {
  local name="$1" pkg; pkg="$(capPkg "$name")"
  [ -n "$pkg" ] || return 1
  local nj="$MONOREPO/$pkg/native.json"
  [ -f "$nj" ] || return 1
  grep -qE "\"name\"[[:space:]]*:[[:space:]]*\"$name\"" "$nj" || return 1
  # The iOS impl ships under the package (native/ios), NOT the host (the Phase E guarantee).
  [ -f "$MONOREPO/$pkg/native/ios/Canopy${name}Module.mm" ]
}

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
status=0

# need <label> <file> <pattern...> — every pattern (extended regex) must be present in the file.
need() {
  local label="$1" file="$2"; shift 2
  if [ ! -f "$file" ]; then red "    FAIL — $label: missing file ${file#$ROOT/}"; status=1; return; fi
  local miss=()
  local pat
  for pat in "$@"; do
    grep -qE -- "$pat" "$file" || miss+=("$pat")
  done
  if [ "${#miss[@]}" -gt 0 ]; then
    red "    FAIL — $label (${file#$ROOT/}) is missing:"
    local m
    for m in "${miss[@]}"; do echo "        · $m"; done
    status=1
  else
    green "    OK  — $label"
  fi
}

# absent <label> <file> <pattern...> — NONE of the patterns may appear (the anti-regression leg).
absent() {
  local label="$1" file="$2"; shift 2
  if [ ! -f "$file" ]; then red "    FAIL — $label: missing file ${file#$ROOT/}"; status=1; return; fi
  local hit=()
  local pat
  for pat in "$@"; do
    grep -qE -- "$pat" "$file" && hit+=("$pat")
  done
  if [ "${#hit[@]}" -gt 0 ]; then
    red "    FAIL — $label (${file#$ROOT/}) must NOT contain:"
    local h
    for h in "${hit[@]}"; do echo "        · $h"; done
    status=1
  else
    green "    OK  — $label"
  fi
}

echo "==> iOS Part-5 validation-ledger gate (scripts/check-ios-validation-ledger.sh) [IOS-6]"
echo "    (structural — the iOS host cannot be compiled off macOS; this proves every Part-5 gate's"
echo "     seam exists, mirrors Android, and is covered by the XCUITest + ObjC++ XCTest harness.)"
echo

# ── (1) RENDER GATES (BUILD-AND-VALIDATE.md §5.1) ────────────────────────────────────────────
echo "--> [1] Render gates (root pinned · Yoga in points · ABI canary · color · styling · diff-null):"
need "boot pins the root full-size to surface_ and renders the first screen" "$VC" \
  'createView\("RCTRootView"' \
  'canopyBoot\(\*_runtime, _rootTag, _bootFlags\)' \
  'evaluateJavaScript'
need "boot-time Hermes ABI canary runs BEFORE any JS (Risk #1 / IOS-4)" "$VC" \
  'enforceHermesAbiGate' \
  'getBytecodeVersion' \
  'checkHermesAbi'
# The deliberate iOS divergence: Yoga runs in POINTS, NO density multiply anywhere (contract §0.3).
need "Yoga layout drives UIView frames off YGNodeLayoutGet* (points)" "$FABRIC" \
  'YGNodeCalculateLayout' \
  'YGNodeLayoutGetLeft' \
  'YGNodeLayoutGetWidth'
# The Android density APIs must NEVER appear on iOS — points everywhere, no dp() multiply (§0.3).
absent "NO Android density APIs on iOS (points everywhere — the dp() divergence is deliberate)" "$FABRIC" \
  'dpToPx' \
  'getDisplayMetrics' \
  'densityDpi' \
  'DisplayMetrics'
need "CanopyColor is the full CSS parser (#rgb/#rgba/#rrggbb/#rrggbbaa, rgb/rgba, hsl/hsla, named)" "$FABRIC" \
  '@interface CanopyColor' \
  'parseHex' \
  'parseRgb' \
  'parseHsl' \
  'RRGGBBAA'
need "styling: per-corner radius via maskedCorners + CAShapeLayer mask, shadow, transform" "$FABRIC" \
  'maskedCorners' \
  'kCALayerMinXMinYCorner' \
  'CAShapeLayer' \
  'borderTopLeftRadius' \
  'shadow' \
  'transform'
# Diff-null discipline (contract §5.6/§5.7): a removed prop arrives as JSON null and RESETS to the
# explicit default — never coerced to 0/"" (the exact silent-default footgun).
need "diff-null discipline: a null prop resets to the explicit default (not 0/empty)" "$FABRIC" \
  'isNull' \
  'NSNull'
echo

# ── (2) EVENT GATES (§5.2) ───────────────────────────────────────────────────────────────────
echo "--> [2] Event gates (exact-token press · gesture set in points · setEvents idempotency):"
need "press is an EXACT token (not a substring of longPress/pressIn/pressOut) and emits via emit_" "$FABRIC" \
  'CanopyGestures' \
  '"press"' \
  '"longPress"' \
  '"pressIn"' \
  '"pressOut"' \
  '"doubleTap"'
need "pan payload is {dx,dy,vx,vy} straight from UIKit points (no /density)" "$FABRIC" \
  'UIPanGestureRecognizer' \
  'dx' \
  'vx'
need "setEvents is idempotent — a recycled view that lost an event loses its recognizer" "$FABRIC" \
  'setEvents'
echo

# ── (3) COMPONENT GATES (§5.3) ───────────────────────────────────────────────────────────────
echo "--> [3] Component gates (ScrollView · TextInput · Image · Switch · Modal · BeforeAfter):"
need "ScrollView has a SEPARATE Yoga content root + contentSize + horizontal + refresh" "$FABRIC" \
  '@interface CanopyScrollView' \
  'contentYoga' \
  'contentSize' \
  'horizontal' \
  'refreshControl'
need "TextInput single-line (UITextField) emits changeText/submitEditing/focus/blur" "$FABRIC" \
  '@interface CanopyTextInputView' \
  'changeText' \
  'submitEditing' \
  'secureTextEntry' \
  'keyboardType'
need "TextInput multiline (UITextView) — the RCTSinglelineTextInputView + multiline-prop fork" "$FABRIC" \
  'CanopyMultilineTextInputView' \
  'multiline'
need "Image declarative (RCTImageView) + recycle-drop de-dup (lastSource) + resizeMode" "$FABRIC" \
  'RCTImageView' \
  'lastSource' \
  'resizeMode' \
  'contentMode'
need "Image blob (CanopyBitmap) reads blobGetUIImage(handle) from the single registry" "$FABRIC" \
  'bitmapHandle' \
  'blobGetUIImage'
need "Switch (UISwitch) emits valueChange" "$FABRIC" \
  '@interface CanopySwitchView' \
  'valueChange'
# Modal predicted-rework: own content root (owner==null), keyWindow traversal, visible applied LAST,
# inline node measures 0×0 (the §5.3 Modal gate + the IOS-6 "predicted rework" note).
need "Modal (CanopyModalHost) — own content root, keyWindow traversal, inline 0x0, presented overlay" "$FABRIC" \
  '@interface CanopyModalHostView' \
  'UIWindowScene' \
  'rootViewController' \
  'presentViewController' \
  'sizeThatFits:\(CGSize\)size \{ return CGSizeZero;'
need "BeforeAfter (CanopyBeforeAfterView) CALayer wipe on before/after blob handles" "$FABRIC" \
  '@interface CanopyBeforeAfterView' \
  'beforeHandle' \
  'afterHandle' \
  'wipeStart' \
  'wipeCommit'
# Leaf measure (predicted rework: sizeThatFits vs Yoga measure modes) — all three modes handled.
need "leaf sizeThatFits is mapped through ALL THREE Yoga measure modes" "$FABRIC" \
  'YGNodeSetMeasureFunc' \
  'YGMeasureModeExactly' \
  'YGMeasureModeAtMost' \
  'YGMeasureModeUndefined' \
  'sizeThatFits'
echo

# ── (4) ANIMATION GATES (§5.4) ───────────────────────────────────────────────────────────────
echo "--> [4] Animation gates (CADisplayLink driver · base cache · remove-during-anim safety):"
need "animations drive via a CADisplayLink frame loop (CanopyAnimDriver)" "$FABRIC" \
  'CanopyAnimDriver' \
  'CADisplayLink' \
  'doFrame'
need "static opacity/transform are cached as a base and restored on clear" "$FABRIC" \
  'baseOpacity|baseTransform|base.[Oo]pacity|base.[Tt]ransform'
need "removeChild cancels animations for the child so a frame callback never hits a dead view" "$FABRIC" \
  'removeChild'
echo

# ── (5) CAPABILITY GATES (§5.5) — every C1 module is PACKAGE-RESIDENT + autolinked ──────────
# AUTO-E-DELETE (plan §5 Phase E): the hardcoded per-capability caps[] list is GONE. Every capability
# now declares itself in its package's native.json and ships its native/ios impl; `canopy-native build`
# emits its (name, streaming) entry into CanopyGeneratedCaps() from the app's dependency graph (the iOS
# analogue of the web compiler concatenating each package's external/*.js). So the ledger now verifies
# the PACKAGE is self-contained, not that a name sits in a boot list — the stronger, post-Phase-E gate.
echo "--> [5] Capability gates (every C1 module is package-resident + autolinked, not hardcoded):"
# Host-RESIDENT capabilities that legitimately stay wired in the module host (NOT autolinked):
#   • Echo — the shared-C++ first-light bridge smoke (registered via the C++ path).
#   • Photos — host-driven picker (no self-contained package; name-registered in the host caps[]).
if grep -qE 'Echo' "$MODHOST"; then green "    OK  — capability 'Echo' (shared-C++ bridge smoke) wired in the module host"; else
  red "    FAIL — capability 'Echo' (shared-C++ bridge smoke) not wired in the module host"; status=1; fi
if grep -qE '@"Photos"' "$MODHOST"; then green "    OK  — capability 'Photos' is host-resident in caps[] (host-driven picker)"; else
  red "    FAIL — host-resident capability 'Photos' missing from the module host caps[]"; status=1; fi
# Every other one-shot capability must be PACKAGE-RESIDENT (native.json declares it + native/ios ships it).
for cap in Image Album ShareImage StorageSecure Notify Http Platform Vibration Haptics Battery DeviceInfo NetInfo Brightness; do
  if capInPackage "$cap"; then green "    OK  — capability '$cap' is package-resident (canopy/$(capPkg "$cap")/native.json + native/ios) — autolinked, not hardcoded"; else
    red "    FAIL — capability '$cap' is not package-resident under $MONOREPO/$(capPkg "$cap") (native.json + native/ios/Canopy${cap}Module.mm)"; status=1; fi
done
# Streaming capabilities — package native.json must declare the name AND the exact streaming spec.
need "Lifecycle is a package-resident streaming cap with {appState, memoryPressure, backPressed}" "$MONOREPO/navigation/native.json" \
  '"Lifecycle"' \
  '"appState"' \
  '"memoryPressure"' \
  '"backPressed"'
need "AppShell is a package-resident streaming cap with {colorScheme}" "$MONOREPO/navigation/native.json" \
  '"AppShell"' \
  '"colorScheme"'
need "Billing is a package-resident streaming cap (StoreKit entitlement changes)" "$MONOREPO/billing/native.json" \
  '"Billing"' \
  '"entitlementChanges"'
# The generated-caps pipeline is the post-Phase-E source of name-registered capabilities: the boot
# file #if __has_include-guards the generated CanopyGeneratedCaps() and iterates it through the SAME
# by-name bridge the host-resident caps[] uses.
need "the module host consumes the GENERATED caps (autolink pipeline, not a hardcoded list)" "$MODHOST" \
  'CanopyGeneratedCaps' \
  '__has_include'
# RestoreEngine (Core ML) is registered via the weak factory, not caps[] (host-resident C++ module).
need "RestoreEngine (Core ML) registered via the weak factory path" "$MODHOST" \
  'RestoreEngine'
# The dispatcher is immutable + reflective: caps[] only NAMES modules; the bridge resolves them.
need "caps are registered through the by-name bridge (immutable reflective dispatcher)" "$MODHOST" \
  'registerModuleNamed:'
need "the by-name bridge round-trips __canopy_call → module → complete(err,res) (C1 ABI)" "$NATIVEBRIDGE" \
  'complete' \
  'callId'
need "streaming base: subscribe keeps the call open, emit repeats, \$done tears down (§4.4)" "$STREAMBASE" \
  'emitOnChannel' \
  'invokeMethod' \
  'cancelCallId'
echo

# ── (6) LINK-TIME + THREADING INVARIANTS (§5.6 / §5.7) ──────────────────────────────────────
echo "--> [6] Link/thread invariants (single blob registry · runtime touched only on main):"
# Exactly ONE globalBlobRegistry() definition (Risk #8): it lives ONLY in CanopyBlobRegistryHost.mm,
# and the Android-only definers must NOT be in the iOS sources at all.
need "the single globalBlobRegistry() definition lives in CanopyBlobRegistryHost.mm" "$BLOBHOST" \
  'globalBlobRegistry' \
  'blobGetUIImage' \
  'blobPutUIImage'
if [ -f "$IOS/CanopyHostCore/Modules/CanopyRestoreEngineModule.mm" ]; then
  absent "the iOS RestoreEngine module does NOT redefine globalBlobRegistry() (no duplicate symbol)" \
    "$IOS/CanopyHostCore/Modules/CanopyRestoreEngineModule.mm" \
    'BlobRegistry *& *globalBlobRegistry'
fi
# Threading: every host→JS call hops to main via the registry's postToJs (= dispatch_async(main));
# the boot emit closure is the sole site that calls canopyEmitEvent (contract §0.2 / §6.9).
need "the boot emit closure routes every emit onto the main queue (the only canopyEmitEvent site)" "$VC" \
  'canopyEmitEvent' \
  'dispatch_async\(dispatch_get_main_queue'
need "worker callbacks hop back to main via the registry postToJs before touching the runtime" "$NATIVEBRIDGE" \
  'postToJs|dispatch_get_main_queue'
echo

# ── (H) THE VALIDATION HARNESS — the XCUITest + ObjC++ XCTest that DRIVE the ledger ─────────
echo "--> [H] The Part-5 validation harness exists and covers every gate family:"
need "the XCUITest validation suite exists and is the parity twin of the Android E2E flow" "$UITEST" \
  'import XCTest' \
  'XCUIApplication' \
  'func test'
# It must drive each Part-5 family by name so the ledger stays honest about coverage.
need "the XCUITest names every Part-5 gate family it drives on the Simulator" "$UITEST" \
  'Render' \
  'Event|[Tt]ap|[Pp]ress' \
  'ScrollView' \
  'TextInput' \
  'Image' \
  'Switch' \
  'Modal' \
  '[Aa]nim' \
  '[Cc]apabilit' \
  '[Ss]treaming'
# testID -> accessibilityIdentifier is what makes ONE spec body run on BOTH platforms (E2E-2).
need "selection is by ~testID (accessibilityIdentifier) — the SAME contract as the Android flow" "$UITEST" \
  'accessibilityIdentifier|\bid:|\$\(|matching|identifier'
need "the host wires testID → accessibilityIdentifier (the XCUITest selector contract)" "$FABRIC" \
  'testID' \
  'accessibilityIdentifier'
# The boot smoke test (authored in IOS-5) stays — the validation suite builds ON it.
need "the IOS-5 boot smoke test is still present (the validation suite builds on first-light)" "$SMOKE_UITEST" \
  'testAppBootsToForeground' \
  'runningForeground'
# The device-free ObjC++ legs (CanopyColor + the streaming base + the ABI verdict) are pinned in
# XCTest so the pure logic is covered on the build host, not only on a Simulator.
need "the device-free ObjC++ ledger XCTest pins the pure legs (color/diff-null/measure verdicts)" "$LEDGERTEST" \
  '#import <XCTest/XCTest.h>' \
  'CanopyColor|parseColor' \
  'testColor|testParse|testDiffNull|testMeasure'
need "the engine XCTest still pins the ABI-canary verdict + blob/stream contracts (IOS-4/IOS-5)" "$ENGTEST" \
  'testHermesAbiGate' \
  'BlobRegistry' \
  'CanopyStreamingModuleBase'
need "the Part-5 ledger document enumerates every gate with its verification status" "$LEDGER_DOC" \
  'Part-5' \
  'MAC-REQUIRED' \
  'device-free'
echo

# ── (P) ANDROID-PARITY CROSS-CHECKS — the ledger is the iOS MIRROR of Android's ─────────────
echo "--> [P] Android-parity cross-checks (the iOS ledger mirrors the Android device-validated one):"
# After Phase E, parity is a PACKAGE property: a capability ships BOTH an iOS (native/ios) and an
# Android (native/android) impl in the same package, so neither platform drifts ahead. (Photos stays
# host-resident on both — its picker is host-driven — so it is checked against the host trees, not a
# package.) This replaces the old "name in iOS caps[] ⇒ also on Android" check, which read a hardcoded
# list that no longer exists.
for cap in Image Album ShareImage StorageSecure Notify Http Platform Lifecycle AppShell Billing; do
  pkg="$(capPkg "$cap")"
  iosImpl="$MONOREPO/$pkg/native/ios/Canopy${cap}Module.mm"
  # Android impl: the package's native/android (<Name>Module.java); Lifecycle/AppShell share a package.
  droidImpl="$MONOREPO/$pkg/native/android/${cap}Module.java"
  if [ -f "$iosImpl" ] && [ -f "$droidImpl" ]; then
    green "    OK  — capability '$cap' is package-resident on BOTH iOS + Android (canopy/$pkg/native)"
  else
    red "    FAIL — capability '$cap' lacks a both-platform package impl (ios:$([ -f "$iosImpl" ] && echo ok || echo MISSING), android:$([ -f "$droidImpl" ] && echo ok || echo MISSING)) under canopy/$pkg/native"; status=1
  fi
done
# Photos is host-resident on both platforms (host-driven picker) — assert the host impls, not a package.
if [ -f "$IOS/CanopyHostCore/Modules/CanopyPhotosModule.mm" ] && grep -qE "\"Photos\"|PhotosModule" "$DROID_MODHOST" "$DROID/modules/PhotosModule.java" 2>/dev/null; then
  green "    OK  — capability 'Photos' is host-resident on BOTH iOS + Android (host-driven picker)"
else
  red "    FAIL — host-resident capability 'Photos' missing an iOS or Android host impl"; status=1
fi
echo

if [ "$status" -eq 0 ]; then
  green "ALL GREEN — every Part-5 gate's seam is present, mirrors Android, and is covered by the"
  green "            XCUITest + ObjC++ XCTest validation harness."
  green "            (Mac-gated: the real Simulator ledger run is host/ios/PART5-LEDGER.md + §5 of"
  green "             host/ios/BUILD-AND-VALIDATE.md; this gate is its device-free structural net.)"
else
  red "REGRESSION — the iOS Part-5 validation ledger drifted. See plans/dependent/IOS-6.md +" >&2
  red "             host/ios/PART5-LEDGER.md." >&2
fi
exit "$status"
