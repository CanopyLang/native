# CMP-6 — Fix source-map generated-line base for IIFE/native

| | |
|---|---|
| **Track** | compiler |
| **Status** | todo |
| **Effort** | ~2 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | CMP-1 (todo) |
| **Open blockers** | CMP-1 (todo) |
| **Source plan** | plans/10-competitor-master-plan.md |

Seed State.outputLine with the newline count of everything prepended before innerBytes (runtime + capability registry) so dev red-box line numbers are correct, not off by the whole runtime.

**Notes:** Confirmed bug. Do before/with CMP-5.
