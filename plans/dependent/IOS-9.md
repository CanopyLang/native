# IOS-9 — Shared cross-platform test-vector suite

| | |
|---|---|
| **Track** | ios |
| **Status** | todo |
| **Effort** | ~2.5 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | IOS-6 (todo) |
| **Open blockers** | IOS-6 (todo) |
| **Source plan** | plans/10-competitor-master-plan.md |

Build a platform-neutral JSON corpus of (component, props, expected Yoga frames + style effects), run it on Android (JUnit) + iOS, and fail CI on divergence — the durable anti-drift control.

**Notes:** Two hand-maintained hosts WILL drift (IOS-7 proved they already do). Normalize the deliberate density/points divergence.
