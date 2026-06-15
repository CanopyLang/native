# RNV-2 — Boot-time + CI Hermes/JSI ABI gate

| | |
|---|---|
| **Track** | stability |
| **Status** | todo |
| **Effort** | ~1.5 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | RNV-1 (todo) |
| **Open blockers** | RNV-1 (todo) |
| **Source plan** | plans/10-competitor-master-plan.md |

At boot read getBytecodeVersion + VM version and compare to a value baked from vendor.lock.json; mismatch -> red-box (debug)/fatal (release), with a matching headless CI step.

**Notes:** No check today that linked libhermes matches its JSI headers — boots on emulator, SIGABRTs on a user's arm64.
