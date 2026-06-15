# Compiler pinning (how the sibling Canopy compiler is version-controlled)

`canopy/native` consumes the **in-house Canopy compiler** (the Elm-fork toolchain that lives in the
sibling repo `../compiler`, Haskell stack project `canopy`) to build the JS bundle from `.can` source.
This doc records the **pinning mechanism**; the wiring is implemented by **CI-2**
(`scripts/build-compiler-from-pin.sh` + the `rebuild-bundle` job in `.github/workflows/ci.yml`).

## Decision

Pin the sibling compiler to a single, auditable **commit SHA** recorded in
[`scripts/compiler-pin.env`](../scripts/compiler-pin.env) — the one file CI and every dev box read to
know *which* compiler builds the bundle. The SHA MUST include the CMP-1/2/3 tree-shaker + resolver
fixes (`docs/compiler-fixes.md`), otherwise the IIFE bundle throws `F7 is not defined` at boot.

CI then, in the `rebuild-bundle` job:

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

Only the **`rebuild-bundle`** job needs the compiler toolchain. The shipping build jobs do **not**:

- `gate` (Node harness + guards) needs no compiler.
- `android-release` and `ios-build` consume a **committed** `canopy.bundle.js`
  (`host/android/app/src/main/assets/`); they need no compiler bootstrap.

So the clone + `stack install` cost is paid only by `rebuild-bundle`, keeping the common path cheap.
(Building the bundle FROM SOURCE in the android/ios jobs — replacing the committed bundle — is CI-3;
Stack/Gradle caching to keep `rebuild-bundle` warm is CI-4.)

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
