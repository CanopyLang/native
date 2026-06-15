# AUTO-B-REG-IOS — Generate iOS caps[]-equivalent registrant array fragment

| | |
|---|---|
| **Track** | autolinking |
| **Status** | todo |
| **Effort** | ~1 engineer-weeks |
| **Classification** | INDEPENDENT — no unmet dependency, safe to assign to a parallel agent now |
| **Depends on** | AUTO-B-SCAN (done) |
| **Open blockers** | none — ready to start now |
| **Source plan** | plans/12-native-autolinking.md |

Generate the iOS name+streaming-spec array fragment consumed by the existing registerAll loop, replacing the hardcoded NSArray at CanopyModuleHost.mm:175-205, wired additively.

**Notes:** iOS half of plan Phase B. DONE list explicitly lists 'iOS registrant/caps fragment generation' as STILL TODO. Parallelizable now: deps AUTO-A/B-SCAN are already done, so it is startable immediately.
