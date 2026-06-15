# DEV-3 — Runtime state seam in runtime.js

| | |
|---|---|
| **Track** | devloop |
| **Status** | todo |
| **Effort** | ~1.5 engineer-weeks |
| **Classification** | INDEPENDENT — no unmet dependency, safe to assign to a parallel agent now |
| **Depends on** | none |
| **Open blockers** | none — ready to start now |
| **Source plan** | plans/10-competitor-master-plan.md |

Install an inert-unless-requested _Platform_live {getModel,setModel,managers} + _Platform_shutdown (kills Subs) gated on a dev flag, exposing the single var model closure for state-preserving reload.

**Notes:** Must verify scanRuntimeIdents (CMP-1) keeps these generator-only symbols; add to runtime-roots if dropped. Without shutdown a reload double-subscribes.
