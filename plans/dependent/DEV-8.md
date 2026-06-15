# DEV-8 — True state-preserving Fast Refresh + Model type-hash fallback

| | |
|---|---|
| **Track** | devloop |
| **Status** | todo |
| **Effort** | ~2 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | DEV-4 (todo), DEV-2 (todo) |
| **Open blockers** | DEV-4 (todo), DEV-2 (todo) |
| **Source plan** | plans/10-competitor-master-plan.md |

Compiler emits a deterministic structural Model type-hash as __canopy_model_typehash; reload remounts with captured state on equal hash, else fresh init + a 'Model changed' toast (no crash).

**Notes:** Load-bearing compiler dep (the type-hash emission). DEV-4 preserves position; this preserves state.
