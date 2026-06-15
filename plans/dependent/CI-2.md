# CI-2 — Reproducible patched compiler

| | |
|---|---|
| **Track** | ci |
| **Status** | todo |
| **Effort** | ~1.5 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | CI-1 (partial) |
| **Open blockers** | CI-1 (partial) |
| **Source plan** | plans/10-competitor-master-plan.md |

Commit the compiler repo and add it as a git submodule pinned to a SHA including CMP-1/2/3, with CI that stack-builds canopy onto PATH and verifies the IIFE bundle does not throw F7.

**Notes:** Depends on CI-1's compiler-pinning decision (still partial).
