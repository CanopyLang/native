# AND-4 — focus/blur, measure, scrollTo/scrollToIndex

| | |
|---|---|
| **Track** | android |
| **Status** | todo |
| **Effort** | ~2 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | AND-3 (todo) |
| **Open blockers** | AND-3 (todo) |
| **Source plan** | plans/10-competitor-master-plan.md |

Implement the imperative ops over AND-3 dispatch: focus+IME, measure round-trip via getLocationInWindow + Yoga frame, and scrollTo/scrollToIndex resolving the child Yoga frame.

**Notes:** None of these exist today; focus/blur exist only as event names.
