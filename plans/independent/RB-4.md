# RB-4 — One-command provision-and-test <IP>

| | |
|---|---|
| **Track** | remote |
| **Status** | todo |
| **Effort** | ~1 engineer-weeks |
| **Classification** | INDEPENDENT — no unmet dependency, safe to assign to a parallel agent now |
| **Depends on** | RB-1 (done), RB-2 (done) |
| **Open blockers** | none — ready to start now |
| **Source plan** | plans/10-competitor-master-plan.md |

scripts/provision-and-test.sh <platform> <user@ip> writes the env from the IP, builds the bundle locally, dispatches to the platform harness provision && all, and prints the pulled screen.png + canopy.log.

**Notes:** The owner's literal ask. Both deps (RB-1, RB-2) are done, so this is startable now. Unify env naming.
