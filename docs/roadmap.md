# canopy/native — Roadmap

Phases from the feasibility study, annotated with what this repo has already done.

## Phase 0 — De-risk the runtime ✅ (done)
Run an unmodified Canopy program's TEA loop on a non-DOM JS host.
- **Done:** `harness/run.js` runs the walker under a faithful mini-runtime; the real
  bundle (`run-compiled.js`) runs the actual `core/runtime.js` scheduler with only a
  `setTimeout`/`scope` shim. Confirms Layers A+B port for free.

## Phase 1 — "Hello, native `<Text>`" wedge POC ✅ (done)
A Canopy `view` renders a native `Text` + `Button`; a tap dispatches a `msg`; `update`
runs; the `Text` updates through a single `__fabric_updateProps` mount call over JSI — no
React, no WebView, and **not** RN's Fabric runtime (see
[`docs/rn-coupling.md`](rn-coupling.md)).
- **Done:** `examples/counter` compiles with the real `canopy` compiler; both harnesses
  assert the §8 pass criteria (single targeted `updateProps`, no re-mount). See
  `docs/architecture.md` §7.

## Phase 2 — Real component set + layout ◐ (mostly done)
`View`/`ScrollView`/`Image`/`TextInput`/`Pressable`, flexbox → Yoga, keyed lists.
- **Done:** all components in `Native` + the style/prop set in `Native.Attributes`;
  facts → Yoga style props; unkeyed + keyed reconciliation in the walker.
- **Next:** keyed reconciliation move-minimization (LIS, mirroring
  `_VirtualDom_lisIndices`); a small multi-screen example (list + detail + form).

## Phase 3 — Effects & native modules ☐ (next)
Wire Canopy `Cmd`/`Sub` effect managers to native capabilities (HTTP, navigation,
storage, camera, geolocation). Canopy already *has* these as browser packages
(`http`, `storage`, `camera`, `web-apis-geolocation`); here they get native FFI backends.
- The effect scheduler already runs unchanged (Phase 0). This phase re-backs the
  capability contracts, not the runtime.

## Phase 4 — Harden & decide on backend #2 ☐
Performance pass on the diff/mutation path; evaluate **Lynx** as a second native backend
behind the same `CanopyHost` interface (its only contract is create/update/insert/remove
+ set props + register event — host-neutral); settle the OTA/2.5.2 policy for production.

## Phase 5 — (optional, years out) own the stack ☐
Re-evaluate Static Hermes AOT + Skia **only if** the product needs pixel-identical
rendering or wants to shed the RN dependency. Not before — it trades away the entire RN
component/native-module ecosystem.

---

## Concrete next tasks
- [ ] Install `canopy/native` as a kernel-trusted package (zip + register, like the
      `~/fh/canopy-package-overrides` set) so apps depend on it normally instead of via
      `source-directories` (see `examples/counter/README.md`).
- [ ] LIS move-minimization in `_Native_updateKeyedKids`.
- [ ] `host`: stand up one real device build (Android first — needs the SDK/NDK this
      machine lacks) and confirm the view hierarchy in the Layout Inspector.
- [ ] Phase 3: a native `Http` Cmd backend as the first re-backed capability.
- [ ] Wire `__fabric_requestFrame` to a real vsync source (Choreographer / CADisplayLink).
