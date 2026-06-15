# CI-3 — Build the bundle FROM SOURCE in CI

| | |
|---|---|
| **Track** | ci |
| **Status** | todo |
| **Effort** | ~1.5 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | CI-2 (todo) |
| **Open blockers** | CI-2 (todo) |
| **Source plan** | plans/10-competitor-master-plan.md |

New CI bundle job that builds the pinned compiler + canopy-native, runs canopy-native build (release+dev), uploads bundle/map/manifest/generated as an artifact, and has android/ios jobs download it.

**Notes:** canopy.bundle.js is git-ignored so current CI cp's a file that doesn't exist on fresh checkout — both build jobs fail today. Assert APK bundle sha matches manifest.
