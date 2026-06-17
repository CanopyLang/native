#!/usr/bin/env bash
# check-ios-release-archive.sh — IOS-10 structural gate for the iOS Release archive config
# (signing / ATS / entitlements). NO Mac required.
#
# The iOS host cannot be ARCHIVED off macOS (xcodebuild/codesign are Apple-only), so this gate proves
# — device-free, by structural + plist assertion — that the CONFIG=Release device archive path is
# fully and correctly configured: a production-signed .ipa would carry the right entitlements, an
# App-Store-clean ATS posture, and a dead-strip-safe link so the weak-loaded/registry-reached
# registrations survive -Os. It fails LOUD in CI's cheap Linux `gate` job if any of that drifts, long
# before a Mac archive ever runs — exactly like check-release-bundle-security.sh does for the Android
# release APK. It is the iOS analog of AND-2 (the Android signed-release config).
#
# What it asserts (each leg is the device-free half of an IOS-10 deliverable):
#   (A) RELEASE ENTITLEMENTS  — CanopyHostRelease.entitlements exists, flips aps-environment to
#                               `production`, and agrees with the Debug entitlements on EVERY OTHER
#                               key (keychain group, in-app-payments) so a capability can't be added
#                               to one file but silently dropped from the shipped build.
#   (B) PROJECT WIRING        — project.yml wires the Release config to the production entitlements,
#                               sets Automatic signing with an INJECTED (not committed) Team ID, turns
#                               bitcode off, and the archive scheme is Release.
#   (C) DEAD-STRIP SAFETY     — the -Os Release archive keeps the registry-reached symbols: the app
#                               links with -ObjC + -all_load (force-load every ObjC class/category so
#                               the +load-time module registrations and the weak Core ML factory are
#                               not dropped), and DEAD_CODE_STRIPPING strips only genuinely-dead code.
#   (D) ATS POSTURE           — Info.plist ENFORCES ATS for production: no NSAllowsArbitraryLoads, and
#                               the ONLY exception is NSAllowsLocalNetworking (the inert, debug-only
#                               dev-loop belt). A blanket cleartext exception would fail the gate.
#   (E) EXPORT OPTIONS        — ExportOptions.plist exists with method=app-store-connect, automatic
#                               signing, no committed literal Team ID, and uploadSymbols=true.
#   (F) DRIVER + IGNORE       — remote-build.sh has the `archive` + `export` subcommands wired, and
#                               .gitignore excludes the .xcarchive/.ipa/generated export options.
#
# Pure bash + grep + /usr/bin/python3 (plistlib parses the .plist/.entitlements XML on Linux — no
# plutil/Xcode needed). Usage:  bash scripts/check-ios-release-archive.sh
# Exit: 0 = the iOS release-archive config is complete + App-Store-clean · 1 = a leg drifted.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IOS="$ROOT/host/ios"

ENT_DEBUG="$IOS/CanopyHostApp/CanopyHost.entitlements"
ENT_RELEASE="$IOS/CanopyHostApp/CanopyHostRelease.entitlements"
PROJECT="$IOS/project.yml"
PLIST="$IOS/CanopyHostApp/Info.plist"
EXPORT="$IOS/ExportOptions.plist"
RBUILD="$IOS/remote-build.sh"
GITIGNORE="$IOS/.gitignore"

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

# nothave <label> <file> <pattern> — the ERE pattern must be ABSENT (in a non-comment line).
nothave() {
  local label="$1" file="$2" pat="$3"
  if [ ! -f "$file" ]; then red "    FAIL — $label: missing file ${file#"$ROOT"/}"; status=1; return; fi
  if grep -qE -- "$pat" "$file"; then
    red "    FAIL — $label: forbidden pattern present in ${file#"$ROOT"/}: $pat"
    status=1
  else
    green "    OK  — $label"
  fi
}

echo "==> iOS release-archive config gate (scripts/check-ios-release-archive.sh)"
echo "    (structural — the iOS host cannot be archived off macOS; this proves the signing/ATS/entitlements config is complete + App-Store-clean)"
echo

for f in "$ENT_DEBUG" "$ENT_RELEASE" "$PROJECT" "$PLIST" "$EXPORT" "$RBUILD"; do
  [ -f "$f" ] || { red "    FAIL — required file missing: ${f#"$ROOT"/}"; status=1; }
done

# ── (A) the release entitlements (production APNs, in lockstep with Debug otherwise) ─────────
echo "--> [A] CanopyHostRelease.entitlements: aps-environment=production, otherwise == Debug set:"
python3 - "$ENT_DEBUG" "$ENT_RELEASE" <<'PY'
import plistlib, sys
dbg_p, rel_p = sys.argv[1], sys.argv[2]
fail = False
def load(p):
    with open(p,'rb') as f: return plistlib.load(f)
try:
    dbg, rel = load(dbg_p), load(rel_p)
except Exception as e:
    print("    \033[31mFAIL — could not parse an entitlements plist: %s\033[0m" % e); sys.exit(1)

# aps-environment must be production in release, development in debug.
if rel.get('aps-environment') != 'production':
    print("    \033[31mFAIL — release aps-environment is %r, expected 'production'\033[0m" % rel.get('aps-environment')); fail = True
else:
    print("    \033[32mOK  — release aps-environment = production\033[0m")
if dbg.get('aps-environment') != 'development':
    print("    \033[31mFAIL — debug aps-environment is %r, expected 'development' (the dev set must NOT ship production APNs)\033[0m" % dbg.get('aps-environment')); fail = True
else:
    print("    \033[32mOK  — debug aps-environment = development (kept distinct)\033[0m")

# Every OTHER key must be IDENTICAL between the two files (no capability added to one but not the other).
dk = {k:v for k,v in dbg.items() if k != 'aps-environment'}
rk = {k:v for k,v in rel.items() if k != 'aps-environment'}
if dk != rk:
    print("    \033[31mFAIL — Debug/Release entitlements diverge on a non-APNs key:\033[0m")
    for k in sorted(set(dk)|set(rk)):
        if dk.get(k) != rk.get(k):
            print("        · %s: debug=%r release=%r" % (k, dk.get(k), rk.get(k)))
    fail = True
else:
    print("    \033[32mOK  — keychain-access-groups + in-app-payments match the Debug set exactly\033[0m")

# The capability entitlements the shipped build needs must be present.
for k in ('keychain-access-groups','com.apple.developer.in-app-payments'):
    if k not in rel:
        print("    \033[31mFAIL — release entitlements missing required capability: %s\033[0m" % k); fail = True
    else:
        print("    \033[32mOK  — release carries %s\033[0m" % k)

sys.exit(1 if fail else 0)
PY
[ $? -eq 0 ] || status=1
echo

# ── (B) project.yml wiring (Release config -> production entitlements + injected-team signing) ──
echo "--> [B] project.yml wires the Release archive path (entitlements + automatic signing + bitcode off):"
need "Release config points CODE_SIGN_ENTITLEMENTS at the production entitlements" "$PROJECT" \
  'CanopyHostApp/CanopyHostRelease\.entitlements'
need "automatic signing with an INJECTED (placeholder) team + bitcode off" "$PROJECT" \
  'CODE_SIGN_STYLE: Automatic' \
  'DEVELOPMENT_TEAM: ""' \
  'ENABLE_BITCODE: NO'
need "the scheme archives the Release configuration" "$PROJECT" \
  'archive:' \
  'config: Release'
# A literal 10-char Team ID must NEVER be committed (only the injected placeholder / token form).
nothave "no real DEVELOPMENT_TEAM is committed (injected at archive time)" "$PROJECT" \
  'DEVELOPMENT_TEAM: *"?[A-Z0-9]{10}"?'
echo

# ── (C) dead-strip safety for the -Os archive (the load-bearing IOS-10 link flag) ───────────
echo "--> [C] -Os archive keeps the registry-reached registrations (no dead-strip of weak-loaded symbols):"
need "the app force-loads every ObjC class/category (-ObjC + -all_load)" "$PROJECT" \
  '"-ObjC"' \
  '"-all_load"'
need "Release strips only genuinely-dead code + emits a dSYM" "$PROJECT" \
  'DEAD_CODE_STRIPPING: YES' \
  'DEBUG_INFORMATION_FORMAT: "dwarf-with-dsym"'
echo

# ── (D) ATS posture: enforced for production, only the inert local-networking belt ──────────
echo "--> [D] Info.plist ATS posture is App-Store-clean (enforced; no blanket cleartext):"
python3 - "$PLIST" <<'PY'
import plistlib, sys
with open(sys.argv[1],'rb') as f: d = plistlib.load(f)
ats = d.get('NSAppTransportSecurity', {})
fail = False
# NSAllowsArbitraryLoads (a blanket cleartext exception) must be ABSENT or false — App Store review
# rejects a release that disables ATS wholesale.
if ats.get('NSAllowsArbitraryLoads'):
    print("    \033[31mFAIL — NSAllowsArbitraryLoads is true; a release build must ENFORCE ATS (App Store review)\033[0m"); fail = True
else:
    print("    \033[32mOK  — no blanket NSAllowsArbitraryLoads (ATS enforced for production)\033[0m")
# The local-networking belt (inert in release; the dev client is compiled out) is the ONLY exception.
if ats.get('NSAllowsLocalNetworking') is True:
    print("    \033[32mOK  — NSAllowsLocalNetworking present (the inert, debug-only dev-loop belt)\033[0m")
else:
    print("    \033[31mFAIL — NSAllowsLocalNetworking expected true (the ATS belt to the dev-loop cleartext allowlist)\033[0m"); fail = True
# Any NSExceptionDomains entry must NOT itself re-open arbitrary cleartext.
for dom, cfg in (ats.get('NSExceptionDomains') or {}).items():
    if isinstance(cfg, dict) and cfg.get('NSExceptionAllowsInsecureHTTPLoads'):
        print("    \033[31mFAIL — exception domain %s allows insecure HTTP loads (cleartext to a named host)\033[0m" % dom); fail = True
sys.exit(1 if fail else 0)
PY
[ $? -eq 0 ] || status=1
echo

# ── (E) ExportOptions.plist (the -exportArchive config) ──────────────────────────────────────
echo "--> [E] ExportOptions.plist: app-store-connect, automatic signing, no committed team, symbols up:"
python3 - "$EXPORT" <<'PY'
import plistlib, sys, re
with open(sys.argv[1],'rb') as f: o = plistlib.load(f)
fail = False
def chk(cond, ok, bad):
    global fail
    print(("    \033[32mOK  — %s\033[0m" % ok) if cond else ("    \033[31mFAIL — %s\033[0m" % bad))
    if not cond: fail = True
chk(o.get('method') == 'app-store-connect', "method = app-store-connect (production channel)",
    "method is %r, expected 'app-store-connect'" % o.get('method'))
chk(o.get('signingStyle') == 'automatic', "signingStyle = automatic (Xcode-managed)",
    "signingStyle is %r, expected 'automatic'" % o.get('signingStyle'))
chk(o.get('uploadSymbols') is True, "uploadSymbols = true (native crash symbolication)",
    "uploadSymbols is %r, expected true" % o.get('uploadSymbols'))
chk(o.get('compileBitcode') is False, "compileBitcode = false (bitcode deprecated)",
    "compileBitcode is %r, expected false" % o.get('compileBitcode'))
# teamID must be a placeholder token ($(...)) or absent — never a literal 10-char Team ID.
team = o.get('teamID', '')
chk(team == '' or team.startswith('$('), "teamID is a placeholder ($(DEVELOPMENT_TEAM)), no literal committed",
    "teamID is a literal %r — a real Team ID must NEVER be committed" % team)
if re.fullmatch(r'[A-Z0-9]{10}', str(team)):
    print("    \033[31mFAIL — teamID looks like a real 10-char Team ID; do not commit it\033[0m"); fail = True
sys.exit(1 if fail else 0)
PY
[ $? -eq 0 ] || status=1
echo

# ── (F) the driver subcommands + the gitignore for the signed outputs ───────────────────────
echo "--> [F] remote-build.sh drives archive+export; .gitignore excludes the signed outputs:"
need "remote-build.sh has the archive + export subcommands (xcodebuild archive / -exportArchive)" "$RBUILD" \
  'cmd_archive\(\)' \
  'cmd_export\(\)' \
  'archive\)   cmd_archive' \
  'export\)    cmd_export' \
  'xcodebuild' \
  '-exportArchive' \
  '-exportOptionsPlist' \
  '-allowProvisioningUpdates' \
  '-configuration .*ARCHIVE_CONFIG' \
  'ARCHIVE_CONFIG:=Release'
need ".gitignore excludes the .xcarchive / .ipa / generated export options" "$GITIGNORE" \
  '\*\.xcarchive' \
  '\*\.ipa' \
  'ExportOptions\.generated\.plist'
echo

if [ "$status" -eq 0 ]; then
  green "ALL GREEN — the iOS release-archive config (signing / ATS / entitlements) is complete and App-Store-clean."
  green "            (Mac-gated: the real archive + export run is host/ios/remote-build.sh archive|export — needs a paid Apple Developer account.)"
else
  red "REGRESSION — the iOS release-archive config drifted. See plans/dependent/IOS-10.md + host/ios/BUILD-AND-VALIDATE.md §6." >&2
fi
exit "$status"
