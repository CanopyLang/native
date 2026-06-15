# IOS-12 — iOS hot-path marshalling

| | |
|---|---|
| **Track** | ios |
| **Status** | todo |
| **Effort** | ~2.5 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | IOS-5 (todo) |
| **Open blockers** | IOS-5 (todo) |
| **Source plan** | plans/10-competitor-master-plan.md |

Measure with Instruments first; if marshalling dominates, read jsi::Object props directly in CanopyFabric.cpp or use a flat binary encoding, coordinating the shared encoding with AND-8/RND-7.

**Notes:** Same jsonStringify + NSJSONSerialization re-parse tax as Android. Measure first.
