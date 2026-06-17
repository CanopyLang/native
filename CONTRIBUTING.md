# Contributing to canopy/native

Thanks for helping. The project's whole value is **reliability** — so the contribution rules are built
around *not regressing the guarantees*.

## The one rule

**Every PR keeps all existing CI gates green, and new load-bearing behaviour ships with its own gate.**
A feature without a device-free test/gate is not done. The guarantee in [`docs/guarantee.md`](docs/guarantee.md)
is only true because each clause has a live, CI-checked enforcement point.

## Setup

```sh
# Build the in-house compiler + the canopy-native CLI (see README "Quick start").
# Then the canonical device-free gate — the same one CI runs:
bash scripts/ci-test.sh
```

`scripts/ci-test.sh` is the source of truth for "green". Run it before opening a PR.

## What a good PR looks like

1. **Scoped.** One concern. Reference the plan id if it maps to one (e.g. `REL-5`, `CAP-2`) — see
   [`plans/MASTER-PLAN.md`](plans/MASTER-PLAN.md).
2. **Gated.** New host/reconciler/marshalling behaviour → a `harness/run-*.js` device-free proof and/or
   a `scripts/check-*.sh` structural gate wired into `scripts/ci-test.sh`. New capability → its
   `gen-capability` spec + mock + the autolink zero-edit gate (CAP-0).
3. **Honest.** If it touches the guarantee scope, update `docs/guarantee.md` (the doc-lint will catch a
   dropped caveat or a dead citation). Never add an unqualified "no errors"/"cannot crash" claim.
4. **Cross-platform parity.** Anything that affects layout/marshalling/capabilities adds or updates a
   shared test-vector so iOS and Android can't drift (the parity gates).
5. **Green.** All gates pass, including `ios-build` (required) and the device-free suite.

## Material changes need an RFC

Changes to the JSI ABI, the public `Native.can` API, the vendored RN/Hermes pin, the reliability
guarantee, or anything that weakens a gate require a merged RFC first
([`rfcs/0000-template.md`](rfcs/0000-template.md)). This keeps the dangerous surfaces deliberate.

## Commit / PR hygiene

- Clear, imperative commit subjects; explain the *why* in the body.
- Link the plan id and any issue.
- Keep the diff reviewable; large mechanical changes separate from logic changes.

## Code of conduct

Be respectful and constructive. Harassment is not tolerated. Report concerns privately to the maintainer.
