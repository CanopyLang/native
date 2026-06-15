# DEV-12 — iOS dev-loop parity

| | |
|---|---|
| **Track** | devloop |
| **Status** | todo |
| **Effort** | ~2 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | DEV-4 (todo), DEV-6 (todo) |
| **Open blockers** | DEV-4 (todo), DEV-6 (todo) |
| **Source plan** | plans/10-competitor-master-plan.md |

Port the DEV-4 in-process reload to ObjC++ (re-eval into the same Hermes runtime, reuse root, same __canopy_* seams) and add an NSURLSessionWebSocketTask debug DevClient.

**Notes:** Gated on the iOS host compiling. Dev server + JS seams shared unchanged.
