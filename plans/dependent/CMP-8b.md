# CMP-8b — Minimal native bundle: DCE + prod source map

| | |
|---|---|
| **Track** | compiler |
| **Status** | todo |
| **Effort** | ~2.5 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | CMP-2 (todo), CMP-5 (todo) |
| **Open blockers** | CMP-2 (todo), CMP-5 (todo) |
| **Source plan** | plans/10-competitor-master-plan.md |

Decouple map emission from Dev/Prod (emit against renamed names, archive out-of-band) and gate/stub browser-only RuntimeDefs (window/document) for Hermes via an allowlist.

**Notes:** --optimize drops the map entirely -> release crashes unsymbolicatable. Assert no document/window refs + retained external map + size budget.
