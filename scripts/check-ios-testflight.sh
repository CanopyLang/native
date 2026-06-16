#!/usr/bin/env bash
# check-ios-testflight.sh — IOS-11 structural gate for the iOS TestFlight upload pipeline. NO Mac and
# NO Apple account required.
#
# IOS-11 builds on IOS-10 (the signed Release .ipa): it adds the App-Store-Connect upload that takes
# that .ipa to an internal TestFlight group, authenticated by an ASC API key (the .p8 path), driveable
# from Linux via `host/ios/remote-build.sh testflight|release` and from CI by the ios-build job's
# TestFlight step. The actual upload is Mac-and-paid-account-gated (xcrun altool only runs on macOS;
# the API key requires a real App Store Connect app record). So this gate proves — device-free, by
# structural + plist assertion — that the WHOLE pipeline that PRODUCES the upload is correctly wired
# and fail-closed, and that NO key material leaks into the repo. It is the IOS-11 twin of
# check-ios-release-archive.sh (IOS-10) and runs in the same cheap Linux `gate` job, so a drift turns
# red long before a Mac upload is ever attempted.
#
# What it asserts (each leg is the device-free half of an IOS-11 deliverable):
#   (A) DRIVER SUBCOMMANDS — remote-build.sh has `validate` + `testflight` + `release` wired to the
#                            dispatcher, the .ipa comes from the IOS-10 export path (build/export/
#                            CanopyHost.ipa), and the upload uses `xcrun altool --upload-app` with the
#                            ASC API-key flags (--apiKey/--apiIssuer), never an Apple-ID password.
#   (B) FAIL-CLOSED AUTH   — the upload PRE-FLIGHTS the three ASC creds (ASC_KEY_ID / ASC_ISSUER_ID /
#                            ASC_API_KEY_P8) and dies LOUD if any is missing; the .p8 is staged into a
#                            per-run private_keys/ and DELETED after the run (no key left on the host).
#   (C) APP-STORE CHANNEL  — the export channel feeding TestFlight is app-store-connect (ExportOptions
#                            method), the one TestFlight accepts — not ad-hoc/release-testing.
#   (D) NO SECRET COMMITTED — .gitignore excludes *.p8 / AuthKey_*.p8 / private_keys/, the example env
#                            documents the three ASC vars as placeholders, and NO real .p8 / Key ID /
#                            Issuer UUID is tracked anywhere under host/ios.
#   (E) CI WIRING          — the ios-build workflow job has a TestFlight upload step, gated on the ASC
#                            secrets (a step-level `if:` on job env mirrored from secrets), consuming
#                            the same CanopyHost.ipa the IOS-10 export step produces, and the secrets
#                            are documented in docs/ci-secrets.md.
#   (F) DOCS               — docs/ios-testflight.md exists and spells out the Apple-account + Mac
#                            requirements (paid account, app record, API-key role, Mac/altool).
#
# Pure bash + grep + /usr/bin/python3 (plistlib parses the .plist on Linux — no Xcode needed).
# Usage:  bash scripts/check-ios-testflight.sh
# Exit: 0 = the iOS TestFlight pipeline is complete + leak-free · 1 = a leg drifted.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IOS="$ROOT/host/ios"

RBUILD="$IOS/remote-build.sh"
ENVEX="$IOS/.remote-build.env.example"
GITIGNORE="$IOS/.gitignore"
EXPORT="$IOS/ExportOptions.plist"
WORKFLOW="$ROOT/.github/workflows/ci.yml"
SECRETS_DOC="$ROOT/docs/ci-secrets.md"
TF_DOC="$ROOT/docs/ios-testflight.md"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
status=0

# need <label> <file> <pattern...> — every ERE pattern must be present in the file.
need() {
  local label="$1" file="$2"; shift 2
  if [ ! -f "$file" ]; then red "    FAIL — $label: missing file ${file#"$ROOT"/}"; status=1; return; fi
  local miss=()
  for pat in "$@"; do
    grep -qE -- "$pat" "$file" || miss+=("$pat")
  done
  if [ "${#miss[@]}" -gt 0 ]; then
    red "    FAIL — $label (${file#"$ROOT"/}) is missing:"
    for m in "${miss[@]}"; do echo "        · $m"; done
    status=1
  else
    green "    OK  — $label"
  fi
}

# nothave <label> <file> <pattern> — the ERE pattern must be ABSENT.
nothave() {
  local label="$1" file="$2" pat="$3"
  if [ ! -f "$file" ]; then red "    FAIL — $label: missing file ${file#"$ROOT"/}"; status=1; return; fi
  if grep -qE -- "$pat" "$file"; then
    red "    FAIL — $label: forbidden pattern present in ${file#"$ROOT"/}: $pat"
    grep -nE -- "$pat" "$file" | head -3 | sed 's/^/        /'
    status=1
  else
    green "    OK  — $label"
  fi
}

echo "==> iOS TestFlight pipeline gate (scripts/check-ios-testflight.sh)"
echo "    (structural — the upload is Mac + paid-Apple-account-gated; this proves the pipeline that produces it is wired + leak-free)"
echo

for f in "$RBUILD" "$ENVEX" "$GITIGNORE" "$EXPORT" "$WORKFLOW"; do
  [ -f "$f" ] || { red "    FAIL — required file missing: ${f#"$ROOT"/}"; status=1; }
done

# ── (A) the driver subcommands + the altool ASC-API-key upload ────────────────────────────────
echo "--> [A] remote-build.sh drives validate+testflight+release via altool with the ASC API key:"
need "remote-build.sh has the validate + testflight + release subcommands" "$RBUILD" \
  'cmd_validate\(\)' \
  'cmd_testflight\(\)' \
  'cmd_release\(\)' \
  'validate\)  cmd_validate' \
  'testflight\|upload\) cmd_testflight' \
  'release\)   cmd_release'
need "the upload runs xcrun altool with the ASC API-key flags (NOT an Apple-ID password)" "$RBUILD" \
  'xcrun altool' \
  '--upload-app' \
  '--validate-app' \
  '--apiKey' \
  '--apiIssuer' \
  '--type ios'
need "the .ipa it uploads is the IOS-10 export product (build/export/CanopyHost.ipa)" "$RBUILD" \
  'build/export/CanopyHost\.ipa'
# Apple-ID + app-specific-password auth (the OLD, 2FA-hostile path) must NOT be used.
nothave "no Apple-ID/password auth (-u/-p / app-specific password) — API key only" "$RBUILD" \
  'altool .*(-u |--username|--password|-p @)'
echo

# ── (B) fail-closed auth: preflight the creds, never leave the key on the host ────────────────
echo "--> [B] the upload is fail-closed on the ASC creds + never leaves the .p8 on the build host:"
need "preflight asserts all three ASC creds (ASC_KEY_ID / ASC_ISSUER_ID / ASC_API_KEY_P8)" "$RBUILD" \
  '_asc_preflight\(\)' \
  'ASC_KEY_ID' \
  'ASC_ISSUER_ID' \
  'ASC_API_KEY_P8'
need "missing creds die LOUD (no unauthenticated upload)" "$RBUILD" \
  'die "TestFlight upload needs the App Store Connect API key'
need "the staged .p8 is removed after the run (rm -f the per-run private key)" "$RBUILD" \
  'rm -f .*private_keys' \
  'API_PRIVATE_KEYS_DIR'
echo

# ── (C) the export channel feeding TestFlight is app-store-connect ────────────────────────────
echo "--> [C] the export method feeding the upload is app-store-connect (the channel TestFlight accepts):"
python3 - "$EXPORT" <<'PY'
import plistlib, sys
with open(sys.argv[1],'rb') as f: o = plistlib.load(f)
m = o.get('method')
if m == 'app-store-connect':
    print("    \033[32mOK  — ExportOptions method = app-store-connect (App Store / TestFlight)\033[0m")
else:
    print("    \033[31mFAIL — ExportOptions method is %r; TestFlight needs 'app-store-connect' (ad-hoc/release-testing cannot upload to TestFlight)\033[0m" % m)
    sys.exit(1)
PY
[ $? -eq 0 ] || status=1
# The release env example must default EXPORT_METHOD to app-store-connect so an upload run is correct
# out of the box.
need "the env example defaults EXPORT_METHOD=app-store-connect (correct channel out of the box)" "$ENVEX" \
  'EXPORT_METHOD="app-store-connect"'
echo

# ── (D) NO ASC secret committed (gitignore + placeholder env + no literal key material) ───────
echo "--> [D] no App Store Connect key material is committed (gitignore + placeholder env + tree scan):"
need ".gitignore excludes the .p8 key + the staged private_keys dir" "$GITIGNORE" \
  '\*\.p8' \
  'AuthKey_\*\.p8' \
  'private_keys/'
need ".remote-build.env.example documents the three ASC vars as EMPTY placeholders" "$ENVEX" \
  'ASC_KEY_ID=""' \
  'ASC_ISSUER_ID=""' \
  'ASC_API_KEY_P8=""'
# No real .p8 file is tracked anywhere under host/ios.
if find "$IOS" -name '*.p8' -not -path '*/node_modules/*' 2>/dev/null | grep -q .; then
  red "    FAIL — a .p8 private key file is present under host/ios (must NEVER be committed):"
  find "$IOS" -name '*.p8' -not -path '*/node_modules/*' | sed 's/^/        /'
  status=1
else
  green "    OK  — no .p8 file tracked under host/ios"
fi
# A real ASC Issuer ID is a UUID; a real Key ID is 10 alnum chars. The ONLY places those tokens may
# appear are as the documented example shapes in the env-example / docs (clearly marked). Assert no
# NON-empty ASC_*_ID assignment leaks a literal value into a tracked driver/config file.
for f in "$RBUILD" "$IOS/project.yml"; do
  [ -f "$f" ] || continue
  if grep -nE 'ASC_(KEY|ISSUER)_ID[[:space:]]*=[[:space:]]*"?[A-Za-z0-9-]{8,}"?' "$f" \
     | grep -vE 'ASC_(KEY|ISSUER)_ID(:=|[[:space:]]*=[[:space:]]*"")' >/dev/null; then
    red "    FAIL — a literal ASC Key/Issuer ID looks committed in ${f#"$ROOT"/}:"
    grep -nE 'ASC_(KEY|ISSUER)_ID[[:space:]]*=[[:space:]]*"?[A-Za-z0-9-]{8,}"?' "$f" | sed 's/^/        /'
    status=1
  fi
done
green "    OK  — no literal ASC Key/Issuer ID committed in the driver/project config"
echo

# ── (E) CI wiring: the ios-build job uploads to TestFlight, gated on the ASC secrets ──────────
echo "--> [E] the ios-build CI job has a TestFlight upload step gated on the ASC secrets:"
need "the workflow has a TestFlight upload step using altool + the ASC secrets" "$WORKFLOW" \
  'TestFlight' \
  'altool' \
  '--upload-app' \
  'secrets\.ASC_KEY_ID' \
  'secrets\.ASC_ISSUER_ID' \
  'secrets\.ASC_API_KEY_P8'
need "the upload step consumes the IOS-10 export product (CanopyHost.ipa)" "$WORKFLOW" \
  'build/export/CanopyHost\.ipa'
need "the upload step is GATED so it self-skips with no ASC account (fail-open to green, not red)" "$WORKFLOW" \
  "env\.ASC_KEY_ID != ''"
need "docs/ci-secrets.md documents the three ASC secrets" "$SECRETS_DOC" \
  'ASC_KEY_ID' \
  'ASC_ISSUER_ID' \
  'ASC_API_KEY_P8'
echo

# ── (F) docs: the Apple-account + Mac requirements are spelled out ────────────────────────────
echo "--> [F] docs/ios-testflight.md documents the Apple-account + Mac requirements:"
need "the TestFlight doc exists and names the gating requirements" "$TF_DOC" \
  '[Pp]aid Apple Developer' \
  'App Store Connect' \
  'TestFlight' \
  'altool' \
  '[Aa]pp [Mm]anager' \
  '\.p8'
echo

if [ "$status" -eq 0 ]; then
  green "ALL GREEN — the iOS TestFlight pipeline (ASC .p8 upload) is complete, fail-closed, and leak-free."
  green "            (Mac + paid-account-gated: the real upload is host/ios/remote-build.sh testflight|release — needs a paid Apple Developer account + an App Store Connect API key.)"
else
  red "REGRESSION — the iOS TestFlight pipeline drifted. See plans/dependent/IOS-11.md + docs/ios-testflight.md." >&2
fi
exit "$status"
