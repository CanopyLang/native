#!/usr/bin/env bash
# rebuild-artifacts.sh — recompile EVERY monorepo canopy/* package's artifacts.dat
# under the CURRENT compiler, force-fresh.
#
# WHY THIS EXISTS
# ---------------
# Each canopy package ships a compiled-interface cache, `artifacts.dat` (gated by a
# "CART" header + a compiler-version field). When a package's source OR the compiler
# changes but the cache does NOT, the compiler happily reads the *stale* interface and
# you get cryptic failures with no obvious cause:
#
#     Missing global Native.init
#     UNKNOWN IMPORT [E0321] could not find module ...
#     could not find a Css module
#
# The fix is to throw the stale caches away and recompile every package from source
# under the compiler that is on your PATH right now. This script does exactly that.
#
# THE MECHANISM (investigated, not guessed)
# -----------------------------------------
# The canonical regenerator is **`canopy setup`**. Given the dev-linked packages in
# ~/.canopy/packages (created by scripts/link-dev-packages.sh, which `canopy link`s the
# monorepo sources), `canopy setup`:
#   * checks each linked local package's artifacts.dat against the current compiler,
#   * recompiles from source EVERY package whose cache is missing or version-drifted,
#   * resolves the dependency order itself (core -> json -> virtual-dom -> html/random
#     -> css/test -> native), so we don't have to.
#
# Things that DON'T regenerate artifacts.dat (so this script does not rely on them):
#   * `canopy make` in a package dir — only emits ESM to output/, never writes the cache.
#   * `canopy test` in a package dir — writes the cache for the package's *dependencies*
#     but NOT for the package itself, and fails outright on packages whose suites need a
#     browser (e.g. canopy/core, canopy/test) even though the cache is fine.
#   * `canopy-native build <app>` — caches interfaces inside the app's own canopy-stuff/,
#     not back into each package source's artifacts.dat.
# Only `canopy setup` reliably (re)writes the package source `artifacts.dat` for ALL
# packages, including leaf consumers like canopy/test (no tests) and canopy/native
# (no dependent with tests).
#
# We FORCE-FRESH by deleting each package's artifacts.dat (and its canopy-stuff/ build
# cache) BEFORE running `canopy setup`, so the header is rewritten under the current
# compiler instead of being left "ready" from a previous version.
#
# Usage:  ./scripts/rebuild-artifacts.sh
#         CANOPY_MONOREPO=/path/to/canopy ./scripts/rebuild-artifacts.sh

set -euo pipefail

MONOREPO="${CANOPY_MONOREPO:-$HOME/projects/canopy}"
NATIVE_PKG="$(cd "$(dirname "$0")/../package" && pwd)"

# Packages whose artifacts.dat we own, in dependency order. The trailing entry is the
# native package in THIS repo; the rest are sibling dirs in the monorepo. `canopy setup`
# does the real ordering — this list only drives the force-fresh wipe + the OK/FAIL report.
MONOREPO_PKGS=(core json virtual-dom html random test css)

# Resolve every package to an absolute source dir.
declare -a PKG_NAMES=()
declare -a PKG_DIRS=()
for p in "${MONOREPO_PKGS[@]}"; do
  PKG_NAMES+=("canopy/$p")
  PKG_DIRS+=("$MONOREPO/$p")
done
PKG_NAMES+=("canopy/native")
PKG_DIRS+=("$NATIVE_PKG")

echo "==> rebuild-artifacts: recompiling all canopy/* artifacts.dat under compiler $(canopy --version 2>/dev/null || echo '?')"
echo "    monorepo: $MONOREPO"
echo

# 1. Sanity: every package source dir must exist.
missing_dirs=0
for i in "${!PKG_DIRS[@]}"; do
  if [[ ! -d "${PKG_DIRS[$i]}" ]]; then
    echo "    !! ${PKG_NAMES[$i]}: source dir not found at ${PKG_DIRS[$i]}" >&2
    missing_dirs=1
  fi
done
if [[ "$missing_dirs" -ne 0 ]]; then
  echo >&2
  echo "Set CANOPY_MONOREPO to the canopy/ checkout and retry." >&2
  exit 1
fi

# 2. Force-fresh: wipe each package's stale cache so the header is rewritten, not reused.
echo "==> [1/2] removing stale artifacts.dat + canopy-stuff/ for ${#PKG_DIRS[@]} packages"
for i in "${!PKG_DIRS[@]}"; do
  dir="${PKG_DIRS[$i]}"
  rm -f  "$dir/artifacts.dat"
  rm -rf "$dir/canopy-stuff"
  echo "    cleared ${PKG_NAMES[$i]}"
done
echo

# 3. Recompile everything from source under the current compiler.
#    `canopy setup` recompiles every package with a missing/stale cache, in dep order.
echo "==> [2/2] canopy setup (recompiling missing caches from source)"
setup_log="$(mktemp)"
trap 'rm -f "$setup_log"' EXIT
if ! canopy setup >"$setup_log" 2>&1; then
  cat "$setup_log"
  echo >&2
  echo "FAIL: 'canopy setup' exited non-zero. See output above." >&2
  echo "      If a package version changed, re-run scripts/link-dev-packages.sh first." >&2
  exit 1
fi
# Surface only the lines for the packages we care about (keeps the noise down).
grep -E 'canopy/(core|json|virtual-dom|html|random|test|css|native)\b' "$setup_log" || cat "$setup_log"
echo

# 4. Per-package OK/FAIL summary: a freshly written CART-headed cache == OK.
echo "==> result"
fail=0
for i in "${!PKG_DIRS[@]}"; do
  name="${PKG_NAMES[$i]}"
  art="${PKG_DIRS[$i]}/artifacts.dat"
  if [[ -f "$art" ]] && [[ "$(head -c 4 "$art" 2>/dev/null)" == "CART" ]]; then
    size="$(stat -c%s "$art" 2>/dev/null || stat -f%z "$art")"
    printf '    OK    %-22s %8s bytes  (CART)\n' "$name" "$size"
  else
    printf '    FAIL  %-22s  no valid artifacts.dat\n' "$name"
    fail=1
  fi
done
echo

if [[ "$fail" -ne 0 ]]; then
  echo "FAIL: one or more packages did not produce a CART artifacts.dat." >&2
  echo "      Run scripts/link-dev-packages.sh (a package may not be linked) and retry." >&2
  exit 1
fi

echo "All canopy/* artifacts.dat recompiled under $(canopy --version 2>/dev/null). Builds should be clean now."
echo "Verify with:  canopy-native build examples/counter"
