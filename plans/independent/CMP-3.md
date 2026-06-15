# CMP-3 — Land+test installed-version resolver

| | |
|---|---|
| **Track** | compiler |
| **Status** | todo |
| **Effort** | ~1 engineer-weeks |
| **Classification** | INDEPENDENT — no unmet dependency, safe to assign to a parallel agent now |
| **Depends on** | none |
| **Open blockers** | none — ready to start now |
| **Source plan** | plans/10-competitor-master-plan.md |

Commit PackageCache.resolveInstalledVersion + call sites so canopy test/package builds stop collapsing every constraint to lowerBound; add ResolveTest.hs.

**Notes:** 51 lines, untested. Preserve empty-cache lowerBound fallback. Golden the canopy init scaffold against New.hs/Setup.hs version bumps.
