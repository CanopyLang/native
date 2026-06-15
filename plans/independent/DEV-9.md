# DEV-9 — Sub-second incremental rebuild

| | |
|---|---|
| **Track** | devloop |
| **Status** | todo |
| **Effort** | ~2 engineer-weeks |
| **Classification** | INDEPENDENT — no unmet dependency, safe to assign to a parallel agent now |
| **Depends on** | none |
| **Open blockers** | none — ready to start now |
| **Source plan** | plans/10-competitor-master-plan.md |

Deliver fast incremental IIFE relink in the compiler plus a warm compile-server in the tool with content-hash short-circuit, hitting single-file edit p50 <1s on a 10-module app.

**Notes:** THE throughput gate of the dev loop; risk entirely in the compiler. Negotiate the warm interface with the compiler workstream week 1; fall back to whole-program compile + warm process.
