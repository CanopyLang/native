#!/usr/bin/env bash
# check-llms-corpus.sh — AAG-1: keep the AI-assistant corpus COMPILE-VERIFIED.
#
# docs/llms-native.txt is reference material an LLM (Claude/Cursor/Copilot) is fed so it writes
# COMPILING Canopy for a zero-training-data language. That only works if the idioms it teaches
# actually typecheck — so corpus/src/Main.can (the canonical idiom set the doc points to) is compiled
# on every CI run. A drift that makes the corpus stop compiling fails the build, so the corpus the doc
# advertises can never rot into plausible-but-wrong code.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✗ %s\033[0m\n' "$*" >&2; fail=1; }

[ -f "$ROOT/docs/llms-native.txt" ] && ok "docs/llms-native.txt present" || bad "docs/llms-native.txt missing (AAG-1)"
grep -q 'corpus/src/Main.can' "$ROOT/docs/llms-native.txt" 2>/dev/null && ok "llms-native.txt points at the compile-verified corpus" || bad "llms-native.txt must reference corpus/src/Main.can"
[ -f "$ROOT/corpus/src/Main.can" ] && ok "corpus/src/Main.can present" || bad "corpus/src/Main.can missing"

if ! command -v canopy-native >/dev/null 2>&1; then
  echo "  · SKIP corpus compile: canopy-native not on PATH (toolchain absent)"; exit "$fail"
fi

echo "==> compile the idiom corpus (every documented idiom must typecheck)"
out="$(cd "$ROOT" && canopy-native build corpus 2>&1)"; rc=$?
if [ $rc -eq 0 ]; then ok "corpus compiles: $(echo "$out" | tail -1)"; else bad "corpus FAILED to compile — a documented idiom no longer typechecks:"; echo "$out" | tail -20 >&2; fi

echo
if [ "$fail" -eq 0 ]; then echo "llms corpus OK — the AI-assistant idioms compile."; else echo "llms corpus check FAILED." >&2; fi
exit "$fail"
