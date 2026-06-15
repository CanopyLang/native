# IOS-4 — Confirm/harden Hermes/Yoga xcframework ABI match

| | |
|---|---|
| **Track** | ios |
| **Status** | todo |
| **Effort** | ~1 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | IOS-1 (todo) |
| **Open blockers** | IOS-1 (todo) |
| **Source plan** | plans/10-competitor-master-plan.md |

Assert resolved Hermes 0.76.9 in Podfile.lock, enforce the pod's jsi.h over the vendored copy, and add a boot-time ABI canary so a mismatched Hermes cannot silently corrupt at runtime.

**Notes:** iOS must consume the SAME Hermes 0.76.9 that Android pins. Document dual-platform re-vendor procedure.
