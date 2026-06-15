# canopy/native — package TODO

Tracks the package (`src/` + `external/native.js`) specifically. Cross-cutting
project phases live in `../../docs/roadmap.md`.

## Done (Phase 1 wedge)
- [x] `Native` view module: `view`/`column`/`row`/`text`/`button`/`image`/`scroll`/`textInput`/`pressable`, built on `VirtualDom` (no compiler/core/vdom changes).
- [x] `Native.Attributes` (Yoga style props + direct props) and `Native.Events` (press/text).
- [x] `external/native.js`: the third walker — `_Native_render` (mirror of `_VirtualDom_render`), `_Native_updateTNode` (mirror of `_VirtualDom_updateTNode`), facts→Fabric props, text fast-path, unkeyed + keyed reconciliation, the `element` seam + animator, event registry + dispatch.
- [x] Validated headlessly against a mock Fabric in `../../harness`.

## Next
- [ ] Keyed reconciliation: replace detach-all-reinsert with LIS move-minimization (mirror `_VirtualDom_lisIndices`). Correct today, not move-minimal.
- [ ] `Native.Keyed` module exposing `keyedNode` ergonomically.
- [ ] More components: `RCTSwitch`, `RCTActivityIndicator`, multiline `TextInput`, `SafeAreaView`, `FlatList`-backed virtualization.
- [ ] Custom (`__2_CUSTOM`) node support → arbitrary Fabric host components (`RCTImage`, maps, video).
- [ ] `Native.Attributes` numeric coercion contract: document/handle `%`, `"auto"`, and shorthand (paddingHorizontal, etc.).
- [ ] Wire `Cmd`/`Sub` native backends (HTTP, navigation, storage, geolocation) — see roadmap Phase 3.
- [ ] Tests in `tests/Test/` once `canopy/test` is registered locally.

## Gotchas captured during the build
- Keyed kids are `{ a: key, b: node }` tuples, NOT a map.
- A NODE with one TEXT child is hoisted to a `text` prop (the textContent fast-path) so label updates are a single `updateProps`, never a re-mount — this is the §8 pass criterion.
- Handlers compare by reference (`$` tag + identity); decoder-identity changes take the swap path. Same pragmatic equality as the browser walker.
- `module`-guarded CommonJS export at the foot of `native.js` is for the Node harness only; it is skipped in a real Hermes/browser bundle where `module` is undefined.
