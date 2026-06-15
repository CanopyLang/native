# IOS-10 — iOS Release archive (signing/ATS/entitlements)

| | |
|---|---|
| **Track** | ios |
| **Status** | todo |
| **Effort** | ~2 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | IOS-6 (todo) |
| **Open blockers** | IOS-6 (todo) |
| **Source plan** | plans/10-competitor-master-plan.md |

Add a CONFIG=Release device path (xcodebuild archive + automatic signing), verify -ObjC/-Os doesn't dead-strip weak-loaded registrations, add an ATS exception, and flip aps-environment to production.

**Notes:** Gated on a paid Apple Developer account. iOS analog of AND-2.
