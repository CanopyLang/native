# CMP-10 — Hermes stdlib gaps: Intl/regex/Date shims

| | |
|---|---|
| **Track** | compiler |
| **Status** | todo |
| **Effort** | ~4 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | CMP-4 (todo) |
| **Open blockers** | CMP-4 (todo) |
| **Source plan** | plans/10-competitor-master-plan.md |

Inventory kernel RuntimeDefs + stdlib FFI touching Date/Intl/RegExp, provide Hermes-targeted shims selected by the native target, and add a node-vs-headless-Hermes conformance suite.

**Notes:** Scope Intl to exactly what canopy/time + common formatting expose — error on the rest.
