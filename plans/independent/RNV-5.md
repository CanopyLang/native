# RNV-5 — Freeze the RN coupling surface as a contract doc

| | |
|---|---|
| **Track** | stability |
| **Status** | todo |
| **Effort** | ~1 engineer-weeks |
| **Classification** | INDEPENDENT — no unmet dependency, safe to assign to a parallel agent now |
| **Depends on** | none |
| **Open blockers** | none — ready to start now |
| **Source plan** | plans/10-competitor-master-plan.md |

Write docs/rn-coupling.md enumerating the ~12 JSI calls + Hermes/Yoga/fbjni subset (grep-pinned to file:line) with a CI grep-guard that fails if a new jsi::/facebook::hermes:: symbol appears outside the allowlist.

**Notes:** Docs currently overclaim 'renders through Fabric' (false). Explicitly NO Fabric/RCTBridge/TurboModule.
