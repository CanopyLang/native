#!/usr/bin/env bash
# df-browserstack.sh — DF-1 iOS provider: run the smoke + perf summary on a REAL iPhone in BrowserStack
# App Automate. Called by df-ios.sh (DF_PROVIDER=browserstack). See docs/device-farm.md §2/§5.
#
# WHY BrowserStack for iOS: it is the only DF-1 candidate that gives real iPhones AND runs our native
# Appium smoke.mjs UNCHANGED — the browserstack-node-sdk points the WebdriverIO session at BrowserStack's
# hub, and e2e/caps.mjs already emits the XCUITest caps. It needs a SIGNED .ipa (the Apple Developer
# account gate — Apple requires a code-signed app to install on a real device).
#
# WHAT THIS DOES (on a box with the BrowserStack credentials + a signed .ipa):
#   1. upload the .ipa to App Automate (-> an app_url the session installs);
#   2. run smoke.mjs against the BrowserStack hub on a real iPhone (caps.mjs -> XCUITest, unchanged);
#   3. pull the App Performance series (CPU/mem/fps) for the session via the App Automate REST API and
#      distil it into frame-summary.json (df-ios-trace-summary.mjs), then gate it with perf-report.js.
#
# It SELF-SKIPS (skip()) when the BrowserStack credentials or the .ipa are absent, so it is safe to run
# on this box (no account, no Mac to build the .ipa). The upload/session/REST calls are written against
# the documented App Automate API but are NOT executed here — see docs/device-farm.md §8.
#
# Env (in addition to df-ios.sh's): BROWSERSTACK_USERNAME (or BROWSERSTACK_USER),
#   BROWSERSTACK_ACCESS_KEY (or BROWSERSTACK_KEY).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

if ! declare -F skip >/dev/null 2>&1; then
  DF_REQUIRE="${DF_REQUIRE:-0}"
  skip() { echo "df-browserstack SKIP — $1"; [ "${DF_REQUIRE:-0}" = "1" ] && { echo "ERROR (DF_REQUIRE=1): $1"; exit 1; }; exit 0; }
fi
if ! declare -F say >/dev/null 2>&1; then say() { echo "==> df-browserstack: $*"; }; fi

DF_OUT="${DF_OUT:-$ROOT/df-out/ios}"
IPA="${IPA:-}"
DF_DEVICE="${DF_DEVICE:-iPhone 15}"
DF_OS_VERSION="${DF_OS_VERSION:-17}"
BS_USER="${BROWSERSTACK_USERNAME:-${BROWSERSTACK_USER:-}}"
BS_KEY="${BROWSERSTACK_ACCESS_KEY:-${BROWSERSTACK_KEY:-}}"
mkdir -p "$DF_OUT"

# --- preconditions: skip cleanly if no account/.ipa --------------------------------------------
if [ -z "$BS_USER" ] || [ -z "$BS_KEY" ]; then skip "no BrowserStack credentials (set BROWSERSTACK_USER + BROWSERSTACK_KEY)"; fi
if [ -z "$IPA" ] || [ ! -f "$IPA" ]; then skip "signed .ipa not found ('$IPA') — build it on a Mac with your Apple Developer cert (docs/device-farm.md §6)"; fi
command -v curl >/dev/null 2>&1 || skip "curl not installed"
command -v node >/dev/null 2>&1 || skip "node not installed (needed to drive the WebdriverIO session)"
# The session is driven through browserstack-node-sdk (it points WebdriverIO at the BrowserStack hub
# so smoke.mjs runs UNCHANGED). It is an e2e/ devDependency for the iOS DF leg — when it is not yet
# installed, skip cleanly with the one-line fix rather than crashing mid-run (E2E lane follow-up).
if [ ! -x "$ROOT/e2e/node_modules/.bin/browserstack-node-sdk" ]; then
  skip "browserstack-node-sdk not installed — add it to e2e/package.json devDeps + npm ci (docs/device-farm.md §5)"
fi

# --- 1. upload the signed .ipa -> app_url ------------------------------------------------------
say "upload $IPA to BrowserStack App Automate"
UPLOAD_JSON="$DF_OUT/bs-upload.json"
curl -fsS -u "$BS_USER:$BS_KEY" \
  -X POST "https://api-cloud.browserstack.com/app-automate/upload" \
  -F "file=@$IPA" > "$UPLOAD_JSON"
APP_URL="$(node -e 'const j=require(process.argv[1]);process.stdout.write(j.app_url||"")' "$UPLOAD_JSON" 2>/dev/null || true)"
[ -n "$APP_URL" ] || skip "BrowserStack upload returned no app_url (see $UPLOAD_JSON)"
say "uploaded -> $APP_URL"

# --- 2. run smoke.mjs against the BrowserStack hub on a REAL iPhone -----------------------------
# The browserstack-node-sdk wraps the WebdriverIO session so smoke.mjs runs UNCHANGED; caps.mjs emits
# the XCUITest caps, and these BS-specific vars route the session to the hub + the real device.
say "run smoke.mjs on $DF_DEVICE / iOS $DF_OS_VERSION (real iPhone)"
set +e
( cd "$ROOT/e2e" \
  && BROWSERSTACK_USERNAME="$BS_USER" BROWSERSTACK_ACCESS_KEY="$BS_KEY" \
     E2E_PLATFORM=iOS E2E_AUTOMATION=XCUITest \
     E2E_BS_APP="$APP_URL" E2E_BS_DEVICE="$DF_DEVICE" E2E_BS_OS_VERSION="$DF_OS_VERSION" \
     E2E_HOST=hub-cloud.browserstack.com E2E_PORT=443 \
     node node_modules/.bin/browserstack-node-sdk node smoke.mjs ) 2>&1 | tee "$DF_OUT/smoke.log"
RUN_RC=${PIPESTATUS[0]}
set -e
say "smoke exit=$RUN_RC (session video + log in the BrowserStack console; smoke.log saved)"

# --- 3. pull the App Performance series + gate it ----------------------------------------------
SESSION_ID="$(grep -oE 'sessionId[":= ]+[a-f0-9]{20,}' "$DF_OUT/smoke.log" 2>/dev/null | grep -oE '[a-f0-9]{20,}' | head -1 || true)"
if [ -n "$SESSION_ID" ]; then
  say "fetch App Performance series for session $SESSION_ID"
  set +e
  curl -fsS -u "$BS_USER:$BS_KEY" \
    "https://api-cloud.browserstack.com/app-automate/sessions/$SESSION_ID/appprofiling/v2" \
    > "$DF_OUT/bs-appprofiling.json" 2>>"$DF_OUT/smoke.log"
  set -e
  if command -v node >/dev/null 2>&1 && [ -s "$DF_OUT/bs-appprofiling.json" ]; then
    node "$HERE/df-ios-trace-summary.mjs" --browserstack "$DF_OUT/bs-appprofiling.json" --out "$DF_OUT/frame-summary.json"
    BASELINE="$ROOT/harness/perf-baselines/$(echo "$DF_DEVICE" | tr 'A-Z ' 'a-z-').json"
    if [ -f "$BASELINE" ]; then
      node "$ROOT/harness/perf-report.js" "$DF_OUT/frame-summary.json" --baseline "$BASELINE" | tee "$DF_OUT/perf-report.txt"
    else
      say "no baseline yet ($BASELINE) — printing the ledger to seed it (docs/device-farm.md §7)"
      node "$ROOT/harness/perf-report.js" "$DF_OUT/frame-summary.json" | tee "$DF_OUT/perf-report.txt"
    fi
  fi
else
  say "no BrowserStack sessionId in smoke.log — App Performance trace unavailable; smoke verdict stands alone"
fi

exit "$RUN_RC"
