# L-I2 — Capability parity on iOS

| | |
|---|---|
| **Track** | ios |
| **Status** | todo |
| **Effort** | ~2.5 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | L-I1 (todo) |
| **Open blockers** | L-I1 (todo) |
| **Source plan** | plans/11-lumen-critical-path.md |

Build and validate each .mm module (Photos/Album/Share/Storage/Notify/Image) on simulator/device to reach the lumen-probe gate set on iOS.

**Notes:** Blocked on L-I1 (iOS must compile + runtime wired first). Effort 2-3ew averaged. Note: CanopyImageModule.mm missing-import fix already landed as compile-readiness.
