# AND-11 — Android instrumented-test + CI harness

| | |
|---|---|
| **Track** | android |
| **Status** | todo |
| **Effort** | ~2 engineer-weeks |
| **Classification** | INDEPENDENT — no unmet dependency, safe to assign to a parallel agent now |
| **Depends on** | none |
| **Open blockers** | none — ready to start now |
| **Source plan** | plans/10-competitor-master-plan.md |

Add an androidTest source set with UIAutomator + a multi-screen fixture app and a Gradle Managed Device wired into CI — the enabling substrate for every AND gate.

**Notes:** Repo has zero instrumented tests. Wire assembleDebug/assembleRelease/connectedCheck into CI against /home/quinten/android-tools.
