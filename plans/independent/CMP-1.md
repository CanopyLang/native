# CMP-1 — Land+test IIFE tree-shaker root-scan

| | |
|---|---|
| **Track** | compiler |
| **Status** | todo |
| **Effort** | ~1.5 engineer-weeks |
| **Classification** | INDEPENDENT — no unmet dependency, safe to assign to a parallel agent now |
| **Depends on** | none |
| **Open blockers** | none — ready to start now |
| **Source plan** | plans/10-competitor-master-plan.md |

Commit and test scanRuntimeIdents/scanArities/generatedIdentTokens in Generate/JavaScript.hs so the native IIFE bundle stops crashing 'F7 is not defined' / '_Platform_export is not defined'.

**Notes:** 135 uncommitted lines, untested. Native rides this unverified hack today. Add TreeShakeRootsTest.hs (golden+property+free-identifier regression).
