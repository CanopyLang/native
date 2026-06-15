# DEV-10 — Reload-diff perf gate

| | |
|---|---|
| **Track** | devloop |
| **Status** | todo |
| **Effort** | ~0.5 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | DEV-8 (todo) |
| **Open blockers** | DEV-8 (todo) |
| **Source plan** | plans/10-competitor-master-plan.md |

Add harness/run-reload-perf.js: a large keyed list with lazy rows where a reload changes one row asserts create/update count is O(changed) not O(N).

**Notes:** Hostage to RND-1 (done). Document the <1s budget assumes the lazy fix.
