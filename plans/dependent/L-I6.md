# L-I6 — E2E parity on iPhone

| | |
|---|---|
| **Track** | ios |
| **Status** | authored (Mac/device-gated run pending) |
| **Effort** | ~1 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | L-A6 (partial), L-I2 (todo) |
| **Open blockers** | L-A6 (partial), L-I2 (todo) |
| **Source plan** | plans/11-lumen-critical-path.md |

Add an XCUITest driver to run-e2e.mjs (testID -> accessibilityIdentifier) and run the same L-A6 lumen-restore spec green on a physical iPhone.

**Notes:** Blocked on both L-A6 (the spec) and L-I2 (iOS capabilities).

## Implemented (this session)

The SAME lumen-restore spine the Android L-A6 spec drives is now authored for iPhone, selecting ONLY
on `testID` → `accessibilityIdentifier`, with a device-free structural anti-drift net:

- **Native XCUITest spec** — `host/ios/Tests/CanopyHostUITests/CanopyLumenRestoreUITests.swift`. The
  iPhone twin of `e2e/lumen-restore.mjs`: one end-to-end test walking
  pick→restore→compare→share→save→loop, asserting the SAME testIDs (`choose`/`justfix`/`save`/`share`/
  `another`) + the SAME Lumen screen copy + the `Enhanced to N×N` inference proof. Runs on a **physical
  iPhone** (the deliverable proper), not just the Simulator. `XCTSkip`s with a reason when the embedded
  bundle is the counter (no silent pass). The iOS-specific edges (PHPicker, UIActivityViewController)
  are the only platform branches — exactly the Android picker/intentresolver counterparts.
- **The Appium spec is now platform-neutral** — `e2e/lumen-restore.mjs` builds caps via `caps.mjs`
  (the one platform fork) and branches the OS picker/share-sheet chrome by platform, so the SAME
  Appium spec runs on the **XCUITest Appium driver** too (it was Android-only — `adb`/`getCurrentPackage`).
- **Self-contained fixture** — `host/ios/Tests/CanopyHostUITests/Fixtures/lumen-test.jpg`,
  byte-identical to the Android canonical fixture (the same restore input on both platforms), seeded
  via `xcrun simctl addmedia` (the iOS twin of the Android gallery seed) by `run-matrix.sh` /
  `run-appium-ios.sh`.
- **Device-free gate** — `scripts/check-ios-lumen-e2e.sh` (step 30 of `scripts/ci-test.sh`, green on
  Linux): asserts the iPhone spec covers the whole spine by testID, asserts the SAME testIDs+copy as
  the Android Appium spec (parity, not aspiration), asserts the Appium spec is platform-neutral, and
  asserts the fixture stays byte-identical.
- **Run steps** — `host/ios/BUILD-AND-VALIDATE.md §5.8` (Simulator + physical-iPhone recipes),
  `e2e/README.md` (the Appium iOS path), `host/ios/PART5-LEDGER.md` (the XCUI-Lumen row).

**Verified here (Linux):** `scripts/check-ios-lumen-e2e.sh` green; full `scripts/ci-test.sh` green
(30/30); `check-portable-cpp.sh` green; all `.mjs` `node --check` clean; the Swift file is
brace/paren-balanced and shellcheck is clean on every touched script. **NOT verified here
(Mac/iPhone-gated):** the actual `xcodebuild test` of `CanopyLumenRestoreUITests` on a Simulator /
provisioned iPhone, and the Appium XCUITest run — no Mac/iPhone on this box. Still depends on a real
embedded Lumen bundle (L-A2) and the iOS capability set (L-I2) for a fully green device run.
