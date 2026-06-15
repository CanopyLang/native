# css-in-js on native (reusing canopy/css)

**Goal:** the same typed css-in-js authoring you use on the web — `canopy/css` — for
native apps, reusing the package **as-is** (no native fork of it).

## The key idea: `Css.Style` is renderer-agnostic data

`canopy/css` builds an opaque-but-public `Css.Style` value:

```canopy
type Style
    = Property String String          -- "background-color" "#0b1020"
    | PseudoClass String (List Style) -- ":active"  [ ... ]
    | MediaQuery String (List Style)  -- "(max-width: 480px)" [ ... ]
    | Nested String (List Style)
    | Batch (List Style)
    | ...
```

This is **exactly the same shape of insight as `VirtualDom.Node`**: a renderer-agnostic
data structure with per-target interpreters. canopy/css already ships two interpreters of
this data:

| Interpreter | Output |
|---|---|
| `Css.css` | a scoped class name + injected stylesheet rules (browser css-in-js) |
| `Css.inlineStyle` | a flat `style="..."` attribute (browser inline) |

**`Native.Css` is a third interpreter** of the same `Css.Style` data, targeting React
Native Fabric. Because the constructors are public (`Css.Style(..)`), the native package
reads them directly — `canopy/css` is a normal dependency, untouched.

```
   List Css.Style                  ← one authoring API (Css.padding, Css.color, …)
        │   renderer-agnostic data
        ├──────────────┬───────────────────────┐
        ▼              ▼                        ▼
   Css.css        Css.inlineStyle          Native.Css.css
   (DOM class)    (DOM inline)             (Fabric style props)   ← this package
```

## What maps today: the static property surface

`Native.Css.css : List Css.Style -> List (Attribute msg)` interprets every
`Property name value` into a Fabric style fact:

- **property name** is camel-cased to RN's convention: `background-color` → `backgroundColor`.
- **value** has its `px` unit stripped (`24px` → `24`) so the JSI layer coerces it to a
  float for Yoga; `%`, unitless, and color strings pass through.
- `Batch` flattens.

That covers the overwhelming majority of real styling: flexbox layout, spacing, colors,
typography, borders, opacity, transforms. It is the full **static** css surface, and it
type-checks against the exact same `canopy/css` functions the web uses.

```canopy
Native.column
    (Native.Css.css
        [ Css.flexDirection Css.column
        , Css.padding (px 24)
        , Css.backgroundColor (hex "#0b1020")
        ]
    )
    [ ... ]
```

## The native frontier: pseudo-classes, media, keyframes

React Native style objects are **flat** — there is no inline `:hover`/`:active`, no
`@media`, no `@keyframes`. So canopy/css's `PseudoClass`/`MediaQuery`/`Nested`/keyframe
variants have **no static** native equivalent, and `Native.Css.css` does not emit them
(it would be wrong to silently flatten a `:active` rule into the base style). On native
these are inherently **runtime-resolved**, and that is the planned layer on top of this
interpreter:

| css-in-js construct | native realization (planned) |
|---|---|
| `:active` / `:pressed` | resolve against `Pressable` interaction state — the walker swaps the variant when the host emits press in/out |
| `:focus` | resolve against focus state of `TextInput` etc. |
| `:hover` | **dropped** — phones have no hover (correct, matches RN) |
| `@media (max-width: …)` | a `Dimensions` subscription re-renders with the matching variant |
| `@keyframes` / transitions | compile to RN `Animated` drivers |

The architecture makes this additive: because the native side already interprets the
`Css.Style` AST, supporting an interaction variant is "recognize the `PseudoClass ":active"`
node and register its `Property` set as a press-state style on the view," not a rewrite.
The static surface ships now; the dynamic surface is a documented, non-breaking extension.

## Why not fork canopy/css?

Forking would duplicate hundreds of typed property functions and split the ecosystem. The
`Css.Style` data is already renderer-neutral, so the only thing native needs is its own
*interpreter* — which is small, lives entirely in `canopy/native`, and keeps web and
native styling **literally the same code**. This is the same principle that lets `Native`
reuse `VirtualDom` and `core` unchanged (see [architecture.md](architecture.md)).
