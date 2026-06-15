#!/usr/bin/env bash
# assert-bundle-manifest.sh — CI-3: prove a bundle's sha256 equals the content-addressed manifest's
# buildId (and the manifest's recorded bundle.sha256). This is the SAME integrity invariant the host
# enforces at boot, lifted into CI so a wrong/stale/corrupt bundle fails the build LOUDLY instead of
# silently shipping a mismatched app.
#
# It is used in two spots by the platform builds (android-release / ios-build):
#   1. on the bundle staged into the app source tree BEFORE the native build (the artifact CI-3's
#      `bundle` job produced and the platform job downloaded), and
#   2. (Android) on the bundle UNZIPPED OUT OF the built APK — proving the bundle that R8/AAPT
#      actually packaged is byte-for-byte the one the manifest pins (no resource-processing mangling).
#
# Usage:
#   scripts/assert-bundle-manifest.sh <bundle.js> <manifest.json>
#
# Exit: 0 if the sha256 matches buildId + bundle.sha256; non-zero (with a clear message) otherwise.
# Dependencies: sha256sum + grep/sed only — no jq, so it runs on a bare GitHub runner / macOS (where
# we fall back to `shasum -a 256`).

set -euo pipefail

BUNDLE="${1:-}"
MANIFEST="${2:-}"
if [ -z "$BUNDLE" ] || [ -z "$MANIFEST" ]; then
  echo "usage: assert-bundle-manifest.sh <bundle.js> <manifest.json>" >&2
  exit 2
fi
[ -f "$BUNDLE" ]   || { echo "bundle not found: $BUNDLE" >&2; exit 1; }
[ -f "$MANIFEST" ] || { echo "manifest not found: $MANIFEST" >&2; exit 1; }

# sha256 of the bundle — prefer sha256sum (Linux), fall back to shasum -a 256 (macOS / iOS runner).
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo "neither sha256sum nor shasum is available" >&2; exit 1
  fi
}

ACTUAL="$(sha256_of "$BUNDLE")"
# Pull buildId + bundle.sha256 from the manifest with grep/sed (failure-tolerant: || true so a
# missing field yields "" and the explicit emptiness check below produces the clear error).
BUILD_ID="$(grep -o '"buildId":"[0-9a-f]\{64\}"' "$MANIFEST" | head -1 | sed 's/.*:"//; s/"//' || true)"
BUNDLE_SHA="$(grep -o '"bundle":{[^}]*}' "$MANIFEST" | grep -o '"sha256":"[0-9a-f]\{64\}"' | head -1 | sed 's/.*:"//; s/"//' || true)"

[ -n "$BUILD_ID" ]   || { echo "manifest $MANIFEST has no buildId" >&2; exit 1; }
[ -n "$BUNDLE_SHA" ] || { echo "manifest $MANIFEST has no bundle.sha256" >&2; exit 1; }

if [ "$ACTUAL" != "$BUILD_ID" ]; then
  echo "BUNDLE/MANIFEST MISMATCH: $BUNDLE sha256=$ACTUAL != manifest buildId=$BUILD_ID" >&2
  exit 1
fi
if [ "$ACTUAL" != "$BUNDLE_SHA" ]; then
  echo "BUNDLE/MANIFEST MISMATCH: $BUNDLE sha256=$ACTUAL != manifest bundle.sha256=$BUNDLE_SHA" >&2
  exit 1
fi

echo "OK: $(basename "$BUNDLE") sha256 == manifest buildId ($ACTUAL)"
