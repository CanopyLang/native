# CMP-9 — Fast Refresh codegen for the native IIFE

| | |
|---|---|
| **Track** | compiler |
| **Status** | todo |
| **Effort** | ~5 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | CMP-5 (todo), CMP-7A (todo) |
| **Open blockers** | CMP-5 (todo), CMP-7A (todo) |
| **Source plan** | plans/10-competitor-master-plan.md |

Factor the existing ESM HMR body to format-agnostic and emit __canopy_hmr.register(moduleId,{init,update,view,subscriptions},modelHash) for the IIFE, reusing hashCanType for the model-compat gate.

**Notes:** Largest codegen item. Plan dep is CMP-7 generally; mapped to CMP-7A. Co-design the WS patch wire format with the dev-loop track.
