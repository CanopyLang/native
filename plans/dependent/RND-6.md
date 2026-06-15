# RND-6 — Make Native.List genuinely skip off-window work

| | |
|---|---|
| **Track** | perf |
| **Status** | todo |
| **Effort** | ~1 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | RND-1 (done), RND-2 (done), RND-4 (todo) |
| **Open blockers** | RND-4 (todo) |
| **Source plan** | plans/10-competitor-master-plan.md |

Wrap each windowed row's renderItem in VirtualDom.lazy keyed by row data + offset so a scroll not crossing a row boundary diffs to ZERO host ops.

**Notes:** RND-1/RND-2 are done; gated on RND-4 (on-device instrumentation). Document stable-callback discipline. harness/run-list-perf.js.
