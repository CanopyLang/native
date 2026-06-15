# AUTO-VIEWTAG — View-tag codegen: generate CanopyViewRegistry.register calls

| | |
|---|---|
| **Track** | autolinking |
| **Status** | todo |
| **Effort** | ~1 engineer-weeks |
| **Classification** | INDEPENDENT — no unmet dependency, safe to assign to a parallel agent now |
| **Depends on** | AUTO-B-SCAN (done) |
| **Open blockers** | none — ready to start now |
| **Source plan** | plans/12-native-autolinking.md |

Generate init-time CanopyViewRegistry.register(tag, factory) calls for every viewTags manifest entry, supplying the currently-unsolved seam where someone must still call register().

**Notes:** Part of plan section 4.4(b)/Phase B-C; DONE list lists 'view-tag (CanopyViewRegistry) codegen' as STILL TODO. Parallelizable: dep AUTO-B-SCAN is done; Android registry hook already exists, so startable now.
