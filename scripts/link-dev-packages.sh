#!/usr/bin/env bash
# link-dev-packages.sh — make the monorepo's canopy/* source packages resolvable for
# development using Canopy's OWN mechanism: `canopy link`. It symlinks each package dir
# into the global Canopy cache (~/.canopy/packages/), so the compiler reuses the live
# source directly (no copies, edits picked up instantly). Nothing to do with Elm, and no
# hand-rolled symlinks — the compiler's package-test resolver now picks the highest
# installed version satisfying each constraint, so linking the real versions is enough.
#
# Run once on a fresh machine so `canopy make` / `canopy test` resolve canopy/native, the
# fork's canopy/virtual-dom, canopy/css, and the test framework.
#
# Usage:  ./scripts/link-dev-packages.sh

set -euo pipefail

MONOREPO="${CANOPY_MONOREPO:-$HOME/projects/canopy}"
NATIVE_PKG="$(cd "$(dirname "$0")/../package" && pwd)"

echo "Linking canopy/* dev packages into ~/.canopy/packages via 'canopy link'"

# The native package + everything its app build and its tests pull in
# (test -> html -> virtual-dom; test -> random; css -> html; native -> css/virtual-dom),
# PLUS the capability packages the real apps (Lumen, lumen-probe) depend on as PROPER package
# dependencies — without these linked, an app's `import Image`/`Photos`/… cannot resolve and the
# build fails with "could not find a Native.Module module" (the dependent can't reach the dep).
# Base + runtime:
for src in core json virtual-dom html random test css http bytes browser url time ping share storage; do
  [ -d "$MONOREPO/$src" ] && canopy link "$MONOREPO/$src"
done
# Native capability packages (each declares canopy/native + core/json):
for src in image inference photos album share-image storage-secure notify billing navigation; do
  [ -d "$MONOREPO/$src" ] && canopy link "$MONOREPO/$src"
done
canopy link "$NATIVE_PKG"   # canopy/native (this repo)

# Re-resolve the package environment so the freshly-(re)linked set is indexed and ready — a bare
# `canopy link` only registers the symlink; `canopy setup` rebuilds the resolution so a dependent
# app build resolves the capability packages immediately (otherwise the first build can miss them).
canopy setup >/dev/null 2>&1 || true

echo "Done. Verify with:  ls ~/.canopy/packages/canopy   then   canopy-native build examples/lumen-probe"
