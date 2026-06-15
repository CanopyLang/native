# CMP-8 — Hermes .hbc emission + versioned bundle container

| | |
|---|---|
| **Track** | compiler |
| **Status** | todo |
| **Effort** | ~3 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | CMP-5 (todo), CMP-8b (todo) |
| **Open blockers** | CMP-5 (todo), CMP-8b (todo) |
| **Source plan** | plans/10-competitor-master-plan.md |

Post-emit hermesc (version-matched) to app.hbc + bytecode map in a versioned container (magic + bundle/bytecode/ABI version) the host rejects on mismatch, with a JS-source dev fallback.

**Notes:** Plain JS today -> slow cold start + source in APK. Fast TTI is a competitiveness gate. CI runs hermesc + asserts .hbc loads in headless Hermes.
