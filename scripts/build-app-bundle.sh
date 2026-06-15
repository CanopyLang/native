#!/usr/bin/env bash
# build-app-bundle.sh — CI-3: build the canopy app JS bundle FROM SOURCE and stage the shippable
# deliverables (bundle + map + .hbc + content-addressed manifest + Fabric codegen) into a single
# `dist/` directory the build jobs (android-release / ios-build) download and consume.
#
# WHY this exists (the production-readiness gap CI-3 closes):
#   host/android/app/src/main/assets/canopy.bundle.js is GIT-IGNORED (a stale checked-in copy must
#   never shadow a fresh build — see that dir's .gitignore). So on a clean CI checkout the bundle
#   simply does not exist, and BOTH the android-release `cp`/`unzip … grep assets/canopy.bundle.js`
#   and the ios-build `cp …/canopy.bundle.js …` fail. The fix is to BUILD the bundle from source in
#   a dedicated CI job and hand it to the platform builds as an artifact — never a committed blob.
#
# Reproducibility contract (inherited from CI-2):
#   * the compiler is built at EXACTLY scripts/compiler-pin.env's CANOPY_COMPILER_SHA (clean clone in
#     CI), `canopy` + `canopy-native` are installed onto PATH, the monorepo canopy/* dev packages are
#     linked, and the SAME pinned compiler emits the bundle. Two runs on the same pin + same package
#     SHAs produce a byte-identical bundle, hence a stable buildId (the bundle's sha256).
#   * `canopy-native build` writes the content-addressed canopy.manifest.json: the bundle's sha256 IS
#     the buildId, and the host verifies the booted bundle against it. The platform builds re-assert
#     the packaged bundle's sha256 equals the manifest, so a wrong/stale bundle fails loud.
#
# What it emits (under $DIST, default scripts/../dist/app-bundle):
#   canopy.bundle.js        — the assembled host bundle (preamble + compiled IIFE + boot hook)
#   canopy.bundle.js.map    — preamble-aligned source map (dev compile; for offline symbolication)
#   canopy.bundle.hbc       — Hermes bytecode (ONLY if a hermesc is locatable; additive, see RNV-7)
#   canopy.manifest.json    — content-addressed manifest (buildId = bundle sha256 + asset shas)
#   generated/              — the Fabric mapping codegen (component-manifest.json/.h/.ts)
#   canopy.<buildId>.map    — buildId-keyed archived release map (release builds only, AND-10)
#
# Usage:
#   scripts/build-app-bundle.sh                      # full: build compiler-from-pin + app bundle + stage
#   scripts/build-app-bundle.sh --bundle-only        # SKIP the compiler build (canopy + canopy-native
#                                                    #   already on PATH + packages linked); just build
#                                                    #   the app bundle and stage it (fast local re-run)
#
# Env overrides (all optional):
#   CANOPY_PIN_CANONICAL_APP   app to build           (default: compiler-pin.env's value, e.g. examples/counter)
#   CANOPY_BUNDLE_DIST         where to stage dist     (default: $NATIVE_ROOT/dist/app-bundle)
#   CANOPY_BUNDLE_RELEASE=1    use the --optimize (release) compile instead of the default dev build.
#                              Opt-in because the optimize path is broken at some compiler pins (it
#                              tree-shakes a referenced helper → ReferenceError); the F7 acceptance
#                              gate below fails the job if so, never publishing a broken bundle.
#   CANOPY_COMPILER_DIR        compiler clone/build dir (passed through to build-compiler-from-pin.sh)
#   CANOPY_MONOREPO            monorepo root holding canopy/* package sources (for linking)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_ROOT="$(cd "$HERE/.." && pwd)"

# shellcheck source=/dev/null
. "$HERE/compiler-pin.env"
CANONICAL_APP="${CANOPY_PIN_CANONICAL_APP:-examples/counter}"
DIST="${CANOPY_BUNDLE_DIST:-$NATIVE_ROOT/dist/app-bundle}"

MODE="full"
case "${1:-}" in
  --bundle-only) MODE="bundle-only" ;;
  "")            MODE="full" ;;
  *) echo "unknown arg: $1 (use --bundle-only)" >&2; exit 2 ;;
esac

log()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
die()  { printf '  \033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ---- 1. compiler-from-pin: build + install canopy/canopy-native, link dev packages ----------
# Reuse the CI-2 driver in --no-verify mode: it obtains the compiler at the pin, stack-builds +
# installs `canopy`, and links the monorepo canopy/* dev packages — everything the app build needs,
# WITHOUT re-running the F7 gate (the rebuild-bundle job already gates that; here we just need a
# working compiler to emit the bundle). `canopy-native` itself is installed by the CI step (or is
# already on PATH on a dev box); we assert it below rather than reinstall it here.
build_toolchain() {
  command -v canopy-native >/dev/null 2>&1 \
    || die "canopy-native not on PATH — install it first (stack install canopy-native --local-bin-path \"\$HOME/.local/bin\")"
  log "Building pinned compiler + linking dev packages (build-compiler-from-pin.sh --no-verify)"
  bash "$HERE/build-compiler-from-pin.sh" --no-verify
  export PATH="$HOME/.local/bin:$PATH"
  command -v canopy >/dev/null 2>&1 || die "canopy not on PATH after build-compiler-from-pin.sh"
  ok "toolchain ready: $(command -v canopy), $(command -v canopy-native)"
}

# ---- 2. build the app bundle, F7-gate it, then stage the deliverables ------------------------
# `canopy-native build` emits the source map (canopy.bundle.js.map) for offline symbolication; under
# --release it ALSO archives a buildId-keyed map (AND-10). The .hbc is emitted only when a hermesc is
# locatable (RNV-7) — additive, never required (a runner without the RN toolchain still produces a
# valid JS bundle the host boots).
#
# DEV vs RELEASE: this defaults to the DEV bundle — the SAME artifact the F7 acceptance gate, the
# renderer harness, and the host boot path validate, and the one the host ships today. The
# --optimize (release) path is OPT-IN via CANOPY_BUNDLE_RELEASE=1, because at some compiler pins the
# optimize pass tree-shakes a referenced runtime helper out and the bundle throws a ReferenceError
# (e.g. `al is not defined`) — the SAME class of bug as CMP-1's `F7 is not defined`, just on the
# optimize path. Either way we run the F7 acceptance gate (verify-iife-no-f7.js) on the produced
# bundle BEFORE staging it, so a broken bundle (dev OR release) fails THIS job and is never published.
build_bundle() {
  command -v canopy-native >/dev/null 2>&1 || die "canopy-native not on PATH"
  command -v node >/dev/null 2>&1          || die "node not on PATH (needed for the F7 acceptance gate)"
  local appDir="$NATIVE_ROOT/$CANONICAL_APP"
  [ -d "$appDir" ] || die "canonical app dir not found: $appDir"

  local relArgs=() relLabel="dev"
  if [ "${CANOPY_BUNDLE_RELEASE:-0}" = "1" ]; then
    relArgs=("--release"); relLabel="release (--optimize)"
  fi
  log "Building app bundle FROM SOURCE [$relLabel]: canopy-native build ${relArgs[*]} $CANONICAL_APP"
  ( cd "$NATIVE_ROOT" && canopy-native build "${relArgs[@]}" "$CANONICAL_APP" )

  local out="$appDir/${CANOPY_BUNDLE_OUTPUT_SUBDIR:-build}"
  local bundle="$out/canopy.bundle.js"
  local manifest="$out/canopy.manifest.json"
  [ -f "$bundle" ]   || die "bundle not produced at $bundle"
  [ -f "$manifest" ] || die "manifest not produced at $manifest"
  ok "bundle built ($(wc -c <"$bundle") bytes); manifest at $manifest"

  # F7 ACCEPTANCE GATE — eval + boot the produced bundle under the mock Fabric. A tree-shaken runtime
  # helper (F7/_Platform_export/`al`/...) surfaces as a ReferenceError here. Fail closed: never stage
  # or publish a bundle that does not boot. This is the SAME gate rebuild-bundle runs (CI-2), applied
  # to the EXACT bundle this job ships.
  log "F7 acceptance gate — eval + boot the produced bundle (verify-iife-no-f7.js)"
  CANOPY_BUNDLE="$bundle" node "$HERE/verify-iife-no-f7.js" \
    || die "produced bundle threw a ReferenceError on eval/boot — NOT published (tree-shaker regression; see docs/compiler-fixes.md)"
  ok "produced bundle evaluated + booted with no ReferenceError"

  log "Staging deliverables -> $DIST"
  rm -rf "$DIST"; mkdir -p "$DIST"
  # Required deliverables (fail closed if the bundle or manifest is missing).
  cp "$bundle"   "$DIST/canopy.bundle.js"
  cp "$manifest" "$DIST/canopy.manifest.json"
  # Optional-but-expected: the source map (dev symbolication) — present unless the compiler emitted
  # none; warn rather than fail so a map-less build still ships the bundle.
  if [ -f "$out/canopy.bundle.js.map" ]; then
    cp "$out/canopy.bundle.js.map" "$DIST/canopy.bundle.js.map"
  else
    printf '  \033[33m· no canopy.bundle.js.map (compiler emitted none) — bundle ships without it\033[0m\n'
  fi
  # Optional: the Hermes .hbc (RNV-7) — stage it ONLY when THIS build emitted it, i.e. the manifest
  # carries a "bytecode" block. We do NOT stage a bare canopy.bundle.hbc sitting in the output dir:
  # it can be a STALE artifact from a prior build (no hermesc on this run ⇒ no fresh .hbc, no bytecode
  # block), and shipping bytecode that does not match the bundle is exactly the footgun the manifest
  # exists to prevent. When the manifest declares it, we also assert its sha256 before staging.
  # NB: these JSON reads are deliberately failure-tolerant (|| true): grep exits 1 when the optional
  # "bytecode" block is absent, and under `set -euo pipefail` that would otherwise abort the script.
  local hbcSha
  hbcSha="$(grep -o '"bytecode":{[^}]*}' "$manifest" 2>/dev/null | grep -o '"sha256":"[0-9a-f]\{64\}"' | head -1 | sed 's/.*:"//; s/"//' || true)"
  if [ -n "$hbcSha" ]; then
    [ -f "$out/canopy.bundle.hbc" ] || die "manifest declares bytecode but $out/canopy.bundle.hbc is missing"
    local actualHbc
    actualHbc="$(sha256sum "$out/canopy.bundle.hbc" | awk '{print $1}')"
    [ "$actualHbc" = "$hbcSha" ] \
      || die "canopy.bundle.hbc sha256 ($actualHbc) != manifest bytecode.sha256 ($hbcSha) — stale/mismatched .hbc"
    cp "$out/canopy.bundle.hbc" "$DIST/canopy.bundle.hbc"
    ok "staged canopy.bundle.hbc (Hermes bytecode, sha matches manifest)"
  else
    printf '  \033[33m· no Hermes .hbc in this build (no hermesc on this runner) — host will boot the JS bundle\033[0m\n'
  fi
  # The buildId-keyed archive map (AND-10) — stage ONLY the one whose name matches THIS build's
  # buildId (the bundle's sha256). The output dir can hold stale canopy.<oldBuildId>.map files from
  # prior builds; shipping those would be misleading, so we select by the current buildId, not a glob.
  local buildId
  buildId="$(sha256sum "$DIST/canopy.bundle.js" | awk '{print $1}')"
  if [ -f "$out/canopy.$buildId.map" ]; then
    cp "$out/canopy.$buildId.map" "$DIST/"
    ok "staged buildId-keyed archive map canopy.$buildId.map (AND-10)"
  fi
  # The Fabric mapping codegen (generated/*) — the host's component glue. Copy the tree if present.
  if [ -d "$out/generated" ]; then
    cp -R "$out/generated" "$DIST/generated"
    ok "staged generated/ Fabric codegen ($(find "$out/generated" -type f | wc -l) files)"
  fi

  # ---- 3. self-check: the staged bundle's sha256 MUST equal the manifest buildId ----------------
  # This is the SAME invariant the platform builds re-assert on the PACKAGED bundle (APK assets /
  # iOS Resources). Asserting it here too means a staging bug fails in THIS job, not three jobs later.
  assert_manifest_matches "$DIST/canopy.bundle.js" "$DIST/canopy.manifest.json"

  log "dist staged:"
  ( cd "$DIST" && find . -type f | sort | sed 's/^/    /' )
}

# | Assert the bundle file's sha256 equals the buildId AND the bundle entry sha256 recorded in the
# | manifest. Pure POSIX sha256sum + a tiny grep/sed JSON read (no jq dependency on the runner).
assert_manifest_matches() {
  local bundle="$1" manifest="$2"
  command -v sha256sum >/dev/null 2>&1 || die "sha256sum not available"
  local actual buildId bundleSha
  actual="$(sha256sum "$bundle" | awk '{print $1}')"
  # buildId and the bundle's recorded sha256 are both top-level/bundle fields in the manifest JSON.
  buildId="$(grep -o '"buildId":"[0-9a-f]\{64\}"' "$manifest" | head -1 | sed 's/.*:"//; s/"//' || true)"
  bundleSha="$(grep -o '"bundle":{[^}]*}' "$manifest" | grep -o '"sha256":"[0-9a-f]\{64\}"' | head -1 | sed 's/.*:"//; s/"//' || true)"
  [ -n "$buildId" ]   || die "manifest has no buildId"
  [ -n "$bundleSha" ] || die "manifest has no bundle.sha256"
  [ "$actual" = "$buildId" ] \
    || die "staged bundle sha256 ($actual) != manifest buildId ($buildId)"
  [ "$actual" = "$bundleSha" ] \
    || die "staged bundle sha256 ($actual) != manifest bundle.sha256 ($bundleSha)"
  ok "staged bundle sha256 == manifest buildId ($actual)"
}

# ---- drive -----------------------------------------------------------------------------------
case "$MODE" in
  full)        build_toolchain; build_bundle ;;
  bundle-only) build_bundle ;;
esac

log "build-app-bundle: DONE ($MODE) — app $CANONICAL_APP, dist $DIST"
