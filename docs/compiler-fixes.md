# Compiler fixes made for `canopy test` + native

Standing up `canopy test` for the native package surfaced two **compiler** bugs (they
affected every package, not just native). Both were fixed properly in the compiler
(`~/projects/canopy/compiler`), not worked around. This file records what and why.

## 1. IIFE runtime tree-shaker dropped generator-emitted references

**Symptom:** `canopy test` (and any `--output-format=iife` build) crashed at runtime with
`ReferenceError: _Platform_export is not defined`, then `F7 is not defined`.

**Root cause:** the IIFE runtime is tree-shaken. Its roots were collected *only* from the
optimized AST + a scan of FFI files. But the code generator *also* emits references the
AST never contains — the program-export call `_Platform_export({...})` (from
`Kernel.toMainExports`, appended after collection) and the `F7`/`A3` arity helpers used
by emitted runtime functions like `_Json_map6`. Those definitions were therefore never
emitted. Effect-manager glue only survived via a hand-written seed (`managerRuntimeIds`) —
i.e. the design relied on humans remembering to seed every generator-emitted symbol. The
fork's re-architected `core` (monolithic `external/runtime.js` instead of Elm-style
per-function `Elm/Kernel/*.js`) removed the implicit inclusion path that had masked it.

**Fix (correct by construction):** make the tree-shaker's roots match the **actual
generated output**. After building the inner content and the candidate runtime, scan
both for kernel identifiers (`_[A-Z]..._...`) and arity helpers (`F2..F9`/`A2..A9`), and
seed those. The runtime that ships is then exactly what the output references — no symbol
a generator emits can ever be dropped, for every current and future emitter.
`compiler/packages/canopy-core/src/Generate/JavaScript.hs` — `scanRuntimeIdents` /
`scanArities`, folded into `neededRuntime` / `neededArities`.

Rejected alternatives: hand-seeding each symbol (the whack-a-mole that caused this);
shipping the full runtime and letting esbuild DCE it (research's adversarial check refuted
bundler-DCE parity — PureScript built `zephyr` precisely because esbuild isn't enough;
it would also bloat every mobile bundle).

## 2. Package-test dependency resolution forced the constraint lower bound

**Symptom:** `canopy test` on a package couldn't find its dependencies unless every
dependency happened to be installed at exactly the lower bound of its constraint (e.g.
`1.0.0`), even though the dev packages are linked at newer versions (core `1.1.0`,
virtual-dom `1.0.5`, test `2.0.0`).

**Root cause:** the package-test paths (`Test.Compile.ensureTestDepArtifacts` and
`Compiler.loadDependencyArtifacts`) resolved each dependency via
`Outline.allDeps` = `Constraint.lowerBound` — the *minimum* version, not what's installed.

**Fix:** resolve each constraint against what is actually installed. New
`PackageCache.resolveInstalledVersion name constraint` scans `~/.canopy/packages` and the
Elm-compat cache, keeps the versions satisfying the constraint, and returns the highest —
preferring a version under the package's own author (a `canopy link`ed tree) over an
Elm-fallback copy, and falling back to the lower bound only when nothing is installed.
Used at every level of the direct + transitive test-dep walk. Applications keep their
exact pins (unchanged).

**Result:** `canopy test` works on any machine with just `canopy link` — no hand-rolled
version symlinks. See `../scripts/link-dev-packages.sh`.

## 3. Version alignment (pre-release housekeeping)

The compiler's blessed standard-version list lagged the monorepo. Bumped to current in
`Setup.hs` (`canopy setup`) and `New.hs` (`canopy init` scaffold): core `1.0.5 → 1.1.0`,
virtual-dom `1.0.3 → 1.0.5`, html `1.0.0 → 1.0.1`, browser `→ 1.0.1`.
