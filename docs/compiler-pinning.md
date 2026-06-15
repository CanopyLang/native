# Compiler pinning (how the sibling Canopy compiler is version-controlled)

`canopy/native` consumes the **in-house Canopy compiler** (the Elm-fork toolchain that lives in the
sibling repo `../compiler`, Haskell stack project `canopy`) to build the JS bundle from `.can` source.
This doc records the **pinning mechanism**; the wiring is implemented by **CI-2**
(`scripts/build-compiler-from-pin.sh`, run by the canonical **`gate`** job in
`.github/workflows/ci.yml` — see [`docs/ci.md`](ci.md) for how CI-7 folded the former
standalone `rebuild-bundle` job into that one gate).

## Decision

Pin the sibling compiler to a single, auditable **commit SHA** recorded in
[`scripts/compiler-pin.env`](../scripts/compiler-pin.env) — the one file CI and every dev box read to
know *which* compiler builds the bundle. The SHA MUST include the CMP-1/2/3 tree-shaker + resolver
fixes (`docs/compiler-fixes.md`), otherwise the IIFE bundle throws `F7 is not defined` at boot.

CI then, in the canonical `gate` job:

1. obtains the compiler **at exactly that SHA** — `scripts/build-compiler-from-pin.sh` clones the
   public compiler repo at the pinned SHA on a clean runner (no sibling checkout needed), or, on a
   dev box that already has `../compiler`, builds the pinned commit via `git archive` **without
   mutating** the local working tree (which may carry later Wave-2 work);
2. `stack build && stack install canopy:exe:canopy` to put the `canopy` binary on `PATH`
   (the snapshot + every extra-dep are pinned in the compiler's `stack.yaml.lock`, so the binary is
   reproducible per SHA);
3. `scripts/link-dev-packages.sh` to resolve the sibling `canopy/*` source packages
   (via `canopy link` into `~/.canopy/packages`, the compiler's own resolver — no hand-rolled symlinks);
4. **F7 acceptance gate** — builds the canonical app's full host bundle
   (`canopy-native build examples/counter`) and EVALUATES + BOOTS it in node under the mock Fabric
   (`scripts/verify-iife-no-f7.js`). A dropped arity helper (`F2..F9`), program-export call
   (`_Platform_export`), or kernel id surfaces as a `ReferenceError` and fails the build.

### Why a recorded SHA + build script, not a git submodule

The earlier plan favoured a `git submodule` of `../compiler`. We ship a recorded-SHA build script
instead because it gives the same single auditable SHA (in `compiler-pin.env`, diffed in one commit
on a bump) **without** a submodule's costs: no `.gitmodules`/gitlink to keep in sync, no
`--recurse-submodules` foot-gun on clone, and the build can target a public SHA on a clean runner
while a dev box reuses its existing `../compiler` checkout untouched. A submodule could be layered on
later; the pin (`compiler-pin.env`) and the gate (`verify-iife-no-f7.js`) would not change.

## Current pin

- Sibling compiler repo: `../compiler` (remote `https://github.com/CanopyLang/compiler.git`)
- Branch: `master`
- Pinned SHA: **`391dde943a793ad03c0b394a2f64396cf11252d4`**
  — the Wave-1 `master` commit "Compiler: land tree-shaker/manager/resolver work, green the suite".
  Verified to contain `Generate/JavaScript.hs` `scanRuntimeIdents`/`scanArities` (the F7 root-scan,
  CMP-1) and `PackageCache.resolveInstalledVersion` (the installed-version resolver, CMP-3).

The pin lives in `scripts/compiler-pin.env`; bumping it is a one-line edit + commit there.

## What actually needs the compiler in CI

Two jobs build the compiler-from-pin (CI-7 — both share one pin-keyed Stack cache, so the
tens-of-minutes GHC/snapshot build is paid once across the workflow):

- the canonical **`gate`** job — it puts `canopy` on PATH (so `scripts/ci-test.sh`'s
  `canopy test tests/` step runs) and runs the F7 IIFE acceptance gate;
- the **`bundle`** job — it builds the shippable `app-bundle` artifact FROM SOURCE.

The shipping build jobs do **not** bootstrap the compiler: `canopy.bundle.js` is **git-ignored**
(no committed bundle — see CI-3), so `android-release`, `android-instrumented`, and `ios-build`
**download** the `app-bundle` artifact the `bundle` job produced and stage it into the app tree.
(Stack/Gradle caching to keep these jobs warm is CI-4.)

## Running it locally

```bash
scripts/build-compiler-from-pin.sh                # full: obtain pinned compiler, install, link, F7 gate
scripts/build-compiler-from-pin.sh --verify-only  # canopy already on PATH: just rebuild + F7 gate
scripts/build-compiler-from-pin.sh --no-verify    # build + install + link only
```

## Upgrade procedure (bump the pin)

```bash
cd ../compiler && git log --oneline      # pick the new SHA (must keep CMP-1/2/3 + green suite)
# edit scripts/compiler-pin.env: CANOPY_COMPILER_SHA=<new-sha>
scripts/build-compiler-from-pin.sh       # locally prove the new pin builds + passes the F7 gate
git add scripts/compiler-pin.env && git commit -m "Bump compiler pin to <new-sha>"
```

CI re-runs `build-compiler-from-pin.sh` against the new SHA on the next push; the cache key is the
pin, so a bump triggers a fresh GHC build and re-runs the F7 gate.
