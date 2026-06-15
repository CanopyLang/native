#!/usr/bin/env bash
# bump-check.sh — does upstream ship a newer Hermes/Yoga (React-Native) or onnxruntime? (RNV-8).
#
# WHY THIS EXISTS
# ──────────────
# The host pins ONE React-Native release (its hermes-engine + Yoga pods → the Hermes/JSI/Yoga
# ABI) and ONE onnxruntime release. A solo dev otherwise has to REMEMBER to periodically check
# whether upstream moved. RNV-8 turns that into a scheduled signal: this script — driven by the
# `bump-check` cron in .github/workflows/ci.yml — queries Maven Central for the latest released
# version of each pinned coordinate and compares it to host/vendor.lock.json. When a newer one
# exists it prints a body the workflow files as a GitHub issue ("react-native 0.77.x is available;
# our pin is 0.76.9 — re-vendor + re-run check-abi.sh"). Nothing is downloaded or changed: this
# is a read-only cadence check (curl + jq only; no stack, no SDK, no Mac).
#
# USAGE
#   bash scripts/bump-check.sh                 # human-readable report to stdout
#   bash scripts/bump-check.sh --issue-body    # emit a Markdown issue body to stdout IFF a bump
#                                              #   is available; exit 10 = "bump available" (the
#                                              #   CI cron opens an issue on exit 10), 0 = up to
#                                              #   date, 1 = an error (network/parse).
#
# Maven Central metadata: https://repo1.maven.org/maven2/<group-path>/maven-metadata.xml carries
# <release> (the newest non-SNAPSHOT) and a <versions> list. We read <release> and also pick the
# greatest STABLE version (no -rc/-beta/-SNAPSHOT) so a pre-release upstream tag never nags.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$ROOT/host/vendor.lock.json"
MAVEN="${CANOPY_MAVEN_BASE:-https://repo1.maven.org/maven2}"

MODE="report"
case "${1:-}" in
  ""|--report)   MODE="report" ;;
  --issue-body)  MODE="issue-body" ;;
  -h|--help)     sed -n '2,30p' "$0"; exit 0 ;;
  *) printf 'bump-check: unknown arg %s (try --report | --issue-body)\n' "$1" >&2; exit 2 ;;
esac

die()  { printf 'bump-check: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "required tool '$1' not on PATH"; }

need curl
need jq
[ -f "$LOCK" ] || die "lock not found: ${LOCK#"$ROOT"/}"

# ── current pins from the lock ────────────────────────────────────────────────────────────────
# react-native: the hermes-engine pod-pin version IS the RN release (Yoga moves with it).
locked_rn="$(jq -r '.artifacts[] | select(.relPath == "hermes-engine") | .version' "$LOCK")"
# onnxruntime: read from the vendored onnxruntime .so artifact's version.
locked_onnx="$(jq -r '[.artifacts[] | select(.relPath | test("onnxruntime/lib/")) | .version] | first // empty' "$LOCK")"
[ -n "$locked_rn" ]   || die "could not read the react-native pin (hermes-engine) from the lock"
[ -n "$locked_onnx" ] || die "could not read the onnxruntime pin from the lock"

# ── version helpers (pure bash; numeric dot-compare) ──────────────────────────────────────────
# Returns 0 (true) if $1 is strictly greater than $2, comparing dotted numeric components.
ver_gt() {
  local a="$1" b="$2" ia ib i
  IFS='.' read -ra ia <<<"$a"
  IFS='.' read -ra ib <<<"$b"
  for ((i = 0; i < ${#ia[@]} || i < ${#ib[@]}; i++)); do
    local na="${ia[i]:-0}" nb="${ib[i]:-0}"
    # strip any non-numeric suffix (e.g. a stray tag) so the compare stays arithmetic
    na="${na//[!0-9]/}"; nb="${nb//[!0-9]/}"
    na="${na:-0}"; nb="${nb:-0}"
    if ((10#$na > 10#$nb)); then return 0; fi
    if ((10#$na < 10#$nb)); then return 1; fi
  done
  return 1
}

# latest_stable <group-path> <artifact> — greatest non-prerelease version from Maven metadata.
latest_stable() {
  local group="$1" artifact="$2"
  local url="$MAVEN/$group/$artifact/maven-metadata.xml"
  local xml
  xml="$(curl -fsSL --retry 3 --retry-delay 2 "$url" 2>/dev/null)" || {
    printf 'bump-check: WARN could not fetch %s\n' "$url" >&2
    return 1
  }
  # Pull every <version>…</version>, drop pre-releases/snapshots, sort by version, take the last.
  printf '%s\n' "$xml" \
    | grep -oE '<version>[^<]+</version>' \
    | sed -E 's:</?version>::g' \
    | grep -viE '(-rc|-beta|-alpha|-snapshot|-m[0-9])' \
    | sort -t. -k1,1n -k2,2n -k3,3n \
    | tail -1
}

# Maven coordinates for the pinned artifacts.
RN_GROUP="com/facebook/react"   ; RN_ARTIFACT="react-android"
ONNX_GROUP="com/microsoft/onnxruntime" ; ONNX_ARTIFACT="onnxruntime-android"

latest_rn="$(latest_stable "$RN_GROUP" "$RN_ARTIFACT" || true)"
latest_onnx="$(latest_stable "$ONNX_GROUP" "$ONNX_ARTIFACT" || true)"

# ── decide what (if anything) is newer ────────────────────────────────────────────────────────
rn_bump=0 ; onnx_bump=0
[ -n "$latest_rn" ]   && ver_gt "$latest_rn"   "$locked_rn"   && rn_bump=1
[ -n "$latest_onnx" ] && ver_gt "$latest_onnx" "$locked_onnx" && onnx_bump=1
any_bump=$(( rn_bump + onnx_bump ))

# ── output ────────────────────────────────────────────────────────────────────────────────────
if [ "$MODE" = "report" ]; then
  echo "==> bump-check: pinned vs latest-stable upstream"
  echo
  printf '  %-26s pinned %-10s latest %-10s  %s\n' "react-native (hermes/yoga)" "$locked_rn"   "${latest_rn:-?}"   "$([ "$rn_bump"   = 1 ] && echo 'BUMP AVAILABLE' || echo 'up to date')"
  printf '  %-26s pinned %-10s latest %-10s  %s\n' "onnxruntime"                "$locked_onnx" "${latest_onnx:-?}" "$([ "$onnx_bump" = 1 ] && echo 'BUMP AVAILABLE' || echo 'up to date')"
  echo
  if [ "$any_bump" -gt 0 ]; then
    echo "A newer upstream is available. To adopt it, re-vendor + re-validate the ABI:"
    echo "  scripts/revendor.sh fetch <new-rn>   # Android .so + headers (byte-verified)"
    echo "  scripts/revendor.sh lock             # rewrite host/vendor.lock.json"
    echo "  scripts/check-abi.sh                 # move the C++ bytecode/RN pin in lockstep"
    echo "  scripts/check-vendor-pins.sh         # update the Podfile + CMakeLists pins together"
  else
    echo "All pins are at the latest stable upstream."
  fi
  exit 0
fi

# --issue-body: print a Markdown body ONLY when a bump exists; exit 10 signals the cron to file it.
if [ "$any_bump" -eq 0 ]; then
  echo "bump-check: all pins up to date (react-native $locked_rn, onnxruntime $locked_onnx)." >&2
  exit 0
fi

{
  echo "## Upstream dependency bump available (automated — RNV-8 bump-check)"
  echo
  echo "The scheduled \`bump-check\` cron found a newer **stable** release upstream than the"
  echo "version pinned in \`host/vendor.lock.json\`. The Hermes/JSI/Yoga ABI is only matched"
  echo "while the pins agree, so adopting a bump means re-vendoring **and** re-running the ABI gate."
  echo
  echo "| coordinate | pinned | latest stable |"
  echo "|---|---|---|"
  [ "$rn_bump"   = 1 ] && echo "| react-native (hermes-engine + Yoga) | \`$locked_rn\` | \`$latest_rn\` |"
  [ "$onnx_bump" = 1 ] && echo "| onnxruntime-android | \`$locked_onnx\` | \`$latest_onnx\` |"
  echo
  echo "### To adopt"
  echo
  if [ "$rn_bump" = 1 ]; then
    echo "- [ ] \`scripts/revendor.sh fetch $latest_rn\` — refetch Android Hermes/JSI .so + headers (byte-verified)"
    echo "- [ ] update \`\$RN_VERSION\` in \`host/ios/Podfile\` to \`$latest_rn\` and re-run \`pod install\` on a Mac"
    echo "- [ ] update \`kCanopyExpectedRnVersion\` (+ the bytecode version) in \`host/shared/cpp/CanopyAbiGate.h\`"
  fi
  if [ "$onnx_bump" = 1 ]; then
    echo "- [ ] bump \`CANOPY_ONNX_VERSION\`/\`ONNX_VERSION\` in the vendor scripts and refetch onnxruntime"
  fi
  echo "- [ ] \`scripts/revendor.sh lock\` — rewrite \`host/vendor.lock.json\`"
  echo "- [ ] \`scripts/check-abi.sh\` && \`scripts/check-vendor-pins.sh\` — must both go green"
  echo
  echo "_Filed automatically by \`scripts/bump-check.sh\` via the scheduled CI job. If you do not"
  echo "want to bump yet, close this issue; it will re-open on the next schedule while a newer"
  echo "release remains available._"
}

exit 10
