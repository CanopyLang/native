# L-A6 — E2E: lumen-restore flow green on emulator

| | |
|---|---|
| **Track** | lumen |
| **Status** | partial |
| **Effort** | ~1 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | L-A2 (todo) |
| **Open blockers** | L-A2 (todo) |
| **Source plan** | plans/11-lumen-critical-path.md |

Make the pick->restore->compare->save->share spec real in e2e/flows + run-e2e.mjs (select by testID) and run it green on the emulator via run-matrix.sh.

**Notes:** Appium + Maestro specs authored this session but not yet device/emulator-run. Needs the real app (L-A2) to run against. Blocked on L-A2.
