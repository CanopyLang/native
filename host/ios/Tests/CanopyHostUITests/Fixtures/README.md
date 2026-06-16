# Lumen E2E fixtures (L-I6)

`lumen-test.jpg` — the canonical **400×400** draw-safe test photo the lumen-restore E2E uses as its
deterministic input. It is the **byte-identical copy** of the Android canonical fixture
`host/android/app/src/main/assets/lumen-test.jpg`, so the SAME image drives the restore on both
platforms (true cross-platform parity at the E2E layer). `scripts/check-ios-lumen-e2e.sh` asserts the
two stay identical, so they can never silently drift.

## Why this exact image

- **Small (≤512px)** so the restored output (a ~3× super-resolution pass) stays well under the
  on-screen `BeforeAfter` compositor's draw limit — a multi-megapixel source produces an output the
  comparator cannot draw. This is the same constraint the Android `lumen-restore.mjs` gallery fixture
  enforces (it clears oversized prior outputs and seeds a ≤512px photo).
- **Deterministic + newest-first**: seeded as the most-recent image so the picker's first cell is
  always this fixture, making the pick step reproducible.

## How it is used (NOT bundled into the test target)

It is seeded into the **Simulator/device photo library** before the run — the iOS twin of the Android
gallery seed (`adb` MediaStore touch + media-scan in `lumen-restore.mjs`):

```bash
xcrun simctl boot 'iPhone 15'
xcrun simctl addmedia booted host/ios/Tests/CanopyHostUITests/Fixtures/lumen-test.jpg
```

On a **physical iPhone**, add it to the device's Camera Roll once (AirDrop / Finder / `devicectl`)
before running `CanopyLumenRestoreUITests`. It is excluded from the `CanopyHostUITests` target sources
in `project.yml` (`Fixtures/**`) so it never bloats the test bundle.
