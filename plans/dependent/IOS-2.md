# IOS-2 — Triage first-compile error classes

| | |
|---|---|
| **Track** | ios |
| **Status** | todo |
| **Effort** | ~3 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | IOS-1 (todo) |
| **Open blockers** | IOS-1 (todo) |
| **Source plan** | plans/10-competitor-master-plan.md |

Work build.log top-down to resolve the JSI/UIKit/ARC/Swift-bridge errors in ~6k lines of never-compiled ObjC++ — the least estimable item in the plan.

**Notes:** High-variance debugging tail. Predicted hotspots listed in plan (makeHermesRuntime header path, Yoga gap APIs, ARC pointers in maps, jsi::Runtime& capture, weak_import/-ObjC linkage).
