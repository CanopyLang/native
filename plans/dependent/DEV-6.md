# DEV-6 — Host dev client (debug-only WS)

| | |
|---|---|
| **Track** | devloop |
| **Status** | todo |
| **Effort** | ~1.5 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | AND-1 (done), DEV-4 (todo), DEV-5 (todo) |
| **Open blockers** | DEV-4 (todo), DEV-5 (todo) |
| **Source plan** | plans/10-competitor-master-plan.md |

Add a debug-only DevClient.java (okhttp) that turns bundle messages into reload(code) and error messages into CanopyRedBox, with auto-reconnect and a cleartext WS allowlist for localhost/LAN.

**Notes:** Plan lists dep DEV-1 which equals AND-1 (done). Stripped from release builds.
