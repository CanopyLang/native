# RND-10 — Stress/fuzz suite

| | |
|---|---|
| **Track** | perf |
| **Status** | todo |
| **Effort** | ~1.2 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | RND-3 (todo) |
| **Open blockers** | RND-3 (todo) |
| **Source plan** | plans/10-competitor-master-plan.md |

run-stress.js: depth-30/breadth-5000 keyed trees, seeded random reorders, a structural oracle built independently of the walker, a diff-equals-rebuild invariant, and an O(n log n) scaling assertion.

**Notes:** Reconciler proven only on small examples today.
