# Troubleshooting

A short runbook for the failure modes that waste the most time. Start here before
debugging deeper — most "the compiler is broken" moments are a stale cache.

## Stale package cache (`artifacts.dat`)

This is the **#1 cause of cryptic, unexplained compile failures** in dev. Read this
first.

### Symptom

A build or test that *used to work* suddenly fails with an error that doesn't point at
anything you changed:

- `Missing global Native.init` (or `Missing global <Module>.<fn>`)
- `UNKNOWN IMPORT [E0321] could not find module ...`
- `could not find a Css module`
- any "the compiler can't see a symbol that clearly exists" error
- a build that breaks right after you pulled, bumped the compiler, or edited a
  `canopy/*` package's source or `native.js`

### Cause

Every `canopy/*` package keeps a compiled-interface cache next to its source:
`artifacts.dat` (a binary file with a `CART` header and a compiler-version field). The
compiler reads this cache instead of recompiling the package every time.

The cache goes **stale** when the package's source — or the **compiler itself** —
changes but the cache is not regenerated. The compiler then reads an *old* interface and
reports symbols as missing/mismatched even though the source is correct. Two common
triggers:

- **Compiler drift** — you switched/upgraded the `canopy` compiler; old caches were
  written by the previous version (the `CART` version field no longer matches).
- **Source drift** — a `canopy/*` package's modules changed (new export, renamed
  function, added dependency) but its `artifacts.dat` still describes the old interface.

### Fix

Recompile every package's cache from source, under the compiler that's on your PATH now:

```sh
make rebuild-artifacts          # or: ./scripts/rebuild-artifacts.sh
```

This wipes each monorepo `canopy/*` package's stale `artifacts.dat` (and its
`canopy-stuff/` build cache), then recompiles them all from source in dependency order
(core -> json -> virtual-dom -> html/random -> css/test -> native) and prints a per-package
`OK`/`FAIL` summary. It is safe to run anytime and is idempotent.

Then confirm a real build is clean:

```sh
canopy-native build examples/counter
```

#### If a package's *version* changed

`rebuild-artifacts` recompiles what is already dev-linked into `~/.canopy/packages`. If a
package's **version** number changed (in its `canopy.json`), the symlink in the global
cache points at the old version dir, so re-link first, then rebuild:

```sh
make link-packages              # or: ./scripts/link-dev-packages.sh
make rebuild-artifacts
```

### Why these specific commands

`make rebuild-artifacts` runs `scripts/rebuild-artifacts.sh`, whose engine is
**`canopy setup`**. Given the dev-linked packages, `canopy setup` checks each linked
package's cache against the current compiler and recompiles every package whose cache is
missing or version-drifted, resolving the dependency order itself.

The script deliberately **deletes** each `artifacts.dat` (and `canopy-stuff/`) before
calling `canopy setup`, so a cache that is merely *version-drifted* is treated as missing
and gets rewritten under the current compiler — otherwise `canopy setup` would report it
as already "ready" and skip it.

Note the things that do **not** regenerate `artifacts.dat`, so you don't chase them:

- `canopy make` in a package dir only emits ESM to `output/` — it never writes the cache.
- `canopy test` in a package dir writes the cache for that package's *dependencies* but
  not for the package itself, and fails outright on suites that need a browser
  (e.g. `canopy/core`, `canopy/test`) even when the cache is fine.
- `canopy-native build <app>` caches interfaces inside the app's own `canopy-stuff/`,
  not back into each package source's `artifacts.dat`.

## Related toolchain checks

```sh
make doctor        # canopy-native doctor — compiler / Node / Android / iOS readiness
make help          # list dev targets
```
