# canopy/native

**The third renderer for Canopy's VirtualDom.** `Html` renders nodes to the browser
DOM; `Ssr` renders the same nodes to HTML strings; **`Native` renders the same nodes
to React Native's Fabric host over JSI** — producing real `UIView` / `android.view.View`
trees, native gestures, and Yoga layout, with no React and no WebView.

```
   view : model -> Native.Node msg     ← idiomatic Canopy, same as Html
        │  (a VirtualDom.Node — renderer-agnostic data)
        ▼
   external/native.js   the THIRD walker: SSR-shaped traversal that emits
                        Fabric create/update/insert/remove instead of strings/DOM
        │  __fabric_*  (JSI host functions)
        ▼
   React Native Fabric  Shadow Tree • Yoga • Mount → real native views
```

## Why this works

The compiler, `core` (the TEA loop + Cmd/Sub scheduler), and `virtual-dom` (the node
data model) are **unchanged**. A `VirtualDom.Node` is pure data — `Ssr` already proves
you can write a *new* walker over those nodes that emits to a non-DOM target. `Native`
is that walker, pointed at Fabric. The runtime runs on Hermes (RN's JS engine), whose
only host-global needs are `setTimeout` and a `scope` object — both trivially provided.

See [`../docs/architecture.md`](../docs/architecture.md) for the full design and
[`../docs/roadmap.md`](../docs/roadmap.md) for the phase plan.

## Usage

```canopy
import Native
import Native.Attributes as A
import Native.Events as Events

type alias Model = Int
type Msg = Increment

init : () -> ( Model, Cmd Msg )
init _ = ( 0, Cmd.none )

update : Msg -> Model -> ( Model, Cmd Msg )
update Increment model = ( model + 1, Cmd.none )

view : Model -> Native.Node Msg
view model =
    Native.column [ A.padding 24 ]
        [ Native.text [ A.fontSize 24 ] ("Count: " ++ String.fromInt model)
        , Native.button [ Events.onPress Increment ] "Tap me"
        ]

main : Native.Program () Model Msg
main =
    Native.element
        { init = init, view = view, update = update, subscriptions = always Sub.none }
```

Compile it and host it with the React Native shell in [`../host`](../host); the
[`../tool`](../tool) `canopy-native` CLI orchestrates the build, and
[`../harness`](../harness) runs the walker headlessly in Node against a mock Fabric
to prove create → tap → targeted update without a device.

## Modules

| Module | What it gives you |
|---|---|
| `Native` | `element` program entry; `view`/`column`/`row`/`text`/`button`/`image`/`scroll`/`textInput`/`pressable` |
| `Native.Attributes` | flexbox/visual `style` props (Yoga) + direct props (`testID`, `source`, `value`, …) |
| `Native.Events` | `onPress`/`onLongPress`/`onChangeText`/`onSubmitEditing` + generic `on` |
| `Native.Css` | **css-in-js for native** — reuses `canopy/css` as-is; interprets `Css.Style` into Fabric style props (see [css-in-js-native.md](../docs/css-in-js-native.md)) |
| `Native.Testing` | device-free assertions over the walker (component tag, text, targeted-update counts, style props) for `canopy test` |

## Component → Fabric tag map

| `Native` | Fabric component |
|---|---|
| `view` / `column` / `row` / `pressable` | `RCTView` |
| `text` | `RCTText` (+ `RCTRawText`) |
| `scroll` | `RCTScrollView` |
| `image` | `RCTImageView` |
| `textInput` | `RCTSinglelineTextInputView` |

The map is the only host-specific surface; adding a component is one line here plus a
prop mapping the host already understands (RN Codegen-style, but hand-authored — which
the RN docs confirm is supported, not mandatory to generate).
