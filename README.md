# canopy/native

**Build real native iOS/Android apps from idiomatic Canopy `view` code** — rendering
through React Native's **Fabric** host over JSI, with **no React and no WebView**.

`Html` renders Canopy's `VirtualDom.Node` data to the browser DOM. `Ssr` renders the
*same* data to HTML strings. **`Native` renders the same data to native Fabric views.**
The compiler, `core` (the TEA loop + Cmd/Sub scheduler), and `virtual-dom` (the node
data model) are **never touched** — only the render seam is swapped.

```
   view : model -> Native.Node msg        ← ordinary Canopy, identical to Html
        │  a VirtualDom.Node (renderer-agnostic data)
        ▼
   external/native.js   the THIRD walker — emits Fabric create/update/insert/remove
        │  __fabric_*  (JSI host functions)
        ▼
   React Native Fabric  Shadow Tree • Yoga layout • Mount → real UIView / android.view
```

> Status: **wedge proven end-to-end on the real toolchain.** The actual `canopy`
> compiler builds the package, and the emitted bundle (real runtime + real walker)
> renders a native tree and turns a tap into a single targeted `updateProps` — no
> re-mount. See [`docs/architecture.md`](docs/architecture.md) §7.

## Layout

| Dir | What |
|---|---|
| [`package/`](package) | the **`canopy/native`** Canopy package — `Native` view module + `external/native.js` (the walker). The deliverable. |
| [`tool/`](tool) | the **`canopy-native`** Haskell CLI — build orchestrator + Fabric codegen. |
| [`host/`](host) | the **React Native New-Architecture host** shell — JSI `__fabric_*` installer + iOS/Android mounts. |
| [`harness/`](harness) | **headless proof** — runs `native.js` against a mock Fabric in Node (no device). |
| [`examples/counter/`](examples/counter) | the **Phase-1 POC** app. |
| [`docs/`](docs) | architecture, roadmap, App-Store-2.5.2. |

## Quick start

```sh
# 1. build the Canopy compiler once (if not already on this machine)
cd ../compiler && make build && cp "$(stack path --local-install-root)/bin/canopy" ~/.local/bin/

# 2. build the canopy-native CLI
cd ../native/tool && stack build && stack test \
  && cp "$(stack path --local-install-root)/bin/canopy-native" ~/.local/bin/

# 3. compile the example to a Hermes bundle + Fabric codegen
canopy-native build ../examples/counter        # → build/canopy.bundle.js + build/generated/

# 4. prove it works headlessly (no device needed)
cd ../harness && npm test                       # run.js (17/17) + run-compiled.js (14/14)

# 5. doctor — what's needed for device builds
canopy-native doctor
```

## What's validated here vs. what needs a device

✅ **Validated locally** (this machine): the package compiles with the real compiler;
the emitted bundle drives a mock Fabric correctly (real native tree, single targeted
`updateProps`, no re-mount); the Haskell tool builds + 22 tests pass + the full pipeline
runs.

☐ **Needs a device / SDK** (not present here — no Android SDK, no macOS): the actual
on-device build via the `host/` templates. The host JSI installer is the
inspection-verifiable core; per-platform mounts are faithful scaffolds. Android first
(see `docs/roadmap.md`).

## The thesis, in one line
Don't rewrite the compiler or build an engine — **write one more walker over data that's
already renderer-agnostic, and ride an existing native host.** Proven.

## License
BSD-3-Clause (matches the Canopy packages). See [`LICENSE`](LICENSE).
