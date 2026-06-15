# L-I4 — Before/After on iOS + parity vectors

| | |
|---|---|
| **Track** | ios |
| **Status** | todo |
| **Effort** | ~1.75 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | L-A1 (done), L-I1 (todo) |
| **Open blockers** | L-I1 (todo) |
| **Source plan** | plans/11-lumen-critical-path.md |

Port the L-A1 compositor to a UIView subclass and add a shared platform-neutral test-vector suite so the two hand-written hosts can't silently drift.

**Notes:** Dep L-A1 is done but L-I1 (iOS compile) is not, so still blocked -> not parallelizable. Effort 1.5-2ew averaged.
