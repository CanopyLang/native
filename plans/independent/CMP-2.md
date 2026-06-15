# CMP-2 — Land+test effect-manager reachability

| | |
|---|---|
| **Track** | compiler |
| **Status** | todo |
| **Effort** | ~1.5 engineer-weeks |
| **Classification** | INDEPENDENT — no unmet dependency, safe to assign to a parallel agent now |
| **Depends on** | none |
| **Open blockers** | none — ready to start now |
| **Source plan** | plans/10-competitor-master-plan.md |

Commit TreeShake.depsOf/managerFnDeps + CodeSplit/Analyze.hs change so TEA Cmd/Sub manager glue is not tree-shaken away under --optimize; add ManagerReachabilityTest.hs.

**Notes:** Factor the two managerFnDeps copies to one exported constant to stop drift.
