# canopy-native (the CLI)

A Haskell build orchestrator + Fabric codegen for `canopy/native` apps — written in
Haskell to match the Canopy compiler it drives (same Stack snapshot, same house style).

## Build

```sh
cd tool
stack build           # reuses the compiler's GHC 9.8.4 + snapshot cache
stack test            # 22 unit tests over codegen / bundle / config
cp "$(stack path --local-install-root)/bin/canopy-native" ~/.local/bin/
```

## Commands

| Command | What it does |
|---|---|
| `canopy-native init <name>` | scaffold a new native app (canopy.json + native.config.json + starter `Main.can`) |
| `canopy-native build [DIR] [--release]` | `canopy make` → assemble Hermes bundle → emit Fabric codegen |
| `canopy-native codegen [--out DIR]` | emit the Fabric mapping glue only |
| `canopy-native doctor` | report toolchain readiness (compiler / node / Android / iOS) |

## What `build` produces

```
build/
├── app.iife.js          # raw canopy compiler output
├── canopy.bundle.js     # Hermes-ready: preamble (F2..F9 ABI + setTimeout shim) + IIFE + __canopy_boot
└── generated/
    ├── component-manifest.json   # tag → Fabric component + prop-kind table (host loads this)
    ├── CanopyComponents.h         # C++: valid tags + the (tag|prop) float-coercion set for the JSI layer
    └── canopyComponents.ts        # TypeScript view of the component surface
```

## Design

- **`Component.hs`** — the typed source of truth: the built-in RN component set
  (`RCTView`/`RCTText`/…), each prop tagged `string`/`float`/`color`/`bool`/`event`.
- **`Codegen.hs`** — pure `spec → source` for three targets (JSON / C++ / TS), kept in
  lock-step. Unit-tested like the compiler's own codegen.
- **`Bundle.hs`** — pure Hermes-bundle assembly. The preamble provides the full
  `F2..F9` / `A2..A9` ABI as globals, because the DEV-mode IIFE only defines the arities
  its *live* code uses, yet bundled kernels reference higher ones (`F6`).
- **`Build.hs`** — shells out to the existing `canopy` compiler (no recompilation logic
  of its own), then assembles + emits codegen.
- **`Doctor.hs` / `Scaffold.hs` / `Config.hs`** — toolchain probe, project scaffolding,
  `native.config.json`.
