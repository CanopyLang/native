# RNV-8 — Wire re-vendor + ABI gate into CI

| | |
|---|---|
| **Track** | stability |
| **Status** | todo |
| **Effort** | ~1.5 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | RNV-1 (todo), RNV-2 (todo), RNV-3 (todo), RNV-5 (todo) |
| **Open blockers** | RNV-1 (todo), RNV-2 (todo), RNV-3 (todo), RNV-5 (todo) |
| **Source plan** | plans/10-competitor-master-plan.md |

Add CI jobs vendor-verify (revendor.sh verify + grep-guard) and abi-gate (headless bytecode/VM assert), make android-release depend on them, and add a scheduled bump-check cron.

**Notes:** Converts 'a solo dev remembering to re-validate forever' into 'green or red.' A PR bumping only the Podfile -> CI red.
