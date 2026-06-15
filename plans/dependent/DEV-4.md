# DEV-4 — In-process reload entry point (Android)

| | |
|---|---|
| **Track** | devloop |
| **Status** | todo |
| **Effort** | ~1.5 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | DEV-2 (todo) |
| **Open blockers** | DEV-2 (todo) |
| **Source plan** | plans/10-competitor-master-plan.md |

Add a reload(bundleJs) JNI method that captures state, tears down, evaluateJavaScript(newBundle) reusing the same runtime, and re-boots with cached rootTag + captured state.

**Notes:** Today reload = force-stop + restart (multi-second, total state loss). Verify IIFE re-eval is idempotent; fall back to clean in-process reboot if not.
