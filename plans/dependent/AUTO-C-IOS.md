# AUTO-C-IOS — Generate iOS xcodegen/Podfile includes + Info.plist permissions

| | |
|---|---|
| **Track** | autolinking |
| **Status** | todo |
| **Effort** | ~1 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | AUTO-B-REG-IOS (todo) |
| **Open blockers** | AUTO-B-REG-IOS (todo) |
| **Source plan** | plans/12-native-autolinking.md |

Generate the xcodegen fragment / Podfile include packaging each native/ios directory (mirror use_native_modules!), append C++ podspec sources, and emit Info.plist permission keys.

**Notes:** iOS half of plan Phase C. DONE list lists 'iOS ... Podfile/xcodegen includes' as STILL TODO. Blocked on AUTO-B-REG-IOS (iOS boot/registrant wiring must exist first).
