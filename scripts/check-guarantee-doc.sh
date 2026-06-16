#!/usr/bin/env bash
# check-guarantee-doc.sh — REL-1: keep docs/guarantee.md honest, device-free.
#
# The reliability guarantee is the spec every "correctness-by-construction" claim is measured
# against. This gate fails the build if the guarantee doc rots in either direction:
#   (A) it cites an enforcement FILE that no longer exists  → a guarantee pointing at a deleted gate;
#   (B) it drops any of the five ASTERISKS (the honest caveats) → a "no errors" overclaim creeps back.
#
# Pure bash + grep. No toolchain, no device.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOC="$ROOT/docs/guarantee.md"
fail=0

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗ %s\033[0m\n' "$*" >&2; fail=1; }

[ -f "$DOC" ] || { echo "FATAL: $DOC missing — the reliability guarantee must be documented (REL-1)." >&2; exit 1; }

# ── (A) every cited file path exists ────────────────────────────────────────────────────────────
# Extract backtick-wrapped tokens that look like in-repo file paths: contain a '/', end in a known
# source/config extension, and carry no glob '*'. (Skips `guardJsCall`, `Cmd`, `_Native_safeDraw`,
# globs like `external/*.js`, and sibling-package mentions that aren't full paths.)
say "==> guarantee.md cited enforcement files exist"
mapfile -t cited < <(grep -oE '`[A-Za-z0-9_./-]+\.(sh|js|can|cpp|h|hpp|java|mm|env|json|gradle|kt|swift)`' "$DOC" \
                       | tr -d '`' | grep '/' | grep -v '[*]' | sort -u)
[ "${#cited[@]}" -gt 0 ] || bad "no cited file paths found in $DOC — the guarantee must cite its enforcement points"
for p in "${cited[@]}"; do
  if [ -e "$ROOT/$p" ]; then ok "$p"; else bad "cited file does NOT exist: $p"; fi
done

# ── (B) all five asterisks (the honest caveats) are present ──────────────────────────────────────
say "==> guarantee.md states all five caveats (the asterisks)"
check_caveat() { if grep -qiE "$2" "$DOC"; then ok "caveat present: $1"; else bad "caveat MISSING from guarantee.md: $1"; fi; }
check_caveat "stack overflow"                "stack overflow"
check_caveat "Hermes out-of-memory"          "out-of-memory|out of memory|\bOOM\b"
check_caveat "ports / FFI boundary"          "ports / FFI|FFI boundary|\bFFI\b"
check_caveat "== on values with functions"   "on values that contain functions|structural equality|== on"
check_caveat "host-side signals (SIGSEGV)"   "SIGSEGV|signal handler|Mach-exception|host-side C\+\+"

# ── (C) the asterisks are stated up front (must precede the positive table) ──────────────────────
# Honesty rule: a reader must hit the caveats before the guarantees, not after.
say "==> the caveats are flagged before the positive guarantees"
ln_caveat=$(grep -nE 'asterisks? first|Read the asterisks' "$DOC" | head -1 | cut -d: -f1)
ln_pos=$(grep -nE '^## 1\. What IS guaranteed' "$DOC" | head -1 | cut -d: -f1)
if [ -n "$ln_caveat" ] && [ -n "$ln_pos" ] && [ "$ln_caveat" -lt "$ln_pos" ]; then
  ok "asterisks flagged (line $ln_caveat) before the positive guarantees (line $ln_pos)"
else
  bad "guarantee.md must flag the asterisks BEFORE the positive guarantee table"
fi

echo
if [ "$fail" -eq 0 ]; then echo "guarantee.md OK — every cited gate is live and every caveat is stated."; else echo "guarantee.md check FAILED." >&2; fi
exit "$fail"
