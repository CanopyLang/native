# L-A0 — Re-confirm probe gates on a fresh emulator after the security + lazy fixes

| | |
|---|---|
| **Track** | lumen |
| **Status** | todo |
| **Effort** | ~0.2 engineer-weeks |
| **Classification** | INDEPENDENT — no unmet dependency, safe to assign to a parallel agent now |
| **Depends on** | none |
| **Open blockers** | none — ready to start now |
| **Source plan** | plans/11-lumen-critical-path.md |

Re-run ./scripts/remote.sh android all against examples/lumen-probe and screenshot each capability gate to confirm nothing regressed after AND-1/RND-1.

**Notes:** P0 item. No unmet deps (AND-1/RND-1 already landed), so startable now. Pure verification pass against the live probe.
