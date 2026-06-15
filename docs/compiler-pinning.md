# Compiler pinning (how the sibling Canopy compiler is version-controlled)

`canopy/native` consumes the **in-house Canopy compiler** (the Elm-fork toolchain that lives in the
sibling repo `../compiler`, Haskell stack project `canopy`) to build the JS bundle from `.can` source.
This doc **ratifies the pinning mechanism**; the actual wiring is implemented by **CI-2**. CI-1 only
records the decision and the current pin.

## Decision

Pin the sibling compiler as a **git submodule** of `../compiler`, fixed to a specific commit SHA that
includes the compiler fixes this repo depends on (CMP-1/2/3). CI then:

1. `git submodule update --init --recursive` to fetch the pinned compiler at its SHA;
2. `stack build && stack install` inside the submodule to put the `canopy` binary on `PATH`;
3. `scripts/link-dev-packages.sh` to resolve the sibling `canopy/*` source packages
   (via `canopy link` into `~/.canopy/packages`, the compiler's own resolver — no hand-rolled symlinks).

A submodule (over vendoring or a loose `CANOPY_COMPILER_REF` env) gives a single auditable SHA in this
repo's tree, reproducible `git clone --recurse-submodules`, and a clean upgrade path (bump the submodule
pointer in one commit).

## Current pin (record at time of writing)

- Sibling compiler repo: `../compiler`
- Branch: `master`
- Tip SHA: **`eb8da5f40634555173b851afc5bf6e706ec7b4db`** (working tree currently **dirty** — 8+ modified
  `.hs` files staged for the CMP-1/2/3 fixes, e.g. `packages/canopy-core/src/Generate/JavaScript.hs`,
  `packages/canopy-builder/src/Compiler.hs`, `packages/canopy-builder/src/PackageCache.hs`).

> **CI-1 BLOCKS on CMP-1/2/3 being committed first.** The fixes are uncommitted in `../compiler`, so
> there is no clean SHA to pin yet. Once CMP-1/2/3 land as a commit, CI-2 sets the submodule pointer to
> *that* SHA (not `eb8da5f`, which predates the fixes).

## What actually needs the compiler in CI

Only a future **`rebuild-bundle`** job needs the compiler toolchain. The shipping CI jobs do **not**:

- `gate` (Node harness + guards) needs no compiler.
- `android-release` and `ios-build` consume a **prebuilt** `canopy.bundle.js`; they need no compiler
  bootstrap. (Note: that bundle is currently `.gitignore`d — flagged separately for CI-7; until CI
  rebuilds or commits the bundle, `android-release` cannot pass on a clean clone.)

So the submodule + `stack install` cost is paid only when the bundle is rebuilt from source, keeping the
common path cheap.

## Upgrade procedure (once submodule is wired by CI-2)

```bash
git submodule update --remote compiler   # or: cd compiler && git checkout <new-sha>
cd compiler && git checkout <sha-with-CMP-1/2/3>
cd .. && git add compiler && git commit -m "Bump compiler pin to <sha>"
```

CI re-runs `stack build && stack install` against the new SHA; if the bundle output changes, the
`rebuild-bundle` job regenerates `canopy.bundle.js` and its integrity manifest.
