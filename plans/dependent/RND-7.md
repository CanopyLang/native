# RND-7 — Eliminate per-mutation JSON (batch -> maybe binary)

| | |
|---|---|
| **Track** | perf |
| **Status** | todo |
| **Effort** | ~2.5 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | RND-3 (todo), RND-4 (todo) |
| **Open blockers** | RND-3 (todo), RND-4 (todo) |
| **Source plan** | plans/10-competitor-master-plan.md |

Stage A batches the frame's mutations into one __fabric_applyBatch (one stringify/parse per frame); Stage B (only if measured) uses a flat typed mutation buffer read in C++ with no JSON.parse.

**Notes:** Keep mock-fabric green; mirror the additive ABI on iOS.
