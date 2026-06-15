# CMP-7A — Def-level column-precise source maps (Stage A)

| | |
|---|---|
| **Track** | compiler |
| **Status** | todo |
| **Effort** | ~1 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | CMP-6 (todo) |
| **Open blockers** | CMP-6 (todo) |
| **Source plan** | plans/10-competitor-master-plan.md |

Use Ann.Region start col for _mSrcCol and compute each def's generated column from the pretty-printer prefix, replacing the hard-coded _mGenCol=0 so red-box points at the right column.

**Notes:** Listed in plan as 'part of CMP-7'; Stage A delivers most of the value cheaply. Stage B is CMP-7B in P2.
