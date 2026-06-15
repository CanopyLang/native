# L-A5 — Asset + memory budget pass

| | |
|---|---|
| **Track** | lumen |
| **Status** | partial |
| **Effort** | ~1.5 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | L-A2 (todo) |
| **Open blockers** | L-A2 (todo) |
| **Source plan** | plans/11-lumen-critical-path.md |

Fit the ~59MB ORT .so + ESPCN model into the AAB size budget (in-AAB vs Play Asset Delivery, drop unused ORT providers) and keep multi-MP restore under the RSS budget on a Tier-C device.

**Notes:** Partially advanced this session via noCompress + per-ABI splits (L-A5-partial); ORT delivery decision, model packaging confirmation, and peak-RSS measurement/tiling remain. Blocked on L-A2. Effort 1-2ew averaged.
