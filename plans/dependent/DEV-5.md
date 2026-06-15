# DEV-5 — Dev server: watcher + incremental rebuild + WS push

| | |
|---|---|
| **Track** | devloop |
| **Status** | todo |
| **Effort** | ~2.5 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | DEV-9 (todo) |
| **Open blockers** | DEV-9 (todo) |
| **Source plan** | plans/10-competitor-master-plan.md |

Node canopy-dev-server.js (chokidar+ws) watching *.can/native.js that debounces, runs canopy-native build, and pushes {bundle,map,buildId} or {error,report} over WebSocket, plus a run/dev subcommand.

**Notes:** No dev server/watcher/socket exists today; dev.sh polls inotify + full rebuild + adb-push.
