# counter — Phase-1 proof-of-concept

The smallest end-to-end Canopy program that drives real native views through Fabric
(docs/architecture.md §8). Tapping increments a counter; the label re-renders via a
single targeted native `updateProps` — not a re-mount.

```canopy
view model =
    Native.column [...]
        [ Native.text [...] ("Count: " ++ String.fromInt model)
        , Native.button [ Events.onPress Increment, A.testID "increment" ] "Tap me"
        , Native.button [ Events.onPress Reset, A.testID "reset" ] "Reset"
        ]
```

## Build

```sh
canopy-native build .            # → build/canopy.bundle.js + build/generated/*
```

Then run it headlessly against the mock Fabric (no device needed):

```sh
cd ../../harness && node run-compiled.js   # 14/14 PASS
```

…or host `build/canopy.bundle.js` on a device with the React Native shell in
`../../host`.

## Two dependency forms (and why this one looks unusual)

This example's `canopy.json` currently uses **`source-directories`** to embed
`canopy/native` and `canopy/virtual-dom` straight from the monorepo:

```json
"source-directories": [ "src", "../../package/src", "../../../virtual-dom/src" ]
```

with `external/native.js` and `external/virtual-dom.js` symlinked in. This is a
**workaround for a fresh machine** where the `canopy/*` packages are not yet
registered in `~/.elm/0.19.1/packages` — without it, `canopy/virtual-dom` falls back
to `elm/virtual-dom` (Elm's original, which uses different node field names) and the
walker can't read the nodes.

On a machine where `canopy/native` and `canopy/virtual-dom` are installed as packages,
use the **normal dependency form** instead (saved as `canopy.json.installed`):

```json
"source-directories": [ "src" ],
"dependencies": { "direct": {
  "canopy/core": "1.0.0", "canopy/json": "1.0.0",
  "canopy/native": "0.1.0", "canopy/virtual-dom": "1.0.0"
}}
```

`canopy-native build` works with either form — it just shells out to `canopy make`.
See `../../docs/architecture.md` §"Packaging note" for how `native` gets registered as
a kernel-trusted package (it reads VirtualDom node internals, exactly like `canopy/ssr`).
