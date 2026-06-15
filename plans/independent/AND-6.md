# AND-6 — Image: cache/lifecycle/error states/headers

| | |
|---|---|
| **Track** | android |
| **Status** | todo |
| **Effort** | ~2 engineer-weeks |
| **Classification** | INDEPENDENT — no unmet dependency, safe to assign to a parallel agent now |
| **Depends on** | AND-2 (done) |
| **Open blockers** | none — ready to start now |
| **Source plan** | plans/10-competitor-master-plan.md |

Add an LRU bitmap + DiskLruCache keyed by source+dims, sampleSize from Yoga frame, defaultSource, gated load/error events, and request headers so image feeds stop re-decoding and re-fetching.

**Notes:** AND-2 dep is done. Instrumented 200-row feed asserts bounded native heap + no duplicate fetches.
