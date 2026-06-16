#!/usr/bin/env bash
# df-ios.sh — DF-1: submit the iOS nightly device-farm sweep (smoke + perf trace) on a REAL iPhone,
# dispatching to the configured provider. This is the real-device complement to the simulator job
# ios-appium-e2e (E2E-2): it runs the SAME e2e/smoke.mjs spec body (caps.mjs emits the XCUITest caps
# unchanged), plus a frame/hitch summary, on a physical iPhone in a managed farm. See
# docs/device-farm.md for the strategy and §6 for the Apple Developer signing gate.
#
# Provider dispatch (DF_PROVIDER):
#   browserstack  (default) -> df-browserstack.sh — BrowserStack App Automate (real iPhone, native Appium)
#   aws                     -> df-aws.sh ios        — AWS Device Farm (unified fallback)
#
# iOS needs a SIGNED .ipa (Apple Developer account) — Apple requires a code-signed app to install on a
# real device. This script SELF-SKIPS with a clear, non-fatal message when the provider credential or
# the .ipa is absent, so it is safe to invoke on a box with neither a farm account nor a Mac (this
# sandbox). The CI job (device-farm-ios) is continue-on-error + secret-gated for the same reason.
#
# Env:
#   DF_PROVIDER     browserstack | aws                              (default: browserstack)
#   IPA             path to the SIGNED .ipa to install on the device   (required for a real run)
#   DF_DEVICE       farm device name (e.g. "iPhone 15")             (default: "iPhone 15")
#   DF_OS_VERSION   iOS version on the device                       (default: 17)
#   DF_OUT          output dir for artifacts                  (default: df-out/ios)
#   DF_REQUIRE      "1" => a missing provider credential/.ipa is a HARD failure (CI flip; default 0)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

DF_PROVIDER="${DF_PROVIDER:-browserstack}"
DF_OUT="${DF_OUT:-$ROOT/df-out/ios}"
DF_REQUIRE="${DF_REQUIRE:-0}"
export DF_OUT DF_REQUIRE

mkdir -p "$DF_OUT"

say() { echo "==> df-ios: $*"; }

skip() {
  echo "::notice::df-ios SKIP — $1" 2>/dev/null || echo "df-ios SKIP — $1"
  if [ "$DF_REQUIRE" = "1" ]; then
    echo "::error::DF_REQUIRE=1 but the device farm could not run: $1" 2>/dev/null || echo "ERROR (DF_REQUIRE=1): $1"
    exit 1
  fi
  exit 0
}
export -f skip
export -f say

say "provider=$DF_PROVIDER device=${DF_DEVICE:-iPhone 15}/iOS${DF_OS_VERSION:-17} out=$DF_OUT"

case "$DF_PROVIDER" in
  browserstack) exec bash "$HERE/df-browserstack.sh" ;;
  aws)          exec bash "$HERE/df-aws.sh" ios ;;
  *) echo "::error::unknown DF_PROVIDER='$DF_PROVIDER' (want: browserstack|aws)"; exit 2 ;;
esac
