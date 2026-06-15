# RND-11 — Per-commit perf regression gate

| | |
|---|---|
| **Track** | perf |
| **Status** | todo |
| **Effort** | ~0.8 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | RND-9 (todo), RND-10 (todo) |
| **Open blockers** | RND-9 (todo), RND-10 (todo) |
| **Source plan** | plans/10-competitor-master-plan.md |

Make ci-test.sh fail on >10% p95 regression via bench.js --baseline and add run-lazy/run-list-perf/run-stress as hard gates, mirrored into the iOS harness.

**Notes:** A measured bar is only credible if regressions fail the build.
