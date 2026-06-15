# RND-3 — Deterministic JS-CPU timing harness

| | |
|---|---|
| **Track** | perf |
| **Status** | todo |
| **Effort** | ~1 engineer-weeks |
| **Classification** | INDEPENDENT — no unmet dependency, safe to assign to a parallel agent now |
| **Depends on** | RND-2 (done) |
| **Open blockers** | none — ready to start now |
| **Source plan** | plans/10-competitor-master-plan.md |

Build harness/bench.js with hrtime around cold render / warm diff / full reorder / lazy-stable diff (p50/p95/p99, --baseline regression fail), also run bytecode-compiled under vendored Hermes.

**Notes:** Zero timing data exists anywhere. RND-2 dep is done, so this is startable now.
