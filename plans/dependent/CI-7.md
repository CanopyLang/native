# CI-7 — Reconcile canonical CI app + unify gates

| | |
|---|---|
| **Track** | ci |
| **Status** | todo |
| **Effort** | ~0.5 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | CI-2 (todo), CI-3 (todo) |
| **Open blockers** | CI-2 (todo), CI-3 (todo) |
| **Source plan** | plans/10-competitor-master-plan.md |

Make ci.yml gate call ci-test.sh after CI-2 puts canopy on PATH (closing the canopy test gap), pick one canonical app for bundle/e2e/smoke, and add run-symbolicate.js to the gate.

**Notes:** ci-test.sh and ci.yml run different harness subsets today; 'green' is ambiguous.
