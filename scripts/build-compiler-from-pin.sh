#!/usr/bin/env bash
# build-compiler-from-pin.sh — CI-2: REPRODUCIBLY build the in-house Canopy compiler from the
# pinned sibling SHA, put `canopy` on PATH, link the dev packages, and PROVE the IIFE bundle the
# native host ships does NOT throw `F7 is not defined` (the tree-shaker regression CMP-1 fixed).
#
# This is the one job in CI that needs the compiler toolchain (the gate/android/ios jobs consume a
# prebuilt bundle). It is the executable form of docs/compiler-pinning.md: a single auditable SHA
# (scripts/compiler-pin.env), fetched reproducibly, built with stack, verified end-to-end.
#
# Reproducibility contract:
#   * the compiler is taken at EXACTLY CANOPY_COMPILER_SHA — a clean clone in CI, or a verified
#     sibling working tree locally; HEAD is asserted to equal the pin (fail-closed on drift).
#   * stack pins the snapshot + every extra-dep in stack.yaml(.lock), so two runs of this script on
#     the same SHA produce the same `canopy` binary behaviour.
#   * the acceptance gate is the ACTUAL emitted output (eval the IIFE bundle), not a proxy.
#
# Usage:
#   scripts/build-compiler-from-pin.sh                 # full: obtain + build + install + link + verify
#   scripts/build-compiler-from-pin.sh --verify-only   # skip build (canopy already on PATH); just the F7 gate
#   scripts/build-compiler-from-pin.sh --no-verify     # build + install + link only (no F7 gate)
#
# Env overrides (all optional):
#   CANOPY_COMPILER_DIR   where to obtain/build the compiler  (default: ../compiler, else $RUNNER_TEMP/canopy-compiler)
#   CANOPY_COMPILER_SHA / CANOPY_COMPILER_REMOTE           override the pin (normally from compiler-pin.env)
#   CANOPY_PIN_CANONICAL_APP                              app whose IIFE bundle is verified
#   STACK_INSTALL_BIN     dir stack installs `canopy` into (default: stack's --local-bin-path)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_ROOT="$(cd "$HERE/.." && pwd)"

# ---- load the pin (single source of truth) --------------------------------------------------
# shellcheck source=/dev/null
. "$HERE/compiler-pin.env"
: "${CANOPY_COMPILER_SHA:?compiler-pin.env must set CANOPY_COMPILER_SHA}"
: "${CANOPY_COMPILER_REMOTE:?compiler-pin.env must set CANOPY_COMPILER_REMOTE}"
CANONICAL_APP="${CANOPY_PIN_CANONICAL_APP:-examples/counter}"

MODE="full"
case "${1:-}" in
  --verify-only) MODE="verify-only" ;;
  --no-verify)   MODE="no-verify" ;;
  "")            MODE="full" ;;
  *) echo "unknown arg: $1 (use --verify-only | --no-verify)" >&2; exit 2 ;;
esac

log()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
die()  { printf '  \033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ---- 1. obtain the compiler at EXACTLY the pinned SHA (reproducible) -------------------------
obtain_compiler() {
  # Prefer a sibling working tree (dev box) IF it already contains the pinned commit; otherwise
  # clone the remote into a scratch dir (clean CI runner). Either way HEAD ends at the pin.
  if [ -n "${CANOPY_COMPILER_DIR:-}" ]; then
    COMPILER_DIR="$CANOPY_COMPILER_DIR"
  elif [ -d "$NATIVE_ROOT/../compiler/.git" ]; then
    COMPILER_DIR="$(cd "$NATIVE_ROOT/../compiler" && pwd)"
  else
    COMPILER_DIR="${RUNNER_TEMP:-/tmp}/canopy-compiler"
  fi

  if [ -d "$COMPILER_DIR/.git" ]; then
    log "Using compiler checkout at $COMPILER_DIR"
    if ! git -C "$COMPILER_DIR" cat-file -e "${CANOPY_COMPILER_SHA}^{commit}" 2>/dev/null; then
      log "Pinned SHA not present locally — fetching it from $CANOPY_COMPILER_REMOTE"
      git -C "$COMPILER_DIR" remote get-url pin >/dev/null 2>&1 || \
        git -C "$COMPILER_DIR" remote add pin "$CANOPY_COMPILER_REMOTE"
      git -C "$COMPILER_DIR" fetch --depth=1 pin "$CANOPY_COMPILER_SHA" 2>/dev/null \
        || git -C "$COMPILER_DIR" fetch pin "$CANOPY_COMPILER_SHA"
    fi
  else
    log "Cloning $CANOPY_COMPILER_REMOTE @ $CANOPY_COMPILER_SHA -> $COMPILER_DIR"
    mkdir -p "$COMPILER_DIR"
    git -C "$COMPILER_DIR" init -q
    git -C "$COMPILER_DIR" remote add origin "$CANOPY_COMPILER_REMOTE"
    git -C "$COMPILER_DIR" fetch --depth=1 origin "$CANOPY_COMPILER_SHA" \
      || git -C "$COMPILER_DIR" fetch origin "$CANOPY_COMPILER_SHA"
    git -C "$COMPILER_DIR" -c advice.detachedHead=false checkout -q FETCH_HEAD
  fi

  # REPRODUCIBILITY: we build from the EXACT pinned commit, never from a working tree that may carry
  # local edits (a dev box mid-Wave-2 has the pin at HEAD but dirty .hs files; a fresh clone has it
  # clean). We DO NOT mutate the user's checkout. The only case where building in place is safe is a
  # checkout that is BOTH at the pin AND clean (the fresh-clone path) — otherwise we `git archive`
  # the pinned commit to a scratch dir and build the committed blobs, untouched by local edits.
  git -C "$COMPILER_DIR" cat-file -e "${CANOPY_COMPILER_SHA}^{commit}" 2>/dev/null \
    || die "pinned SHA $CANOPY_COMPILER_SHA is not in $COMPILER_DIR — fetch it first"
  local head dirty
  head="$(git -C "$COMPILER_DIR" rev-parse HEAD)"
  dirty="$(git -C "$COMPILER_DIR" status --porcelain)"
  if [ "$head" = "$CANOPY_COMPILER_SHA" ] && [ -z "$dirty" ]; then
    ok "compiler checkout is at the pinned SHA and clean — building in place"
    BUILD_DIR="$COMPILER_DIR"
  else
    if [ "$head" != "$CANOPY_COMPILER_SHA" ]; then
      log "checkout HEAD ($head) != pin — exporting pinned commit via git archive (no mutation of $COMPILER_DIR)"
    else
      log "checkout is at the pin but has local edits — exporting CLEAN pinned commit via git archive (ignoring working-tree dirt)"
    fi
    BUILD_DIR="${RUNNER_TEMP:-/tmp}/canopy-compiler-pinned"
    rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"
    git -C "$COMPILER_DIR" archive "$CANOPY_COMPILER_SHA" | tar -x -C "$BUILD_DIR"
    ok "exported pinned tree to $BUILD_DIR ($(find "$BUILD_DIR" -type f | wc -l) files)"
  fi
}

# ---- 2. stack build + install `canopy` onto PATH --------------------------------------------
build_and_install() {
  command -v stack >/dev/null 2>&1 || die "stack not on PATH (install GHCup/stack first)"
  local bindir="${STACK_INSTALL_BIN:-$HOME/.local/bin}"
  mkdir -p "$bindir"
  log "stack build (snapshot + extra-deps are pinned in stack.yaml.lock — reproducible)"
  ( cd "$BUILD_DIR" && stack build canopy:exe:canopy )
  log "stack install canopy -> $bindir"
  ( cd "$BUILD_DIR" && stack install canopy:exe:canopy --local-bin-path "$bindir" )
  export PATH="$bindir:$PATH"
  command -v canopy >/dev/null 2>&1 || die "canopy not on PATH after install"
  ok "canopy installed: $(command -v canopy) ($(canopy --version 2>/dev/null || echo '?'))"
}

# ---- 3. link the monorepo's canopy/* dev packages (compiler's own resolver) -----------------
# The canonical app resolves canopy/core, canopy/json, canopy/virtual-dom, ... from the sibling
# monorepo package repos. On a dev box (and once CI-3 provides them in CI) they are present and we
# link them; on a bare native-only checkout they are absent — we say so and let verify_no_f7 decide.
# Returns 0 if the packages are linked, 1 if the monorepo is not present (best-effort, never fatal here).
MONOREPO="${CANOPY_MONOREPO:-$(cd "$NATIVE_ROOT/.." && pwd)}"
link_packages() {
  if [ ! -d "$MONOREPO/core" ] || [ ! -d "$MONOREPO/virtual-dom" ]; then
    printf '  \033[33m· monorepo packages not found under %s — skipping link (the F7 gate needs them; see CI-3)\033[0m\n' "$MONOREPO"
    return 1
  fi
  log "Linking canopy/* dev packages (scripts/link-dev-packages.sh)"
  CANOPY_MONOREPO="$MONOREPO" bash "$HERE/link-dev-packages.sh"
  return 0
}

# ---- 4. ACCEPTANCE GATE: the emitted IIFE bundle must NOT throw `F7 is not defined` ----------
# Builds the canonical app's full host bundle (preamble + compiled IIFE + boot hook) and EVALUATES
# it in node under the mock Fabric. A dropped F7/arity-helper or program-export surfaces as a
# ReferenceError at eval/boot — exactly the CMP-1 regression. We assert clean eval + boot.
verify_no_f7() {
  # The gate builds the canonical app from source, which needs the monorepo packages linked.
  # If they are absent (bare native-only checkout) we SKIP rather than fail — getting the package
  # sources onto a CI runner is CI-3's job. A skip is loud and non-green-washing.
  if [ "${PACKAGES_LINKED:-0}" != "1" ]; then
    if [ "${CANOPY_PIN_REQUIRE_GATE:-0}" = "1" ]; then
      die "F7 gate required (CANOPY_PIN_REQUIRE_GATE=1) but monorepo packages are not linked"
    fi
    printf '  \033[33m· SKIP F7 gate: monorepo packages not linked (need canopy/core,json,virtual-dom,...).\033[0m\n'
    printf '  \033[33m  The compiler was still built reproducibly from the pin. Provide the package sources\n'
    printf '    (CI-3) or run on a dev box with the monorepo, then re-run to exercise the gate.\033[0m\n'
    return 0
  fi
  command -v canopy-native >/dev/null 2>&1 || die "canopy-native not on PATH"
  command -v node >/dev/null 2>&1 || die "node not on PATH"
  log "Building canonical app bundle: canopy-native build $CANONICAL_APP"
  ( cd "$NATIVE_ROOT" && canopy-native build "$CANONICAL_APP" )
  local bundle="$NATIVE_ROOT/$CANONICAL_APP/build/canopy.bundle.js"
  [ -f "$bundle" ] || die "bundle not produced at $bundle"
  ok "bundle built ($(wc -c <"$bundle") bytes)"

  log "F7 gate — evaluate + boot the real bundle under the mock Fabric"
  CANOPY_BUNDLE="$bundle" node "$HERE/verify-iife-no-f7.js" \
    || die "IIFE bundle threw a ReferenceError (F7/arity/export dropped — compiler pin is missing the CMP-1 tree-shaker fix)"
  ok "IIFE bundle evaluated + booted with NO ReferenceError (no 'F7 is not defined')"

  # Second proof: the full compiled-output renderer harness (drives the SAME bundle through real
  # gestures/scheduler against the mock host). Present in the repo today; run it if it's there.
  if [ -f "$NATIVE_ROOT/harness/run-compiled.js" ]; then
    log "F7 gate (deep) — harness/run-compiled.js end-to-end render+tap on the real bundle"
    ( cd "$NATIVE_ROOT" && node harness/run-compiled.js >/dev/null ) \
      && ok "compiled-output harness PASS (render + targeted update on the real IIFE)" \
      || die "harness/run-compiled.js failed on the pinned compiler's output"
  fi
}

# ---- drive ----------------------------------------------------------------------------------
# CI-4: when CI restored a SHA-keyed cache of the `canopy` binary, skip the (mtime-invalidated,
# multi-minute) clone + GHC rebuild — but ONLY if the cached binary actually RUNS (health check),
# so a stale/incompatible cache falls through to a full reproducible build. The reuse is gated on
# CANOPY_REUSE_CACHED_CANOPY=1, which CI sets only on a cache HIT; it is never set on a dev box, so
# local behaviour is unchanged (a dev's on-PATH canopy is never silently reused for the pin build).
can_reuse_cached_canopy() {
  [ "${CANOPY_REUSE_CACHED_CANOPY:-0}" = "1" ] || return 1
  command -v canopy >/dev/null 2>&1 || return 1
  canopy --version >/dev/null 2>&1 || return 1   # health check: the cached binary must actually run
  return 0
}
build_or_reuse() {
  if can_reuse_cached_canopy; then
    ok "reusing SHA-keyed cached canopy: $(command -v canopy) — skipping clone + stack build (CI-4)"
  else
    obtain_compiler
    build_and_install
  fi
}

PACKAGES_LINKED=0
case "$MODE" in
  full)
    build_or_reuse
    if link_packages; then PACKAGES_LINKED=1; fi
    verify_no_f7
    ;;
  no-verify)
    build_or_reuse
    link_packages || true
    ;;
  verify-only)
    command -v canopy >/dev/null 2>&1 || die "--verify-only needs canopy already on PATH"
    ok "reusing canopy on PATH: $(command -v canopy) ($(canopy --version 2>/dev/null || echo '?'))"
    if link_packages; then PACKAGES_LINKED=1; fi
    verify_no_f7
    ;;
esac

log "build-compiler-from-pin: DONE ($MODE) — pin $CANOPY_COMPILER_SHA"
