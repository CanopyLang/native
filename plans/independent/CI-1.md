# CI-1 — Keystore scrub + compiler version-control decision

| | |
|---|---|
| **Track** | ci |
| **Status** | partial |
| **Effort** | ~0.5 engineer-weeks |
| **Classification** | INDEPENDENT — no unmet dependency, safe to assign to a parallel agent now |
| **Depends on** | none |
| **Open blockers** | none — ready to start now |
| **Source plan** | plans/10-competitor-master-plan.md |

git rm --cached the release keystore, scrub history, store base64+passwords as secrets, ratify how the sibling compiler is pinned, and extend .gitignore for iOS Pods/DerivedData.

**Notes:** git tree created this session (init + commits on main). Remaining: keystore scrub/history rewrite, secrets wiring, compiler-pin decision, .gitignore extensions.
