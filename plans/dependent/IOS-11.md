# IOS-11 — TestFlight pipeline

| | |
|---|---|
| **Track** | ios |
| **Status** | todo |
| **Effort** | ~1.5 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | IOS-10 (todo) |
| **Open blockers** | IOS-10 (todo) |
| **Source plan** | plans/10-competitor-master-plan.md |

exportArchive + notarytool/altool upload to an internal TestFlight group, driveable from Linux via a remote-build.sh release subcommand, validated on a Neural-Engine device.

**Notes:** 'Ships on both stores' litmus; validates the whole Release+signing chain on physical devices.
