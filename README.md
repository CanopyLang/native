# canopy/native

**Build real native iOS/Android apps from idiomatic Canopy `view` code** — running the
compiled JS on **Hermes** and mounting **real platform views over JSI**, with **no React
and no WebView**. (It does **not** use React Native's Fabric runtime — see
[`docs/rn-coupling.md`](docs/rn-coupling.md) for the exact, grep-pinned coupling surface.)

`Html` renders Canopy's `VirtualDom.Node` data to the browser DOM. `Ssr` renders the
*same* data to HTML strings. **`Native` renders the same data to real platform views**
(Android `android.view`, iOS `UIView`) via a tiny JSI mount ABI. The compiler, `core`
(the TEA loop + Cmd/Sub scheduler), and `virtual-dom` (the node data model) are **never
touched** — only the render seam is swapped.

```
   view : model -> Native.Node msg        ← ordinary Canopy, identical to Html
        │  a VirtualDom.Node (renderer-agnostic data)
        ▼
   external/native.js   the THIRD walker — emits create/update/insert/remove
        │  __fabric_*  (Canopy's OWN JSI mount ABI — Fabric vocabulary, NOT RN's Fabric runtime)
        ▼
   CanopyHost (per platform):  Android = JNI → android.view ;  iOS = UIView + Yoga layout
        → real UIView / android.view  (no RCTBridge, no Fabric MountingManager, no ShadowTree)
```

> Status: **wedge proven end-to-end on the real toolchain.** The actual `canopy`
> compiler builds the package, and the emitted bundle (real runtime + real walker)
> renders a native tree and turns a tap into a single targeted `updateProps` — no
> re-mount. See [`docs/architecture.md`](docs/architecture.md) §7.

## Layout

| Dir | What |
|---|---|
| [`package/`](package) | the **`canopy/native`** Canopy package — `Native` view module + `external/native.js` (the walker). The deliverable. |
| [`tool/`](tool) | the **`canopy-native`** Haskell CLI — build orchestrator + mount-ABI codegen. |
| [`host/`](host) | the **native host shell** — a small JSI `__fabric_*` installer (Hermes + JSI + **Yoga layout on both platforms**: Android via the `com.facebook.yoga` Java binding, iOS via the C++ Yoga) + iOS/Android mounts. Canopy's own Android code calls **plain JNI**, never fbjni (though `libfbjni.so` rides along as a Hermes/Yoga transitive `.so`), and uses **no** RN Fabric/RCTBridge/TurboModule — see [`docs/rn-coupling.md`](docs/rn-coupling.md). |
| [`harness/`](harness) | **headless proof** — runs `native.js` against a mock mount host in Node (no device). |
| [`examples/counter/`](examples/counter) | the **Phase-1 POC** app. |
| [`docs/`](docs) | architecture, roadmap, App-Store-2.5.2. |

## Quick start

```sh
# 1. build the Canopy compiler once (if not already on this machine)
cd ../compiler && make build && cp "$(stack path --local-install-root)/bin/canopy" ~/.local/bin/

# 2. build the canopy-native CLI
cd ../native/tool && stack build && stack test \
  && cp "$(stack path --local-install-root)/bin/canopy-native" ~/.local/bin/

# 3. compile the example to a Hermes bundle + mount-ABI codegen
canopy-native build ../examples/counter        # → build/canopy.bundle.js + build/generated/

# 4. prove it works headlessly (no device needed)
cd ../harness && npm test                       # run.js (17/17) + run-compiled.js (14/14)

# 5. doctor — what's needed for device builds
canopy-native doctor
```

## What's validated here vs. what needs a device

✅ **Validated locally** (this machine): the package compiles with the real compiler;
the emitted bundle drives a mock mount host correctly (real native tree, single targeted
`updateProps`, no re-mount); the Haskell tool builds + 22 tests pass + the full pipeline
runs.

☐ **Needs a device / SDK** (not present here — no Android SDK, no macOS): the actual
on-device build via the `host/` templates. The host JSI installer is the
inspection-verifiable core; per-platform mounts are faithful scaffolds. Android first
(see `docs/roadmap.md`).

## The thesis, in one line
Don't rewrite the compiler or build an engine — **write one more walker over data that's
already renderer-agnostic, and ride an existing native host.** Proven.

## Reliability & guarantee scope
canopy/native's headline is **correctness-by-construction** — but stated precisely, not as
"can't crash". In *Canopy* code you cannot hit `null`/`undefined`, an unhandled `case`, or
"undefined is not a function"; effects only happen through the managed `Cmd`/`Sub` runtime; and a
JavaScript-level error becomes a recoverable red-box, not a process abort. Five things sit **outside**
that fence (stack overflow, Hermes OOM, the ports/FFI boundary, `==` on values holding functions, and
raw host-side signals). The full, honest scope — every guarantee with its live enforcement file, and
every caveat — is in [`docs/guarantee.md`](docs/guarantee.md), and `scripts/check-guarantee-doc.sh`
(a CI gate) fails the build if that document ever cites a deleted gate or drops a caveat.

## Contributing & governance
canopy/native is currently single-maintainer (bus-factor 1 — stated honestly, with a succession plan).
See [`CONTRIBUTING.md`](CONTRIBUTING.md) (the one rule: keep every CI gate green, gate new behaviour),
[`GOVERNANCE.md`](GOVERNANCE.md) (RFC process for load-bearing surfaces + bus-factor mitigation),
[`SECURITY.md`](SECURITY.md) (disclosure + supply-chain CVE posture), [`FUNDING.md`](FUNDING.md)
(the honest funding gap + first paid SKU), and [`rfcs/`](rfcs) (start from `0000-template.md`).
The full quality roadmap is [`plans/MASTER-PLAN.md`](plans/MASTER-PLAN.md).

## License
BSD-3-Clause (matches the Canopy packages). See [`LICENSE`](LICENSE).
