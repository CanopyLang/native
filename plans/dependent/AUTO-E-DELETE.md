# AUTO-E-DELETE — Phase E: delete hardcoded boot blocks + rewrite CONVENTIONS §6 + evolve gen-capability

| | |
|---|---|
| **Track** | autolinking |
| **Status** | todo |
| **Effort** | ~0.5 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | AUTO-D-JNI (todo), AUTO-D-CPP-STREAMING (todo) |
| **Open blockers** | AUTO-D-JNI (todo), AUTO-D-CPP-STREAMING (todo) |
| **Source plan** | plans/12-native-autolinking.md |

Remove CanopyHostJni.cpp:243-274 and CanopyModuleHost.mm:175-205, rewrite CONVENTIONS §6 from human-applied integration manifest to autolinked native manifest, and evolve gen-capability into a full self-contained package generator.

**Notes:** Plan Phase E (0.5wk). Blocked until every capability is package-resident (all of Phase D) and the generated registrant covers them, per the plan's sequencing.
