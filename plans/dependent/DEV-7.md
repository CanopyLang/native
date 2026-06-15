# DEV-7 — Connect-by-IP (Wi-Fi / remote box)

| | |
|---|---|
| **Track** | devloop |
| **Status** | todo |
| **Effort** | ~1 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | DEV-6 (todo) |
| **Open blockers** | DEV-6 (todo) |
| **Source plan** | plans/10-competitor-master-plan.md |

Add run --host <ip>/--lan that skips adb reverse, bakes the dev server's LAN IP into CANOPY_DEV_HOST, and binds WS to 0.0.0.0 so the loop works over LAN, not just USB/emulator.

**Notes:** The owner's box often runs remote; a Metro-class loop must work over LAN.
