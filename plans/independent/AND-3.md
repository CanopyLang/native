# AND-3 — __fabric_command ABI seam

| | |
|---|---|
| **Track** | android |
| **Status** | todo |
| **Effort** | ~1.5 engineer-weeks |
| **Classification** | INDEPENDENT — no unmet dependency, safe to assign to a parallel agent now |
| **Depends on** | none |
| **Open blockers** | none — ready to start now |
| **Source plan** | plans/10-competitor-master-plan.md |

Add one additive global __fabric_command(handle,name,argsJson) wired native.js -> CanopyFabric.cpp -> CanopyHostJni.cpp -> CanopyHost.java, with results returning async via emitEvent — foundational for AND-4.

**Notes:** MINOR additive change — do not bump CANOPY_ABI_VERSION. Reconcile with IOS-8's __fabric_callMethod to one seam.
