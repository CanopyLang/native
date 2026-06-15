# RND-4 — On-device frame instrumentation (Android)

| | |
|---|---|
| **Track** | perf |
| **Status** | todo |
| **Effort** | ~1.2 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | RND-3 (todo) |
| **Open blockers** | RND-3 (todo) |
| **Source plan** | plans/10-competitor-master-plan.md |

Wrap each CanopyFabric installFn with a ns timer feeding __canopy_perfDump, add a Choreographer frame-drop counter, and a perf-android.sh that drives a scripted fling and pulls dumps.

**Notes:** Guard timers behind CANOPY_PERF (compiled out of release). Label emulator numbers as upper-bound-on-jank.
