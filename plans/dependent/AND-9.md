# AND-9 — Coalesce/backpressure Cmd/Sub completions

| | |
|---|---|
| **Track** | android |
| **Status** | todo |
| **Effort** | ~2 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | AND-8 (todo) |
| **Open blockers** | AND-8 (todo) |
| **Source plan** | plans/10-competitor-master-plan.md |

Batch parked callbacks within one frame into a single main-Looper post and add opt-in latest-wins backpressure per streaming module so high-freq streams stop competing with the UI thread.

**Notes:** Direct-views requires UI-thread mounts, so the win is coalescing not a 2nd thread.
