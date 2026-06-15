# RNV-6 — Decouple cadence: pin Hermes+Yoga ourselves

| | |
|---|---|
| **Track** | stability |
| **Status** | todo |
| **Effort** | ~3 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | RNV-3 (todo), RNV-4 (todo) |
| **Open blockers** | RNV-3 (todo), RNV-4 (todo) |
| **Source plan** | plans/10-competitor-master-plan.md |

Spike standalone-Hermes-release + Maven/pod Yoga vs AAR extraction, verify standalone libhermes exports the C-ABI vtable, and record the pin-2x/year decision in docs/rn-coupling.md.

**Notes:** Owner's explicit decision point. No Fabric -> no reason to ride RN's train. iOS stays on the pod path until proven on Mac.
