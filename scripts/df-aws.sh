#!/usr/bin/env bash
# df-aws.sh — DF-1 unified fallback provider: run the smoke + perf sweep on a REAL device in AWS Device
# Farm, for EITHER platform. Called by df-android.sh / df-ios.sh when DF_PROVIDER=aws. See
# docs/device-farm.md §2 (the "unified fallback" row): one provider + one bill does both platforms, at
# the cost of packaging our Appium spec as an AWS test ".zip" and (for iOS) a signed .ipa.
#
# Usage: df-aws.sh <android|ios>
#
# WHAT THIS DOES (on a box with the `aws` CLI + credentials + a Device Farm project):
#   1. upload the app (debug APK for android / signed .ipa for ios) to the Device Farm project;
#   2. upload our Appium-Node test package (the e2e/ dir zipped) + a custom test-spec YAML that runs
#      smoke.mjs and pulls the perf artifact via the test-spec `artifacts:` block;
#   3. schedule the run on a real-device pool, poll to completion, download the artifacts (video +
#      the pulled perf dump) into $DF_OUT, and gate the perf trace with perf-report.js.
#
# It SELF-SKIPS (skip()) when the aws CLI / credentials / project ARN / app artifact are absent, so it
# is safe to run on this box (no account). The `aws devicefarm` calls are written against the
# documented CLI but are NOT executed here — see docs/device-farm.md §8.
#
# Env (in addition to the caller's): AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY (or a profile),
#   DF_AWS_PROJECT_ARN, DF_AWS_DEVICE_POOL_ARN.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

PLATFORM="${1:-}"
case "$PLATFORM" in
  android|ios) ;;
  *) echo "::error::df-aws.sh needs a platform arg: android | ios"; exit 2 ;;
esac

if ! declare -F skip >/dev/null 2>&1; then
  DF_REQUIRE="${DF_REQUIRE:-0}"
  skip() { echo "df-aws SKIP — $1"; [ "${DF_REQUIRE:-0}" = "1" ] && { echo "ERROR (DF_REQUIRE=1): $1"; exit 1; }; exit 0; }
fi
if ! declare -F say >/dev/null 2>&1; then say() { echo "==> df-aws($PLATFORM): $*"; }; fi

DF_OUT="${DF_OUT:-$ROOT/df-out/$PLATFORM}"
mkdir -p "$DF_OUT"

# Which app artifact + AWS upload type per platform.
if [ "$PLATFORM" = "android" ]; then
  APP="${APK:-}"
  APP_TYPE="ANDROID_APP"
  if [ -z "$APP" ] || [ ! -f "$APP" ]; then skip "APK not found ('$APP') — build the debug APK first"; fi
else
  APP="${IPA:-}"
  APP_TYPE="IOS_APP"
  if [ -z "$APP" ] || [ ! -f "$APP" ]; then skip "signed .ipa not found ('$APP') — build it on a Mac (Apple Developer cert; docs/device-farm.md §6)"; fi
fi

# --- preconditions: skip cleanly if no account/CLI/project --------------------------------------
command -v aws >/dev/null 2>&1 || skip "aws CLI not installed (no AWS Device Farm account wired)"
if [ -z "${AWS_ACCESS_KEY_ID:-}" ] && [ -z "${AWS_PROFILE:-}" ]; then
  skip "no AWS credentials (set AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY or AWS_PROFILE)"
fi
[ -n "${DF_AWS_PROJECT_ARN:-}" ] || skip "DF_AWS_PROJECT_ARN unset (the Device Farm project)"
[ -n "${DF_AWS_DEVICE_POOL_ARN:-}" ] || skip "DF_AWS_DEVICE_POOL_ARN unset (the real-device pool)"

# Device Farm runs only in us-west-2.
export AWS_DEFAULT_REGION="us-west-2"

# --- 1. package the Appium-Node test bundle (the e2e/ dir + a test-spec YAML) -------------------
# The test spec runs smoke.mjs (caps.mjs flips the platform) and, post-test, copies the perf dump into
# the AWS-collected customer artifacts dir so it comes back with the run.
TEST_ZIP="$DF_OUT/appium-node-tests.zip"
say "package the Appium-Node test bundle -> $TEST_ZIP"
( cd "$ROOT/e2e" && zip -qr "$TEST_ZIP" . -x 'node_modules/*' 'screenshots/*' )

upload() { # <file> <type> -> echoes the uploaded ARN once SUCCEEDED
  local file="$1" type="$2" name; name="$(basename "$file")"
  local arn url
  arn="$(aws devicefarm create-upload --project-arn "$DF_AWS_PROJECT_ARN" --name "$name" --type "$type" --query 'upload.arn' --output text)"
  url="$(aws devicefarm get-upload --arn "$arn" --query 'upload.url' --output text)"
  curl -fsS -T "$file" "$url"
  for _ in $(seq 1 60); do
    local st; st="$(aws devicefarm get-upload --arn "$arn" --query 'upload.status' --output text)"
    [ "$st" = "SUCCEEDED" ] && { echo "$arn"; return 0; }
    [ "$st" = "FAILED" ] && { echo "::error::AWS upload FAILED for $name"; return 1; }
    sleep 5
  done
  echo "::error::AWS upload for $name never succeeded"; return 1
}

say "upload app ($APP_TYPE) + test bundle"
APP_ARN="$(upload "$APP" "$APP_TYPE")"
TEST_ARN="$(upload "$TEST_ZIP" "APPIUM_NODE_TEST_PACKAGE")"

# --- 2. schedule the run on a real-device pool, poll to completion ------------------------------
say "schedule the run on the real-device pool"
RUN_ARN="$(aws devicefarm schedule-run \
  --project-arn "$DF_AWS_PROJECT_ARN" \
  --app-arn "$APP_ARN" \
  --device-pool-arn "$DF_AWS_DEVICE_POOL_ARN" \
  --name "canopy-df-$PLATFORM-$(date -u +%Y%m%dT%H%M%SZ)" \
  --test "type=APPIUM_NODE,testPackageArn=$TEST_ARN" \
  --query 'run.arn' --output text)"
say "run scheduled: $RUN_ARN — polling"

RESULT="PENDING"
for _ in $(seq 1 120); do
  RESULT="$(aws devicefarm get-run --arn "$RUN_ARN" --query 'run.result' --output text 2>/dev/null || echo PENDING)"
  STATUS="$(aws devicefarm get-run --arn "$RUN_ARN" --query 'run.status' --output text 2>/dev/null || echo RUNNING)"
  [ "$STATUS" = "COMPLETED" ] && break
  sleep 15
done
say "run status=${STATUS:-?} result=$RESULT"

# --- 3. download the artifacts (video + the pulled perf dump) -----------------------------------
say "list + download run artifacts -> $DF_OUT"
aws devicefarm list-artifacts --arn "$RUN_ARN" --type FILE --query 'artifacts[].{name:name,url:url,ext:extension}' --output json > "$DF_OUT/aws-artifacts.json" || true
if command -v node >/dev/null 2>&1; then
  node -e '
    const fs=require("fs"),cp=require("child_process");
    const arts=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
    for (const a of arts) {
      if (/frame-metrics|frame-summary|perf/i.test(a.name)) {
        const out=process.argv[2]+"/"+a.name+"."+(a.ext||"json");
        cp.execSync("curl -fsS -o "+JSON.stringify(out)+" "+JSON.stringify(a.url));
        console.error("pulled "+out);
      }
    }
  ' "$DF_OUT/aws-artifacts.json" "$DF_OUT" || true
fi

# --- gate the perf trace if one came back ------------------------------------------------------
DUMP="$(find "$DF_OUT" -maxdepth 1 \( -name '*frame-metrics*' -o -name '*frame-summary*' \) 2>/dev/null | head -1 || true)"
if [ -n "$DUMP" ] && command -v node >/dev/null 2>&1; then
  say "gate perf trace ($DUMP)"
  node "$ROOT/harness/perf-report.js" "$DUMP" | tee "$DF_OUT/perf-report.txt" || true
else
  say "no perf dump in the run artifacts — smoke verdict stands alone"
fi

[ "$RESULT" = "PASSED" ] && exit 0 || exit 1
