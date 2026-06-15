# DEV-11 — Error overlay in the loop + reload-failure recovery

| | |
|---|---|
| **Track** | devloop |
| **Status** | todo |
| **Effort** | ~1 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | DEV-6 (todo), DEV-8 (todo) |
| **Open blockers** | DEV-6 (todo), DEV-8 (todo) |
| **Source plan** | plans/10-competitor-master-plan.md |

Wire {error} -> CanopyRedBox (auto-dismiss on next good bundle), keep the prior good tree after a failed reload, restore last-known-good state on next success, and pipe the WS map into __canopy_sourcemap.

**Notes:** Overlay + symbolication already exist; this wires them into the loop.
