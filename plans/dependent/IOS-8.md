# IOS-8 — Shared imperative ABI (__fabric_callMethod)

| | |
|---|---|
| **Track** | ios |
| **Status** | todo |
| **Effort** | ~3 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | IOS-6 (todo) |
| **Open blockers** | IOS-6 (todo) |
| **Source plan** | plans/10-competitor-master-plan.md |

Add one generic __fabric_callMethod(handle,method,argsJson)->resultJson + CanopyHost::callViewMethod virtual on iOS and mirror on Android, reconciled with AND-3 into a single seam.

**Notes:** Imperative surface absent on BOTH platforms; cross-platform ABI change belongs in the parity DoD. Reconcile with AND-3.
