# AND-8 — Reduce per-mutation JSON marshalling

| | |
|---|---|
| **Track** | android |
| **Status** | todo |
| **Effort** | ~2 engineer-weeks |
| **Classification** | INDEPENDENT — no unmet dependency, safe to assign to a parallel agent now |
| **Depends on** | AND-2 (done) |
| **Open blockers** | none — ready to start now |
| **Source plan** | plans/10-competitor-master-plan.md |

Instrument+bench on a physical arm64, then add an additive __fabric_updatePropScalar fast-path for text/value/opacity that bypasses JSON, keeping JSON as fallback for object/style props.

**Notes:** AND-2 dep is done. Measure first — dominant per-frame cost. CI regression-guards median frame cost.
