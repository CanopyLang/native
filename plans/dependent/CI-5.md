# CI-5 — Vendored-.so storage (LFS vs fetch-script)

| | |
|---|---|
| **Track** | ci |
| **Status** | todo |
| **Effort** | ~0.5 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | CI-1 (partial) |
| **Open blockers** | CI-1 (partial) |
| **Source plan** | plans/10-competitor-master-plan.md |

Use Git LFS for genuinely unobtainable blobs and scripts/fetch-vendor.sh for the 0.76.9 AAR set so a fresh clone is under 50MB.

**Notes:** 69MB vendored binaries bloat every clone. Plan dep CI-1 is partial (git tree created).
