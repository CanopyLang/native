# CMP-11 — RN-target version stamp in the bundle

| | |
|---|---|
| **Track** | compiler |
| **Status** | todo |
| **Effort** | ~1.5 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | CMP-8 (todo) |
| **Open blockers** | CMP-8 (todo) |
| **Source plan** | plans/10-competitor-master-plan.md |

Bake compiler version + Hermes bytecode version + CANOPY_ABI_VERSION into the CMP-8 container and add --rn-target=0.76.9 to select matched hermesc + shim set, with the host rejecting a mismatch.

**Notes:** Makes ABI breakage loud + the upgrade a single declared knob.
