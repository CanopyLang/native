# Shared cross-platform test-vector suite (IOS-9)

**The durable anti-drift control.** canopy/native has *two* hand-written hosts — the Android host
(`CanopyHost.java` + `com.facebook.yoga`) and the iOS host (`CanopyHostFabric.mm` + the Yoga pod).
They implement the *same* contract by hand, so they **will drift** (IOS-7 already proved divergence),
and today the only signal is a crash on a device. This suite makes drift a **CI failure** instead.

It is the native analogue of a golden test: **one** platform-neutral corpus of
`(component, props) → expected Yoga frame + style effect`, run against the **real Yoga** each host
links, on **both** platforms. A vector that is green on Android and red on iOS — or green at density 1
and red at density 3 — is exactly the silent divergence this suite exists to catch (master plan R5).

## The one source of truth

```
host/shared/test-vectors/
  layout-vectors.json     ← THE corpus. Edit ONLY this file.
  validate-vectors.js     ← device-free validator (an independent flexbox/CSS oracle)
  README.md               ← this file
```

`layout-vectors.json` has three vector sets, all in **logical units** (dp == points):

| set | asserts |
|---|---|
| `layoutVectors` | a view tree (`component` + `style` + `children`) and the **exact Yoga frame** (`left/top/width/height`) of every node. Covers fixed boxes, column/row flow, padding/margin insets, `flexGrow` distribution, `justifyContent` (incl. `space-between`), `alignItems`/`alignSelf`, `gap`, `%` dims, absolute positioning, `min/max` clamps, `display:none` collapse, and nested combinations. |
| `colorVectors` | the CSS color contract (`#rgb/#rgba/#rrggbb/#rrggbbaa` CSS-alpha-last, `rgb()/rgba()`, `hsl()`, named, `transparent`) the host `CanopyColor` must satisfy. |
| `styleEffectVectors` | the platform-neutral, non-Yoga style effects (opacity, uniform vs per-corner border-radius discrimination, border-width inset). |

## The deliberate divergence, normalized

The hosts disagree on **units on purpose** (contract §0.3):

- **Android** lays out in **physical pixels**: every input dim is `dp × density` (`CanopyHost.dp`),
  Yoga computes px, and frames are reported `÷ density`.
- **iOS** lays out in **points** with **no** density multiply (`dp == v`).

So the corpus is in **logical units** and each runner normalizes back to them before asserting:

- the Android runner **sweeps densities `1.0, 2.0, 3.0`** — multiplies inputs by density (exactly the
  host), lets real Yoga compute px, then divides frames back by density. Green across the sweep proves
  the host's px convention round-trips to the logical corpus with no gap.
- the iOS runner asserts the **points** frame directly (density 1). The two hosts reaching the **same**
  logical numbers is the parity proof.

All corpus dims are chosen integral under `×density` and `÷density` so neither host has a sub-pixel
rounding gap (Yoga's default config rounds to whole units).

## The two host runners (real Yoga, on device)

| host | runner | engine | run on |
|---|---|---|---|
| Android | `host/android/app/src/androidTest/java/com/canopyhost/CanopyLayoutVectorTest.java` | the real `libyoga.so` from the `com.facebook.yoga` AAR (the exact binary the host uses) | emulator / device (instrumentation) |
| iOS | `host/ios/Tests/CanopyHostCoreTests/CanopyLayoutVectorTests.mm` | the real Yoga pod (`<yoga/Yoga.h>`, the exact lib the host uses) | Simulator / device (XCTest) |

Each runner builds a **real Yoga tree** applying the host's style→Yoga mapping, runs
`calculateLayout` / `YGNodeCalculateLayout`, and asserts every node's normalized frame against
`expect`. The *layout* is therefore not a re-implementation — it is the same engine production uses.
(`CanopyColor` / the style mapping live as platform-private code in the hosts, so each runner carries a
small, reviewable reference of those pure rules; `check-cross-platform-vectors.sh` ties the references
to the production `applyStyle` so they cannot drift.)

The Android runner packages the corpus from `src/androidTest/assets/layout-vectors.json` — a copy kept
**byte-identical** to the canonical file by the gate. The iOS runner reads the canonical file directly
(bundled as a `CanopyHostCoreTests` resource via `project.yml`).

## How to run

### Device-free (Linux, every commit — in `scripts/ci-test.sh` step 26)

```bash
node host/shared/test-vectors/validate-vectors.js     # the independent oracle
bash scripts/check-cross-platform-vectors.sh          # the wiring + single-source + host-tie gate
```

The gate fails if: the corpus rots, the Android copy drifts from canonical, a runner stops loading the
corpus, or a geometric style key the corpus uses stops being handled by either host's `applyStyle`.

### Android (live emulator / device — REAL Yoga)

```bash
JAVA_HOME=$JDK ANDROID_HOME=$SDK host/android/gradlew -p host/android \
  :app:connectedDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.class=com.canopyhost.CanopyLayoutVectorTest
```

Validated on the project's x86_64 emulator: **2 tests, 0 failures, 0 errors**
(`layoutVectorsMatchAcrossDensities` across densities 1/2/3, `colorVectorsMatch` against the real
`CanopyColor`). When you add or change a vector, re-run this to lock the expected frames against real
Yoga; the emulator is the authoritative oracle.

### iOS (Mac / Simulator — REAL Yoga) — [MAC-REQUIRED, authored, not run here]

```bash
cd host/ios && xcodegen generate && pod install
xcodebuild test -workspace CanopyHost.xcworkspace -scheme CanopyHost \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:CanopyHostCoreTests/CanopyLayoutVectorTests
```

This is authored completely but **has not been compiled/run** in this environment (the iOS host needs
Xcode/UIKit/Hermes/Yoga, unavailable off macOS). Its device-free guarantees are: the corpus is proven
by the independent oracle **and** by the real-Yoga Android run, and the iOS runner issues the *same*
`<yoga/Yoga.h>` calls the host uses (asserted structurally by the gate).

## Editing the corpus

1. Edit **only** `host/shared/test-vectors/layout-vectors.json`.
2. Re-sync the Android test-APK copy (the gate prints this on drift):
   ```bash
   cp host/shared/test-vectors/layout-vectors.json \
      host/android/app/src/androidTest/assets/layout-vectors.json
   ```
3. `node host/shared/test-vectors/validate-vectors.js` — fix any frame the independent oracle rejects.
4. Run the Android instrumentation test to confirm against real Yoga (and lock new expected frames).
5. `bash scripts/check-cross-platform-vectors.sh` — must be green before commit.

Keep new dims integral under the density sweep (the validator enforces this).

---

# Before/After wipe-compositor parity suite (L-I4)

A second, sibling anti-drift control — same philosophy, different surface. The **C2 before/after
*wipe* compositor** is a hand-written native view on BOTH hosts (`BeforeAfterView.java` on Android,
`CanopyBeforeAfterView` in `CanopyHostFabric.mm` on iOS). They implement the same drag-the-seam
interaction by hand, so they will drift — but unlike layout, the drift is in small **pure numeric
rules**, not Yoga frames:

| rule | what it decides |
|---|---|
| `clampFraction` | the 0..1 clamp on the controlled wipe (== `Native.BeforeAfter.clamp01`) |
| `splitColumn` | `round(wipe*width)` — the clip/mask boundary column (an off-by-one is a 1px seam gap) |
| `dragFraction` | `clamp01(x/width)` — the finger→fraction map during a drag |
| `snapTarget` | `(wipe>=0.5)?0:1` — the end a double-tap snaps toward |
| `snapEased` / `snapValue` | `1-(1-t)^2` decelerate easing over the shared 260ms tween |
| `coverRect` | the center-crop "cover" geometry so the two layers register pixel-for-pixel |
| `commitPayloadJson` | the **exact** `{"fraction":<v>}` wire bytes the `wipeCommit` event carries |

## The single source of truth

Both hosts **delegate** every one of those rules to ONE place, so they cannot diverge:

```
host/shared/cpp/CanopyBeforeAfter.h    ← THE math. The iOS view calls canopy::beforeafter::* directly.
host/android/.../views/CanopyBeforeAfterMath.java
                                       ← the line-for-line Java twin; the Android view calls it.
```

The last row (`commitPayloadJson`) is the headline: the two hosts *previously* formatted the float
differently (Java `Float.toString` → `0.33333334` vs iOS `printf %g` → `0.333333`), so the SAME drag
emitted DIFFERENT wire bytes. The shared formatter (C `%g`, trailing-zeros stripped, mirrored exactly
in Java) removes that gap, and the corpus pins the bytes.

## The corpus + runners

```
host/shared/test-vectors/
  beforeafter-vectors.json         ← THE corpus (8 vector sets; unitless fractions, NO density term).
  beforeafter-vectors.schema.json  ← its schema.
  validate-beforeafter.js          ← device-free INDEPENDENT oracle (incl. a from-scratch %g formatter).
```

| host | runner | exercises | run on |
|---|---|---|---|
| Android | `host/android/app/src/test/java/com/canopyhost/views/CanopyBeforeAfterMathTest.java` | the REAL `CanopyBeforeAfterMath` the view delegates to | **JVM unit test** (`:app:testDebugUnitTest`) — runs on the build host, no emulator |
| iOS | `host/ios/Tests/CanopyHostCoreTests/CanopyBeforeAfterVectorTests.mm` | the REAL shared header `canopy::beforeafter::*` the view delegates to | Simulator/device (XCTest) — [MAC-REQUIRED, authored, not run here] |

There is **no density term** — the wipe is a fraction of the view, never a dp — so the same unitless
fractions validate both hosts (Android draws in physical px, iOS in points; a fraction-of-width is
unit-agnostic). The corpus is read from this canonical file by both runners (the iOS target bundles it
as a resource via `project.yml`; the Android JVM test reads it straight from `host/shared/test-vectors/`).

## How to run

```bash
# Device-free (Linux, every commit — ci-test.sh step 29):
node host/shared/test-vectors/validate-beforeafter.js   # the independent oracle (8 sets)
bash scripts/check-beforeafter-parity.sh                # the delegation + wiring + single-source gate

# Android (REAL production math, JVM — runs HERE, no emulator needed):
JAVA_HOME=$JDK ANDROID_HOME=$SDK host/android/gradlew -p host/android \
  :app:testDebugUnitTest --tests 'com.canopyhost.views.CanopyBeforeAfterMathTest'
#   → validated here: 8 tests, 0 failures (the production math reproduces every corpus vector).

# iOS (REAL shared header, Simulator) — [MAC-REQUIRED, authored, not run here]:
cd host/ios && xcodegen generate && pod install
xcodebuild test -workspace CanopyHost.xcworkspace -scheme CanopyHost \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:CanopyHostCoreTests/CanopyBeforeAfterVectorTests
```

## Editing the corpus

1. Edit **only** `host/shared/test-vectors/beforeafter-vectors.json`.
2. `node host/shared/test-vectors/validate-beforeafter.js` — the independent oracle must reproduce
   every expected value (and its `%g` formatter must agree with the corpus's payload strings).
3. Run the Android JVM unit test (above) to confirm against the real production math.
4. `bash scripts/check-beforeafter-parity.sh` — must be green before commit.

If you change a rule, change it in **both** `CanopyBeforeAfter.h` and `CanopyBeforeAfterMath.java`
(the gate's step 3 asserts both carry the rule, but it cannot compare their bodies — keep them twins).
