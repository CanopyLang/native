# L-I1 — iOS first compile + Hermes/JSI runtime wired

| | |
|---|---|
| **Track** | ios |
| **Status** | todo |
| **Effort** | ~3 engineer-weeks |
| **Classification** | INDEPENDENT — no unmet dependency, safe to assign to a parallel agent now |
| **Depends on** | none |
| **Open blockers** | none — ready to start now |
| **Source plan** | plans/11-lumen-critical-path.md |

Run ./scripts/remote.sh ios provision && ios all on a Mac, resolve first-compile ARC/ObjC++/JSI/Hermes-ABI errors, and wire jsi::Runtime* into the host so canopyEmitEvent fires.

**Notes:** Plan dep is 'a Mac' (a resource, not a work-item), so no unmet work-item dependency: parallelizable/startable now. Gate for all iOS work. Effort 2-4ew averaged. Scheduled to start today.
