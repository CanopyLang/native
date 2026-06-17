# RFC-0001: The reliability guarantee scope

- **Status:** Accepted
- **Author(s):** maintainer
- **Created:** 2026-06-17
- **Affects:** reliability guarantee (`docs/guarantee.md`); all external claims

## Summary

Ratify [`docs/guarantee.md`](../docs/guarantee.md) as the single, precise, honest statement of what
canopy/native's "correctness-by-construction" does and does not guarantee, and make it a governed
surface: it may only change via a future RFC, and `scripts/check-guarantee-doc.sh` (a CI gate) keeps
it from citing a deleted enforcement file or dropping a caveat. This is also the project's first
end-to-end RFC — demonstrating the GOVERNANCE.md process is real, not decorative.

## Motivation

"Correctness-by-construction" / "no errors" was asserted in scattered code comments with no single
honest scope. An unqualified "cannot crash" is a credibility bomb the first time anyone reproduces a
stack overflow, an OOM, an FFI fault, `==` on functions, or a host-side signal. The pitch is only
durable if the claim is *precise* and *enforced*.

## Detail

- The positive guarantees and their **live enforcement files** are tabulated in `docs/guarantee.md`
  §1 (no null/undefined, exhaustive `case`, no "undefined is not a function", managed effects, draw
  errors caught, JS error → red-box not SIGABRT, failed-reload recovery, fuzzed reconciler, release
  load-safety, ABI-mismatch detection).
- The **five caveats** (`docs/guarantee.md` §2) are stated *first*: stack overflow, Hermes OOM, the
  ports/FFI boundary, `==` on values holding functions, raw host-side signals.
- `scripts/check-guarantee-doc.sh` (wired into `scripts/ci-test.sh`) fails the build if a cited file
  is deleted, a caveat is dropped, or the asterisks stop preceding the positive table.

## Reliability & compatibility impact

Defines the guarantee scope itself. No ABI/runtimeVersion change. Future changes to the scope require
a new RFC superseding this one.

## Alternatives considered

- *Leave it implicit.* Rejected: unfalsifiable + a credibility risk.
- *Claim "no crashes".* Rejected: false (see the caveats), and the first reproduced crash destroys trust.

## Risks & migration

The open caveat with the least coverage is #5 (raw host-side signals); closing it is tracked as REL-2
(NDK + iOS signal/Mach-exception handlers). Until REL-2 lands, `docs/guarantee.md` says so explicitly.

## Acceptance

- [x] `docs/guarantee.md` exists with positives (live citations) + the five caveats led-with.
- [x] `scripts/check-guarantee-doc.sh` is wired into `scripts/ci-test.sh` and passes.
- [x] README + external surfaces carry the caveats (no unqualified "no errors"/"cannot crash").
