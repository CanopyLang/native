# CI-4 — Stack/Gradle/Pods caching

| | |
|---|---|
| **Track** | ci |
| **Status** | todo |
| **Effort** | ~1 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | CI-2 (todo), CI-3 (todo) |
| **Open blockers** | CI-2 (todo), CI-3 (todo) |
| **Source plan** | plans/10-competitor-master-plan.md |

Add actions/cache for ~/.stack and .stack-work plus SDK/~/.gradle/Pods/node_modules and a nightly cache-warm so a no-op second bundle run finishes under 5 minutes.

**Notes:** May need a self-hosted/larger runner (GitHub 10GB cache limit).
