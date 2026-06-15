#!/usr/bin/env bash
# fetch-vendor.sh — restore the large, fetchable vendored .so blobs from upstream (CI-5).
#
# WHY THIS EXISTS
# ──────────────
# The Android host links a handful of third-party prebuilt .so files (Hermes/JSI from the
# React-Native 0.76.9 AARs + onnxruntime). Two of those — the per-ABI libonnxruntime.so —
# are ~27–33 MB each, so committing them made a fresh `git clone` carry ~64 MB of binaries
# that churn on every RN/onnx bump. CI-5's decision (see docs/vendored-binaries.md): do NOT
# use Git LFS; instead KEEP the binaries out of the working tree's git history and fetch them
# on demand here, keyed to the checksummed host/vendor.lock.json. A fresh clone is now < 50 MB.
#
# WHAT IS / ISN'T FETCHED
# ───────────────────────
#   FETCHED (reproducible byte-identically from a single Maven coordinate — proven in
#   scripts/revendor.sh, whose `fetch` reproduces these and re-verifies the lock green):
#     • host/android/vendor/lib/<abi>/libhermes.so            ⟵ hermes-android-<rn>-release.aar
#     • host/android/vendor/lib/<abi>/libjsi.so               ⟵ react-android-<rn>-release.aar
#     • host/android/vendor/onnxruntime/lib/<abi>/libonnxruntime.so ⟵ onnxruntime-android-<onnx>.aar
#
#   NOT fetched (stays committed — small + NOT reproducible from the obvious upstream; it is a
#   hand-stripped build whose exact provenance was never recorded — see revendor.sh's header):
#     • host/android/vendor/lib/<abi>/libfbjni.so   (~0.17 MB each; left in git on purpose)
#
# So this script is the cheap, toolchain-free (curl + unzip + sha256sum + jq; NO stack) bootstrap
# a fresh clone / CI runner runs ONCE before building the APK or running `revendor.sh verify`.
# `revendor.sh fetch` does the same swap PLUS the header trees and a full stack-based re-verify;
# this script is the lighter "just put the .so back" path with an inline per-file sha256 gate.
#
# USAGE
#   ./scripts/fetch-vendor.sh                # fetch every missing/mismatched fetchable .so, verify
#   ./scripts/fetch-vendor.sh --check        # exit non-zero if any fetchable .so is missing/wrong
#                                            #   (does NOT download — a cheap "are we bootstrapped?")
#   ./scripts/fetch-vendor.sh --force        # re-fetch even if present & matching (ignore the cache)
#   CANOPY_RN_VERSION=0.76.9 CANOPY_ONNX_VERSION=1.26.0 ./scripts/fetch-vendor.sh
#
# IDEMPOTENT: a .so already on disk whose sha256 matches the lock is left untouched (no download).
# FAILS LOUD: any post-extract sha256 that does not match the lock aborts non-zero, naming the file
# (a wrong upstream build can never silently land).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$ROOT/host/vendor.lock.json"
VENDOR="$ROOT/host/android/vendor"

# Upstream pins — kept in lockstep with host/vendor.lock.json + scripts/revendor.sh. The lock is
# the source of truth for the BYTES (sha256); these are just the coordinates to fetch them from.
RN_VERSION="${CANOPY_RN_VERSION:-0.76.9}"
ONNX_VERSION="${CANOPY_ONNX_VERSION:-1.26.0}"
MAVEN="${CANOPY_MAVEN_BASE:-https://repo1.maven.org/maven2}"

MODE="fetch"
case "${1:-}" in
  --check) MODE="check" ;;
  --force) MODE="force" ;;
  "")      MODE="fetch" ;;
  -h|--help)
    sed -n '2,40p' "$0"; exit 0 ;;
  *) printf 'fetch-vendor: unknown arg %s (try --check | --force)\n' "$1" >&2; exit 2 ;;
esac

log()  { printf '%s\n' "$*"; }
die()  { printf 'fetch-vendor: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "required tool '$1' not on PATH"; }

need sha256sum
need jq
[ -f "$LOCK" ] || die "lock not found: ${LOCK#"$ROOT"/}"

# ── The fetchable set: relPath  →  "<aar-url>::<member-path-inside-aar>" ─────────────────────────
# Only the Maven-reproducible binaries are listed (libfbjni.so is intentionally absent). The .so
# inside each AAR lives at jni/<abi>/<name> (the stripped copy — same one revendor.sh swaps in).
HERMES_AAR="$MAVEN/com/facebook/react/hermes-android/$RN_VERSION/hermes-android-$RN_VERSION-release.aar"
REACT_AAR="$MAVEN/com/facebook/react/react-android/$RN_VERSION/react-android-$RN_VERSION-release.aar"
ONNX_AAR="$MAVEN/com/microsoft/onnxruntime/onnxruntime-android/$ONNX_VERSION/onnxruntime-android-$ONNX_VERSION.aar"

# relPath (under host/android/vendor) → AAR url + member. Bash 3-compatible parallel arrays.
REL_PATHS=(
  "lib/arm64-v8a/libhermes.so"
  "lib/x86_64/libhermes.so"
  "lib/arm64-v8a/libjsi.so"
  "lib/x86_64/libjsi.so"
  "onnxruntime/lib/arm64-v8a/libonnxruntime.so"
  "onnxruntime/lib/x86_64/libonnxruntime.so"
)
SOURCES=(
  "$HERMES_AAR::jni/arm64-v8a/libhermes.so"
  "$HERMES_AAR::jni/x86_64/libhermes.so"
  "$REACT_AAR::jni/arm64-v8a/libjsi.so"
  "$REACT_AAR::jni/x86_64/libjsi.so"
  "$ONNX_AAR::jni/arm64-v8a/libonnxruntime.so"
  "$ONNX_AAR::jni/x86_64/libonnxruntime.so"
)

# Expected sha256 for a vendored relPath, read from the committed lock (the byte-level truth).
expected_sha() {
  local rel="$1"
  jq -r --arg p "host/android/vendor/$rel" \
    '.artifacts[] | select(.relPath == $p) | .sha256' "$LOCK"
}

# sha256 of a file on disk, or empty string if absent.
disk_sha() {
  [ -f "$1" ] && sha256sum "$1" | cut -d' ' -f1 || true
}

# ── --check: report-only. Are all fetchable .so present and matching the lock? ───────────────────
if [ "$MODE" = "check" ]; then
  missing=0
  for i in "${!REL_PATHS[@]}"; do
    rel="${REL_PATHS[$i]}"; dest="$VENDOR/$rel"
    want="$(expected_sha "$rel")"
    [ -n "$want" ] || die "lock has no sha256 for host/android/vendor/$rel"
    have="$(disk_sha "$dest")"
    if [ "$have" = "$want" ]; then
      log "  ok      $rel"
    elif [ -z "$have" ]; then
      log "  MISSING $rel"; missing=1
    else
      log "  DRIFT   $rel (have ${have:0:12}… want ${want:0:12}…)"; missing=1
    fi
  done
  if [ "$missing" -ne 0 ]; then
    log "fetch-vendor --check: some fetchable .so are missing/drifted — run scripts/fetch-vendor.sh"
    exit 1
  fi
  log "fetch-vendor --check: all fetchable .so present and match host/vendor.lock.json"
  exit 0
fi

# ── fetch / force: download each needed AAR ONCE, extract + verify each member ───────────────────
need curl
need unzip

# Decide up front which AARs we actually need (skip a multi-hundred-MB download if everything is
# already present & matching, unless --force). Maps an AAR url → 1 when at least one of its members
# must be (re)fetched.
declare -A NEED_AAR=()
declare -A AAR_OF=()      # relPath → aar url
declare -A MEMBER_OF=()   # relPath → member path inside the aar
todo=()
for i in "${!REL_PATHS[@]}"; do
  rel="${REL_PATHS[$i]}"
  url="${SOURCES[$i]%%::*}"
  member="${SOURCES[$i]##*::}"
  AAR_OF["$rel"]="$url"; MEMBER_OF["$rel"]="$member"
  want="$(expected_sha "$rel")"
  [ -n "$want" ] || die "lock has no sha256 for host/android/vendor/$rel"
  have="$(disk_sha "$VENDOR/$rel")"
  if [ "$MODE" != "force" ] && [ "$have" = "$want" ]; then
    log "  cached  $rel"
    continue
  fi
  todo+=("$rel")
  NEED_AAR["$url"]=1
done

if [ "${#todo[@]}" -eq 0 ]; then
  log "fetch-vendor: nothing to do — all fetchable .so already match host/vendor.lock.json"
  exit 0
fi

WORK="$(mktemp -d)"
cleanup() { [ -n "${WORK:-}" ] && rm -rf "$WORK"; return 0; }
trap cleanup EXIT

# Download only the AARs we need.
log "==> fetch-vendor: react-native $RN_VERSION / onnxruntime $ONNX_VERSION"
declare -A AAR_FILE=()
n=0
for url in "${!NEED_AAR[@]}"; do
  n=$((n+1))
  f="$WORK/aar-$n.aar"
  log "    GET     $url"
  curl -fSL --retry 3 --retry-delay 2 -o "$f" "$url" || die "download failed: $url"
  AAR_FILE["$url"]="$f"
done

# Extract + verify each needed member, then atomically swap it into the vendor tree.
for rel in "${todo[@]}"; do
  url="${AAR_OF[$rel]}"; member="${MEMBER_OF[$rel]}"; aar="${AAR_FILE[$url]}"
  want="$(expected_sha "$rel")"
  dest="$VENDOR/$rel"
  tmp="$WORK/extract"; rm -rf "$tmp"; mkdir -p "$tmp"
  unzip -q -o "$aar" "$member" -d "$tmp" || die "member not in AAR: $member ($url)"
  got="$(sha256sum "$tmp/$member" | cut -d' ' -f1)"
  if [ "$got" != "$want" ]; then
    die "sha256 drift for $rel: got $got, lock wants $want (wrong upstream build — refusing to install)"
  fi
  mkdir -p "$(dirname "$dest")"
  cp -f "$tmp/$member" "$dest.new" && mv -f "$dest.new" "$dest"
  log "  fetched $rel  (sha256 ${want:0:12}… ✓)"
done

log
log "OK — fetched ${#todo[@]} vendored .so, all byte-identical to host/vendor.lock.json."
log "   (libfbjni.so is committed, not fetched — see docs/vendored-binaries.md.)"
