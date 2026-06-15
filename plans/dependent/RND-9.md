# RND-9 — Ratify + prove the 'competitive' perf bar

| | |
|---|---|
| **Track** | perf |
| **Status** | todo |
| **Effort** | ~0.8 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | RND-5 (todo), RND-6 (todo) |
| **Open blockers** | RND-5 (todo), RND-6 (todo) |
| **Source plan** | plans/10-competitor-master-plan.md |

Ratify numeric gates (list jank <=1.2x RN, tap-to-paint median <= RN+4ms, cold TTI <=1.3x RN, no-op frame = 0 mutations, RSS <=1.5x RN) and encode them as assertions in bench-compare.sh.

**Notes:** Owner sign-off on multipliers. TTI gate depends on .hbc (CMP-8). Commit a perf ledger.
