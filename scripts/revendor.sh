#!/usr/bin/env bash
# revendor.sh — vendor provenance gate for canopy/native (RNV-1).
#
# The host ships third-party prebuilts (Hermes/JSI/fbjni + onnxruntime), their header trees,
# and iOS pod pins. host/vendor.lock.json records source/version/date + a sha256 per file.
# This wrapper drives the `canopy-native` tool's vendor-lock / vendor-verify subcommands.
#
#   ./scripts/revendor.sh verify   # recompute every checksum and diff the committed lock;
#                                   # exits NON-ZERO (fails loud, names the file) on any drift.
#   ./scripts/revendor.sh lock     # regenerate host/vendor.lock.json from the files on disk.
#
# CI runs `revendor.sh verify` as a cheap early gate (no emulator/Mac needed).
#
# RNV-3 SEAM: RNV-3 will extend this same script with a `fetch`/`download` subcommand that
# pulls + unzips the upstream AARs/prebuilts into host/android/vendor before re-locking. Add
# the new case to the dispatch below; keep verify/lock untouched.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STACK_YAML="$ROOT/tool/stack.yaml"

run_tool() {
  # `stack run` is incremental; the tool is tiny and warm in CI's stack cache.
  stack --stack-yaml "$STACK_YAML" run canopy-native -- "$@"
}

cmd="${1:-verify}"
case "$cmd" in
  verify)
    echo "==> revendor: verifying host/vendor.lock.json against the files on disk"
    run_tool vendor-verify --root "$ROOT"
    ;;
  lock)
    echo "==> revendor: regenerating host/vendor.lock.json from the files on disk"
    run_tool vendor-lock --root "$ROOT"
    ;;
  *)
    echo "usage: $(basename "$0") {verify|lock}" >&2
    echo "  verify  recompute checksums + diff the committed lock (non-zero on drift)" >&2
    echo "  lock    regenerate host/vendor.lock.json" >&2
    exit 2
    ;;
esac
