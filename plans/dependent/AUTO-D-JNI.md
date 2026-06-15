# AUTO-D-JNI — Phase D: extract pure-JNI in-host modules into canopy/* packages

| | |
|---|---|
| **Track** | autolinking |
| **Status** | todo |
| **Effort** | ~2 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | AUTO-B-REG-ANDROID (done), AUTO-B-REG-IOS (todo), AUTO-C-ANDROID (done), AUTO-C-IOS (todo) |
| **Open blockers** | AUTO-B-REG-IOS (todo), AUTO-C-IOS (todo) |
| **Source plan** | plans/12-native-autolinking.md |

Move each pure-JNI Image/Photos/Album/etc. Java+ObjC++ module plus its in-core .can (Http, NetInfo, Battery, DeviceInfo, Brightness, Haptics, Platform, Vibration) into self-contained packages with native foreign import + manifest.

**Notes:** Plan Phase D (2-3wk, mechanical), pure-JNI ones first. Blocked: needs both Android+iOS registrant and build-include generation to land so extracted packages actually link on both platforms.
