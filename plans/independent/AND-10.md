# AND-10 — Crash symbolication + release map archival

| | |
|---|---|
| **Track** | android |
| **Status** | todo |
| **Effort** | ~1 engineer-weeks |
| **Classification** | INDEPENDENT — no unmet dependency, safe to assign to a parallel agent now |
| **Depends on** | AND-2 (done) |
| **Open blockers** | none — ready to start now |
| **Source plan** | plans/10-competitor-master-plan.md |

Archive the JS map (even under --optimize) + R8 mapping.txt keyed to buildId and build an offline symbolicator reusing __canopy_symbolicate, with a CI test that throws from a known .can line + Java method.

**Notes:** AND-2 dep is done. Release emits no map + R8 obfuscation -> unreadable crashes today.
