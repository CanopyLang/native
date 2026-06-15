# RB-3 — Release-validation safety gate (remote)

| | |
|---|---|
| **Track** | remote |
| **Status** | todo |
| **Effort** | ~0.5 engineer-weeks |
| **Classification** | INDEPENDENT — no unmet dependency, safe to assign to a parallel agent now |
| **Depends on** | RB-2 (done), AND-1 (done) |
| **Open blockers** | none — ready to start now |
| **Source plan** | plans/10-competitor-master-plan.md |

cmd_run clears /data/local/tmp/canopy.bundle.js before a release install, and a CI security test pushes junk + asserts the baked bundle booted.

**Notes:** Both deps (RB-2, AND-1) are done, so this is startable now. Was red until AND-1's guard landed — now landed.
