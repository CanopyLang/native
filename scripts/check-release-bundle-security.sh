#!/usr/bin/env bash
# check-release-bundle-security.sh — the device-free half of RB-3's release-validation safety gate.
#
# A shipped (release) APK must NOT have a world-writable, unsigned dynamic-code-load path: it must
# never boot a bundle planted at /data/local/tmp, and it must refuse to boot a tampered/stale baked
# bundle (App Store guideline 2.5.2 / Android security review). MainActivity.readBundle() +
# verifyBundleIntegrity() enforce that at runtime; the runtime proof lives in
# `host/android/remote-build.sh release-security` (needs a booted device).
#
# THIS script is the cheap, device-free source-guard that runs in CI's `gate` job and locally. It
# greps MainActivity.java and FAILS LOUD if the safety shape regresses:
#   (1) the /data/local/tmp override is read ONLY inside `if (BuildConfig.DEBUG)`  — a release build
#       must never consult the tmp path;
#   (2) every `throw new SecurityException` (the fail-closed integrity refusals) is reachable only
#       under a `!BuildConfig.DEBUG` guard — a release build crashes rather than boots a
#       tampered/missing-manifest bundle, while DEBUG stays lenient.
#
# It is pure bash + awk + grep (no device, no SDK, no compiler).
#
# Usage:  bash scripts/check-release-bundle-security.sh
# Exit:   0 = safety shape intact (green) · 1 = a regression was found.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/host/android/app/src/main/java/com/canopyhost/MainActivity.java"
TMP_PATH='/data/local/tmp/canopy.bundle.js'

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

status=0

echo "==> release bundle-load security guard (scripts/check-release-bundle-security.sh)"
echo "    source: host/android/app/src/main/java/com/canopyhost/MainActivity.java"
echo

[ -f "$SRC" ] || { red "    FAIL — MainActivity.java not found at $SRC"; exit 1; }

# ── (1) the dev override File must be DEBUG-gated ────────────────────────────────────────
# Find every line that names the /data/local/tmp override path and confirm it sits inside a
# `if (BuildConfig.DEBUG) {` block (i.e. there is an unclosed DEBUG-gated brace above it). We
# track brace depth and the depth at which the most recent `if (BuildConfig.DEBUG)` opened.
echo "--> [1/3] /data/local/tmp override is read ONLY inside if (BuildConfig.DEBUG):"
guard_report="$(awk -v needle="$TMP_PATH" '
  {
    line = $0
    # Opening of a BuildConfig.DEBUG branch on this line?
    if (line ~ /if[[:space:]]*\([[:space:]]*BuildConfig\.DEBUG[[:space:]]*\)/) {
      debug_open_depth = depth + 1     # the block this if opens lives one level deeper
    }
    # Does this line reference the tmp override path?
    if (index(line, needle) > 0) {
      if (debug_open_depth > 0 && depth >= debug_open_depth)
        print "OK " NR
      else
        print "BAD " NR
    }
    # Update brace depth AFTER classifying this line.
    n = gsub(/{/, "{", line); depth += n
    m = gsub(/}/, "}", line); depth -= m
    if (debug_open_depth > 0 && depth < debug_open_depth) debug_open_depth = 0
  }
' "$SRC")"

tmp_refs="$(printf '%s\n' "$guard_report" | grep -c . || true)"
bad_refs="$(printf '%s\n' "$guard_report" | grep -c '^BAD ' || true)"
if [ "$tmp_refs" -eq 0 ]; then
  red "    FAIL — no reference to $TMP_PATH found; the dev-override guard may have moved."
  red "           This guard exists to keep that path DEBUG-gated; verify MainActivity.readBundle()."
  status=1
elif [ "$bad_refs" -ne 0 ]; then
  red "    FAIL — $bad_refs reference(s) to $TMP_PATH are NOT inside if (BuildConfig.DEBUG):"
  printf '%s\n' "$guard_report" | awk '/^BAD /{print "      line " $2}'
  red "           A release build must never read the tmp override (App Store 2.5.2 substitution vector)."
  status=1
else
  green "    OK — all $tmp_refs reference(s) to the tmp override are DEBUG-gated."
fi
echo

# ── (2) every throw new SecurityException must be release-only (!BuildConfig.DEBUG) ──────
# Each fail-closed throw is wrapped in `if (!BuildConfig.DEBUG) { ... throw ... }`. Verify every
# `throw new SecurityException` sits inside an open `if (!BuildConfig.DEBUG)` block.
echo "--> [2/3] throw new SecurityException reachable ONLY under !BuildConfig.DEBUG (fail-closed in release):"
sec_report="$(awk '
  {
    line = $0
    if (line ~ /if[[:space:]]*\([[:space:]]*![[:space:]]*BuildConfig\.DEBUG[[:space:]]*\)/) {
      notdebug_open_depth = depth + 1
    }
    if (line ~ /throw[[:space:]]+new[[:space:]]+SecurityException/) {
      if (notdebug_open_depth > 0 && depth >= notdebug_open_depth)
        print "OK " NR
      else
        print "BAD " NR
    }
    n = gsub(/{/, "{", line); depth += n
    m = gsub(/}/, "}", line); depth -= m
    if (notdebug_open_depth > 0 && depth < notdebug_open_depth) notdebug_open_depth = 0
  }
' "$SRC")"

throw_refs="$(printf '%s\n' "$sec_report" | grep -c . || true)"
bad_throws="$(printf '%s\n' "$sec_report" | grep -c '^BAD ' || true)"
if [ "$throw_refs" -eq 0 ]; then
  red "    FAIL — no 'throw new SecurityException' found; the fail-closed integrity check may have"
  red "           been weakened. verifyBundleIntegrity() must refuse to boot in release on mismatch."
  status=1
elif [ "$bad_throws" -ne 0 ]; then
  red "    FAIL — $bad_throws SecurityException throw(s) are NOT guarded by if (!BuildConfig.DEBUG):"
  printf '%s\n' "$sec_report" | awk '/^BAD /{print "      line " $2}'
  red "           A throw that also fires in DEBUG would break the hot-reload loop; one that does NOT"
  red "           fire in release would let a tampered/stale bundle boot. Both are wrong."
  status=1
else
  green "    OK — all $throw_refs SecurityException throw(s) are release-only (fail-closed)."
fi
echo

# ── (3) the runtime markers the device test asserts on must still exist verbatim ─────────
# remote-build.sh release-security greps logcat for these EXACT strings. If either is renamed,
# that runtime assertion silently breaks — catch it here, device-free.
echo "--> [3/3] runtime log markers used by remote-build.sh release-security exist verbatim:"
markers_ok=1
for marker in 'hot-reload: booting dev bundle' 'bundle integrity OK'; do
  if grep -qF "$marker" "$SRC"; then
    green "    OK — found: \"$marker\""
  else
    red   "    FAIL — missing log marker: \"$marker\" (remote-build.sh release-security greps for it)"
    markers_ok=0
    status=1
  fi
done
[ "$markers_ok" -eq 1 ] || true
echo

if [ "$status" -eq 0 ]; then
  green "ALL GREEN — release bundle-load safety shape intact (tmp override DEBUG-gated; integrity fail-closed in release)."
else
  red "REGRESSION — release bundle-load safety shape changed. See MainActivity.readBundle()/verifyBundleIntegrity()." >&2
fi
exit "$status"
