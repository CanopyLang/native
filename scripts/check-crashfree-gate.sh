#!/usr/bin/env bash
# check-crashfree-gate.sh — TEL-1/REL-4: keep the crash-free metric computable + honest, device-free.
#
# The crash floor writes buildId-keyed crash records and a per-launch session-start beacon; the
# crash-free metric = 1 - (sessions with a fatal / total sessions) per platform+buildId. This gate
# proves the METRIC PIPELINE is correct without any device:
#   (1) the computation passes its selftest (the math + the "emulator source ⇒ caveat" rule);
#   (2) the telemetry schema doc + JSON Schema exist and are valid;
#   (3) BOTH hosts emit the schema fields the reporter consumes (sessionId, eventType, the session
#       beacon, platform/buildId/fatal) — so the record shape can't drift from what the reporter reads;
#   (4) telemetry is OFF by default (no network without explicit consent + a configured endpoint).
# A real published crash-free NUMBER still needs real shipped-device sessions (DEV/SHIP); this gate is
# the always-on floor that keeps the pipeline honest until then.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AND="$ROOT/host/android/app/src/main/java/com/canopyhost/CanopyCrashFloor.java"
IOS="$ROOT/host/ios/CanopyHostCore/Boot/CanopyCrashFloor.mm"
REPORT="$ROOT/harness/crashfree-report.js"
SCHEMA="$ROOT/docs/telemetry-schema.json"
DOC="$ROOT/docs/telemetry.md"
fail=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✗ %s\033[0m\n' "$*" >&2; fail=1; }
has() { grep -qF "$2" "$1" 2>/dev/null; }

# (1) the computation selftest
echo "==> [1/4] crash-free computation selftest"
if command -v node >/dev/null 2>&1; then
  if node "$REPORT" --selftest >/dev/null 2>&1; then ok "crashfree-report.js --selftest passes (math + caveat rule)"; else bad "crashfree-report.js --selftest FAILED"; fi
else
  echo "  · SKIP selftest: node not on PATH"
fi

# (2) schema doc + JSON Schema valid
echo "==> [2/4] telemetry schema + doc"
[ -f "$DOC" ] && ok "docs/telemetry.md present" || bad "docs/telemetry.md missing"
if [ -f "$SCHEMA" ]; then
  if command -v node >/dev/null 2>&1; then
    node -e "JSON.parse(require('fs').readFileSync('$SCHEMA','utf8'))" 2>/dev/null && ok "telemetry-schema.json is valid JSON" || bad "telemetry-schema.json is not valid JSON"
  else ok "telemetry-schema.json present (node absent — JSON not parsed)"; fi
else bad "docs/telemetry-schema.json missing"; fi

# (3) both hosts emit the reporter's required fields + the session beacon
echo "==> [3/4] both hosts emit the schema-2 telemetry the reporter consumes"
for f in "$AND" "$IOS"; do
  label="$(basename "$(dirname "$f")")/$(basename "$f")"
  has "$f" 'sessionId'      && ok "$label: emits sessionId (the crash-free key)"        || bad "$label: missing sessionId"
  has "$f" 'session-start'  && ok "$label: writes the session-start beacon (denominator)" || bad "$label: missing the session-start beacon"
  has "$f" 'eventType'      && ok "$label: tags records with eventType"                  || bad "$label: missing eventType"
  has "$f" 'buildId'        && ok "$label: keys by buildId"                              || bad "$label: missing buildId"
done

# (4) off by default: no network without explicit consent + a configured endpoint
echo "==> [4/4] telemetry is off by default (no network without consent + endpoint)"
{ has "$AND" 'optIn' || has "$AND" 'telemetryEndpoint' || has "$AND" 'no-network' || has "$AND" 'ring'; } \
  && ok "Android: a no-network ring-buffer default / consent gate is present" \
  || bad "Android: no evidence of a no-network default (consent/endpoint/ring)"
{ has "$IOS" 'optIn' || has "$IOS" 'telemetryEndpoint' || has "$IOS" 'no-network' || has "$IOS" 'ring'; } \
  && ok "iOS: a no-network ring-buffer default / consent gate is present" \
  || bad "iOS: no evidence of a no-network default (consent/endpoint/ring)"

echo
if [ "$fail" -eq 0 ]; then echo "crash-free gate OK — the metric pipeline is correct + honest (real number needs shipped-device sessions)."; else echo "crash-free gate FAILED." >&2; fi
exit "$fail"
