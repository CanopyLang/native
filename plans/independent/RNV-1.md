# RNV-1 — vendor.lock.json + provenance

| | |
|---|---|
| **Track** | stability |
| **Status** | todo |
| **Effort** | ~1 engineer-weeks |
| **Classification** | INDEPENDENT — no unmet dependency, safe to assign to a parallel agent now |
| **Depends on** | none |
| **Open blockers** | none — ready to start now |
| **Source plan** | plans/10-competitor-master-plan.md |

Record source/version/sha256/date per vendored artifact, generate it from actual files, and add revendor.sh verify with a corrupt-byte test that fails loud — prerequisite for every later ABI gate.

**Notes:** Vendored .so + headers + pod pins have no provenance/checksums today.
