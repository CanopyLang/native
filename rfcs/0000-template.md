# RFC-NNNN: <title>

- **Status:** Draft | Accepted | Rejected | Superseded
- **Author(s):**
- **Created:** YYYY-MM-DD
- **Affects:** (e.g. JSI ABI / Native.can public API / vendored RN pin / reliability guarantee / a CI gate)

> Material changes to the load-bearing surfaces require a merged RFC (see GOVERNANCE.md): the
> `__fabric_*`/`__canopy_*` JSI ABI, the public `Native.can` API, the vendored RN/Hermes pin, the
> reliability guarantee (`docs/guarantee.md`), and anything that weakens a CI gate.

## Summary

One paragraph: what changes and why.

## Motivation

The problem, with evidence (file:line, a gate, a benchmark, a bug). What's wrong or missing today.

## Detail

The proposed design. Be concrete enough to implement. Call out the affected files and the new/changed
CI gate that will prove it.

## Reliability & compatibility impact

- Does this change the guarantee scope (`docs/guarantee.md`)? If so, which clause/caveat?
- Cross-platform parity: does it need a new/updated shared test-vector?
- ABI/compat: does it bump `CANOPY_ABI_VERSION` / `runtimeVersion`?

## Alternatives considered

What else was weighed, and why this won.

## Risks & migration

What could break; how existing apps migrate; rollback story.

## Acceptance

The objective, CI-gated criteria that mark this RFC "done".
