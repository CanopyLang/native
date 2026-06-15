# DF-1 — Device-farm strategy (real arm64 + real iOS)

| | |
|---|---|
| **Track** | ci |
| **Status** | todo |
| **Effort** | ~2 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | E2E-1 (todo) |
| **Open blockers** | E2E-1 (todo) |
| **Source plan** | plans/10-competitor-master-plan.md |

Pick Firebase Test Lab / AWS Device Farm / BrowserStack and run a nightly smoke + perf trace (atrace) artifact on real devices to validate the marshalling hot path + 60fps + store credibility.

**Notes:** iOS device farm needs the Apple Developer account.
