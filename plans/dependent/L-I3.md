# L-I3 — RestoreEngine on iOS (Core ML / ANE)

| | |
|---|---|
| **Track** | ios |
| **Status** | partial |
| **Effort** | ~2.5 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | L-I1 (todo) |
| **Open blockers** | L-I1 (todo) |
| **Source plan** | plans/11-lumen-critical-path.md |

Compile CanopyRestoreEngineModule.mm, fix the dead CanopyMakeCoreMLRestoreModule weak-symbol, and convert/ship the Core ML model for the ANE restore path.

**Notes:** Weak-symbol now defined this session (CanopyRestoreEngineModule.mm) as compile-readiness, but actual on-device Core ML compile + model conversion/ship remain. Blocked on L-I1. Effort 2-3ew averaged.
