# CI-6 — Flip iOS CI to required + remote-Mac fallback

| | |
|---|---|
| **Track** | ci |
| **Status** | todo |
| **Effort** | ~1 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | CI-3 (todo), RB-1 (done) |
| **Open blockers** | CI-3 (todo) |
| **Source plan** | plans/10-competitor-master-plan.md |

Pin the working RN 0.76.9 pod set, remove continue-on-error from ios-build, document a remote-Mac fallback via remote-build.sh, and add XCUITest to the gate.

**Notes:** RB-1 dep is done; gated on CI-3.
