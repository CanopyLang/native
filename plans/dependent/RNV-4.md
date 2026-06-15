# RNV-4 — Re-bind Hermes through the stable C-vtable ABI

| | |
|---|---|
| **Track** | stability |
| **Status** | todo |
| **Effort** | ~4 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | RNV-2 (todo), RNV-3 (todo) |
| **Open blockers** | RNV-2 (todo), RNV-3 (todo) |
| **Source plan** | plans/10-competitor-master-plan.md |

Wrap HermesABIRuntimeWrapper in CanopyHermes::makeRuntime and replace the 2 direct makeHermesRuntime callsites so a Hermes bump becomes a file swap behind a frozen C boundary.

**Notes:** The durable lever; hermes_abi.h is already vendored and unused. First verify nm -D libhermes.so exports get_hermes_abi_vtable (may need RNV-6's standalone Hermes).
