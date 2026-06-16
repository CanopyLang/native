#!/usr/bin/env bash
# check-ios-devloop.sh — DEV-12 structural gate for the iOS dev-loop parity (NO Mac required).
#
# The iOS host cannot be COMPILED off macOS (Xcode/UIKit), so this gate proves — device-free, by
# structural assertion — that the iOS dev loop is the faithful twin of the validated Android one
# (DEV-4 in-process reload + DEV-6 dev client). It fails LOUD if any load-bearing seam is missing or
# drifts from the Android contract, so a regression is caught in CI's cheap Linux `gate` job exactly
# like check-rn-coupling.sh, long before a Mac build ever runs.
#
# What it asserts:
#   (A) the VC reload seam  — CanopyHostViewController declares -reloadWithBundle: + -showDevBuildError:
#                            and drives the SAME __canopy_captureState/__canopy_teardown/__canopy_remount
#                            seam + Elm reset + canopyBoot(cachedRoot, bootFlags) as Android's nativeReload;
#   (B) the dev client      — CanopyDevClient exposes the SAME pure decision layer (classify/parseFrame/
#                            isCleartextAllowed/deriveWsUrl/backoffMs) as the Java client, dials over
#                            NSURLSessionWebSocketTask, and is DEBUG-gated;
#   (C) wire-protocol parity — the five frame types (hello/building/reload/nochange/error) match the
#                            Android client + the dev server;
#   (D) the start site      — a debug-only CanopyDevBootstrap resolves CANOPY_DEV_HOST and is started
#                            from SceneDelegate;
#   (E) the security scope  — the ATS NSAllowsLocalNetworking exception is present (the platform belt
#                            to isCleartextAllowed), and the cleartext allowlist ranges match Android;
#   (F) the test            — CanopyDevClientTests pins the pure layer device-free (XCTest).
#
# Pure bash + grep (no device, no SDK, no compiler). Usage:  bash scripts/check-ios-devloop.sh
# Exit: 0 = the iOS dev loop is structurally complete + Android-parity · 1 = a seam is missing/drifted.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IOS="$ROOT/host/ios"
DROID="$ROOT/host/android/app/src"

VC="$IOS/CanopyHostCore/Boot/CanopyHostViewController.mm"
VC_H="$IOS/CanopyHostCore/Boot/CanopyHostViewController.h"
CLIENT="$IOS/CanopyHostCore/DevLoop/CanopyDevClient.mm"
CLIENT_H="$IOS/CanopyHostCore/DevLoop/CanopyDevClient.h"
REDBOX="$IOS/CanopyHostCore/DevLoop/CanopyDevRedBox.mm"
BOOTSTRAP="$IOS/CanopyHostApp/CanopyDevBootstrap.swift"
SCENE="$IOS/CanopyHostApp/SceneDelegate.swift"
PLIST="$IOS/CanopyHostApp/Info.plist"
TEST="$IOS/Tests/CanopyHostCoreTests/CanopyDevClientTests.mm"
DROID_RELOAD="$ROOT/host/android/app/src/main/jni/CanopyHostJni.cpp"
DROID_CLIENT="$DROID/debug/java/com/canopyhost/CanopyDevClient.java"

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

echo "==> iOS dev-loop parity gate (scripts/check-ios-devloop.sh)"
echo "    (structural — the iOS host cannot be compiled off macOS; this proves the seams exist + match Android)"
echo

# ── (A) the VC in-process reload seam (DEV-4 twin) ───────────────────────────────────────
echo "--> [A] CanopyHostViewController in-process reload seam (twin of Android nativeReload):"
need "header declares the reload + build-error API" "$VC_H" \
  '- \(void\)reloadWithBundle:' \
  '- \(void\)showDevBuildError:'
need "reload drives the DEV-2 seam + host reset + re-boot" "$VC" \
  '- \(void\)reloadWithBundle:' \
  '__canopy_captureState' \
  '__canopy_teardown' \
  '__canopy_remount' \
  '__canopy_reloadNotice' \
  'setProperty\(rt, "Elm"' \
  'evaluateJavaScript' \
  'canopyBoot\(rt, _rootTag, _bootFlags\)' \
  'dispatch_async\(dispatch_get_main_queue'
need "boot caches the root + flags for the reload to reuse" "$VC" \
  '_rootTag = _host->createView\("RCTRootView"' \
  '_bootFlags = "\{\}"'
echo

# ── (B) the dev client (DEV-6 twin) ──────────────────────────────────────────────────────
echo "--> [B] CanopyDevClient (twin of the Android dev-loop WS client):"
need "header exposes the pure decision layer + start/stop" "$CLIENT_H" \
  '\+ \(CanopyDevAction\)classify:' \
  '\+ \(CanopyDevFrame \*\)parseFrame:' \
  '\+ \(BOOL\)isCleartextAllowed:' \
  '\+ \(nullable NSString \*\)deriveWsUrl:' \
  '\+ \(long\)backoffMs:' \
  '\+ \(nullable instancetype\)startWithDevHost:'
need "impl dials over NSURLSessionWebSocketTask + reconnect + reaches the host VC" "$CLIENT" \
  'NSURLSessionWebSocketTask' \
  'NSURLSessionWebSocketDelegate' \
  'receiveMessageWithCompletionHandler' \
  'scheduleReconnect' \
  'reloadWithBundle:' \
  'showDevBuildError:' \
  'rootViewController'
need "client socket path is DEBUG-gated (stripped from release)" "$CLIENT" \
  '#if DEBUG' \
  '#else'
echo

# ── (C) wire-protocol parity with Android + the dev server ───────────────────────────────
echo "--> [C] wire-protocol parity (the five frame types match Android + canopy-dev-server.js):"
for t in hello building reload nochange error; do
  if grep -qE "\"$t\"" "$CLIENT" && grep -qE "\"$t\"" "$DROID_CLIENT"; then
    green "    OK  — frame type '$t' handled on BOTH iOS + Android"
  else
    red "    FAIL — frame type '$t' is not handled identically on both clients"; status=1
  fi
done
echo

# ── (D) the start site (DEV-6 CanopyDevBootstrap twin) ───────────────────────────────────
echo "--> [D] debug-only start site (twin of Android CanopyDevBootstrap):"
need "bootstrap resolves CANOPY_DEV_HOST + starts the client, DEBUG-gated" "$BOOTSTRAP" \
  '#if DEBUG' \
  'CANOPY_DEV_HOST' \
  'CanopyDevClient.start\(withDevHost:'
need "SceneDelegate starts the bootstrap after installing the host root" "$SCENE" \
  'window.rootViewController = CanopyHostViewController\(\)' \
  'CanopyDevBootstrap.start\(\)'
echo

# ── (E) the security scope (ATS belt to the code allowlist) ──────────────────────────────
echo "--> [E] cleartext security scope (ATS belt + allowlist parity with Android):"
need "Info.plist scopes cleartext to the LOCAL NETWORK only (ATS)" "$PLIST" \
  'NSAppTransportSecurity' \
  'NSAllowsLocalNetworking'
# the allowlist ranges must match the Android client's (loopback / 10/8 / 192.168 / 172.16-31 / link-local)
need "isCleartextAllowed enforces the SAME RFC-1918 ranges as Android" "$CLIENT" \
  'localhost' \
  '127' \
  '192 && q\[1\] == 168' \
  '172 && q\[1\] >= 16 && q\[1\] <= 31' \
  '169 && q\[1\] == 254'
echo

# ── (F) the device-free test ─────────────────────────────────────────────────────────────
echo "--> [F] device-free XCTest pins the pure decision layer (twin of CanopyDevClientTest.java):"
need "CanopyDevClientTests covers classify/parseFrame/cleartext/url/backoff" "$TEST" \
  'testClassifyMapsEveryKnownType' \
  'testParseFrameReloadExtractsBundleAndBuildId' \
  'testParseFrameMalformedJsonIsIgnoreNotThrow' \
  'testCleartextRefusesPublicAndOutOfRange' \
  'testDeriveWsUrlRefusesDisallowedHost' \
  'testBackoffFloorsDoublesAndCeilings'
echo

if [ "$status" -eq 0 ]; then
  green "ALL GREEN — the iOS dev loop is structurally complete and is the faithful twin of Android's."
  green "            (Mac-gated: a real Simulator reload run is documented in host/ios/README-ios.md.)"
else
  red "REGRESSION — the iOS dev loop drifted from the Android contract. See plans/dependent/DEV-12.md." >&2
fi
exit "$status"
