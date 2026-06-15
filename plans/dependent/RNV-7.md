# RNV-7 — Ship real .hbc so bytecode-version is the gated contract

| | |
|---|---|
| **Track** | stability |
| **Status** | todo |
| **Effort** | ~2 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | RNV-2 (todo), RNV-3 (todo) |
| **Open blockers** | RNV-2 (todo), RNV-3 (todo) |
| **Source plan** | plans/10-competitor-master-plan.md |

Extend Bundle.hs/CMP-5 to pipe through matched hermesc -> .hbc, record the bytecode version in the manifest, and accept .hbc via isHermesBytecode(), keeping JS for dev.

**Notes:** Overlaps CMP-8. Mismatch -> fails at the RNV-2 gate.
