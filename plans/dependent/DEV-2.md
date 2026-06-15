# DEV-2 — JS reload seam in native.js

| | |
|---|---|
| **Track** | devloop |
| **Status** | todo |
| **Effort** | ~2 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | DEV-3 (todo) |
| **Open blockers** | DEV-3 (todo) |
| **Source plan** | plans/10-competitor-master-plan.md |

Lift per-program state to module level and add __canopy_teardown/__canopy_captureState/__canopy_remount so native.js can tear down and re-mount onto the same root without a fresh process.

**Notes:** CanopyHostJni.reload() is a stub today. New harness/run-reload.js asserts 0 create for unchanged subtree + no stale handles.
