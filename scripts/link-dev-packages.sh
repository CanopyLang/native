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
# (test -> html -> virtual-dom; test -> random; css -> html; native -> css/virtual-dom).
for src in core json virtual-dom html random test css; do
  canopy link "$MONOREPO/$src"
done
canopy link "$NATIVE_PKG"   # canopy/native (this repo)

echo "Done. Verify with:  ls ~/.canopy/packages/canopy   then   (cd ../package && canopy test tests/)"
