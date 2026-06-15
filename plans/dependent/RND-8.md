# RND-8 — (Conditional) Move JS off the UI thread

| | |
|---|---|
| **Track** | perf |
| **Status** | todo |
| **Effort** | ~2 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | RND-7 (todo) |
| **Open blockers** | RND-7 (todo) |
| **Source plan** | plans/10-competitor-master-plan.md |

Add a dedicated JS thread owning the runtime with __fabric_* marshalling view writes to the UI thread — only if RND-7 batching alone misses the perf bar.

**Notes:** Large architectural change. Descope to advisory if batching meets RND-9.
