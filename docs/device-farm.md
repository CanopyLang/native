# Device farm — real arm64 Android + real iOS (DF-1)

This page is the authoritative description of the **real-device** leg of canopy/native's validation
matrix: the nightly **smoke + perf-trace** sweep on **physical arm64 Android** and **physical iOS**
hardware, the provider choice (Firebase Test Lab vs. AWS Device Farm vs. BrowserStack), and the CI
hooks that drive it (`device-farm-android` / `device-farm-ios` in `.github/workflows/ci.yml`, the
`scripts/df-*.sh` drivers).

It records the **DF-1** work: *pick a device farm, run a nightly smoke + perf trace (atrace) artifact
on real devices to validate the marshalling hot path + 60 fps + store credibility.*

DF-1 builds on **E2E-1** (the Android Appium smoke flow, `docs/ci.md` → `android-appium-e2e`) and
**E2E-2** (`docs/ci-e2e-ios.md` → `ios-appium-e2e`). Those two jobs run the **same** `smoke.mjs`
spec on an **emulator** (Linux KVM) and a **simulator** (Mac). DF-1 is the third leg: the **same spec
body again, unchanged**, but on **real arm64 silicon** in a managed device farm — because an
emulator/simulator is an **upper bound on jank, never a floor** (no GPU-compositor parity, no real
thermal/scheduler behaviour). The 60 fps and store-credibility claims are only honest on real glass.

> **Honest status (2026-06):** this leg has **never run** — no device-farm account (Firebase / AWS /
> BrowserStack) is wired to this repo, and the iOS leg additionally needs the Apple Developer account
> (signing). Everything here is **authored + actionlint/shellcheck-clean** and the artifacts it
> produces (`smoke.mjs`, the `perf-android.sh` frame-metrics dump, the `perf-report.js` gate) are
> **locally proven on the x86_64 emulator**. Both device-farm jobs are **`continue-on-error: true`**
> (advisory, never red) and **schedule/dispatch-only** (never on push/PR), gated on the provider
> secret being present — so a missing account can never turn the tree red or burn farm minutes on
> every PR. This page is the checklist for the flip to a real account.

---

## 1. Why a device farm at all (what the emulator/simulator cannot prove)

The e2e matrix (E2E-1/E2E-2) already runs the host end-to-end on an emulator and a simulator. Three
claims, all load-bearing for "a credible React Native competitor", are **unprovable** there:

| claim | why emulator/sim can't prove it | what the farm proves |
|---|---|---|
| **60 fps list fling** | x86_64/sim has no GPU-compositor parity and runs on a desktop scheduler — frame timings are an *upper bound on jank*, never a floor | a real arm64 Choreographer/CADisplayLink trace at the device's true refresh rate |
| **marshalling hot path is cheap** | JIT/host CPU is desktop-class; the JSI↔Yoga round-trip cost is masked | the AND-8 scalar-update fast path measured on a phone-class core |
| **store credibility** | reviewers run on real devices; a "passes on emulator" claim is not shippable evidence | a green run + a perf trace on the exact device classes the store reviews on |

DF-1 closes that gap with **one nightly sweep** per platform: the **same** Appium `smoke.mjs` (the
device-stack proof — launch → mount native views → tap → TEA update → reset) **plus** a **perf trace**
(the `perf-android.sh` Choreographer frame-metrics dump on Android; an `xctrace`/Instruments
`.trace` + frame summary on iOS), uploaded as a CI artifact so the 60 fps + hot-path numbers travel
with the build and are reviewable without a farm account.

---

## 2. Provider choice — Firebase Test Lab (Android) + BrowserStack (iOS), AWS Device Farm as the unified fallback

DF-1 names three candidates. The repo's existing shape (a black-box **Appium/WebdriverIO** spec that
already runs unchanged on both platforms via `e2e/caps.mjs`) makes the decision turn on **two**
questions: *does the provider run our existing Appium spec unchanged?* and *does it give us a real
perf trace artifact, not just pass/fail?*

| provider | Android | iOS | runs our Appium spec? | perf trace? | signing burden | verdict |
|---|---|---|---|---|---|---|
| **Firebase Test Lab** | ✅ real Pixel/Galaxy arm64 | ❌ no iOS | ✅ (`gcloud … run --type robo`/instrumentation; **Appium via the `androidx_test` + custom orchestrator**, or instrumented) | ✅ `--record-video` + **`--directories-to-pull` for our atrace dump** + Performance Metrics (CPU/mem/fps via the Firebase perf overlay) | none extra (debug APK) | **chosen for Android** — cheapest real-arm64, native artifact pull |
| **BrowserStack App Automate** | ✅ real arm64 | ✅ **real iPhone** | ✅ **native Appium** (`browserstack-node-sdk`, our `smoke.mjs` runs unchanged) | ⚠️ profiling = CPU/mem/fps charts (no raw `.trace`), pulled via the App Performance API | needs a **resigned** `.ipa` (BrowserStack resigns with its own profile) or an enterprise profile | **chosen for iOS** — the only one of the three with **real iPhones** + native Appium |
| **AWS Device Farm** | ✅ real arm64 | ✅ real iPhone | ✅ **Appium Node** test package (our spec packaged as a `.zip`) | ⚠️ built-in CPU/mem/fps + video; raw atrace via a custom test spec `artifacts:` block | iOS needs a signed `.ipa` (your Apple Developer cert) | **unified fallback** — one provider, both platforms, when you'd rather not run two accounts |

**The decision, and why:**

- **Android → Firebase Test Lab.** It is the cheapest path to **real arm64** (Google's own Pixels),
  it pulls **arbitrary files off the device** (`--directories-to-pull /sdcard/Android/data/...`),
  which is exactly how `perf-android.sh` already exports its frame-metrics JSON — so our **existing**
  perf artifact comes back **unchanged**, no provider-specific reshaping. The smoke flow runs as a
  black-box Appium session against the booted device (Test Lab's `gcloud` can host the device while a
  **self-driven** Appium server on the runner attaches over the reverse-tunnel, or via the
  instrumented path). Debug APK = **no signing**.
- **iOS → BrowserStack App Automate.** It is the only candidate that gives **real iPhones** *and*
  runs our **native Appium** `smoke.mjs` **unchanged** (the `browserstack-node-sdk` wrapper just
  points the WebdriverIO session at BrowserStack's hub — `e2e/caps.mjs` already emits XCUITest caps).
  It needs a **signed/resigned `.ipa`** → **this is the Apple Developer account gate** the plan flags.
- **AWS Device Farm → unified fallback.** If running two accounts is not worth it, AWS Device Farm
  does **both** platforms with one bill and one Appium-Node test package. We keep its driver
  (`scripts/df-aws.sh`) authored so the switch is a one-line provider flip, but it is **not** the
  default (its iOS path still needs your signing cert, and its perf is charts-not-`.trace`).

> The provider is a single env switch (`DF_PROVIDER=firebase|browserstack|aws`) read by the driver
> scripts, so swapping is a secret + a variable, never a workflow rewrite.

---

## 3. What the nightly sweep produces (the artifacts)

Each platform's job uploads **two** artifact families, both reviewable with no farm account:

1. **`df-<platform>-smoke`** — the Appium server log + screenshots + the device-farm session console
   URL (Firebase/BrowserStack/AWS each emit a web console link for the recorded video). This is the
   **pass/fail device-stack proof** on real silicon — the same `smoke.mjs` verdict as E2E-1/E2E-2,
   now on arm64.
2. **`df-<platform>-perf`** — the **perf trace**:
   - **Android:** the `perf-android.sh` Choreographer frame-metrics JSON (`frame-metrics.json`) +,
     when captured, the raw **`atrace`/Perfetto** `.pftrace`. `harness/perf-report.js` parses it,
     prints the jank ledger (jank% @ 1×/2×/4× refresh, p50/p95/p99 frame time), and runs the
     **relative regression gate** against a per-device-class baseline.
   - **iOS:** the `xctrace record --template 'Animation Hitches'` (or `Time Profiler`) `.trace` +
     a `frame-summary.json` distilled from it (hitch ratio, frame-time percentiles) by
     `scripts/df-ios-trace-summary.mjs`, gated by the same `perf-report.js` ledger shape.

Both perf artifacts carry the **same `caveat`/`abi` tags** the emulator dumps carry — except here the
tag reads `arm64` + `real-device`, so a reviewer (and the gate) can tell a **shippable** arm64 number
from an emulator upper bound. The DF perf gate is **relative to a recorded baseline per device class**
(`harness/perf-baselines/<device>.json`), never an absolute millisecond, for the same reason
`perf-report.js` and `perf-bar.js` are relative: only the **same hardware's** numbers are comparable.

---

## 4. The CI hooks — `device-farm-android` + `device-farm-ios`

Two jobs in `.github/workflows/ci.yml`, both **schedule/dispatch-only** and **`continue-on-error`**,
each gated on its provider secret so they self-skip cleanly when no account is wired:

| | `device-farm-android` | `device-farm-ios` |
|---|---|---|
| trigger | nightly DF cron (`41 3 * * *`) **or** manual dispatch (`device_farm=true`) | same |
| runner | `ubuntu-latest` (drives Firebase via `gcloud`; no Mac needed for Test Lab) | `ubuntu-latest` (drives BrowserStack over its hub; no Mac needed for App Automate) |
| gate | `if` requires `secrets.GCP_SA_KEY` (or `DF_PROVIDER`) to be present | `if` requires `secrets.BROWSERSTACK_KEY` (+ a signed `.ipa` from the Apple Developer account) |
| input | the `app-bundle` artifact (CI-3) + the **debug APK** (built from it, like `android-appium-e2e`) | the `app-bundle` + a **signed `.ipa`** (built on a Mac — see §6) |
| driver | `scripts/df-android.sh` (provider-dispatch → `df-firebase.sh` / `df-aws.sh`) | `scripts/df-ios.sh` (provider-dispatch → `df-browserstack.sh` / `df-aws.sh`) |
| smoke | `e2e/smoke.mjs` (unchanged — `caps.mjs` points WebdriverIO at the farm hub) | `e2e/smoke.mjs` (unchanged) |
| perf | `perf-android.sh` frame-metrics, pulled off the device | `xctrace`/`frame-summary.json` from the farm session |
| artifacts | `df-android-smoke` + `df-android-perf` (`always()`) | `df-ios-smoke` + `df-ios-perf` (`always()`) |

The job bodies mirror `android-appium-e2e`/`ios-appium-e2e` exactly (download bundle → stage → build),
then hand off to the **`scripts/df-*.sh`** driver instead of `run-appium-ci.sh` — so the only new code
is the farm-submission driver; the spec, caps, bundle staging, and artifact discipline are all reused.

### Why schedule/dispatch-only (not on every PR)

Real-device minutes cost money and queue. The e2e matrix (emulator + simulator) already gates **every
PR** for free; the device farm is the **nightly** confirmation on real glass + the perf-trace artifact
for store credibility. Running it per-PR would burn farm minutes for a signal the emulator already
provides. So DF jobs fire on the nightly DF cron and on an explicit `workflow_dispatch` only — the
same discipline the bump-check (weekly) and cache-warm (nightly) jobs use.

### Why `continue-on-error` (advisory until first green)

Identical reasoning to `android-appium-e2e`/`ios-build`: the farm leg has **never run** (no account),
so it cannot have a green run to require against. It is authored + lint-clean now; it flips to
**required** only after the first green real-device run is pinned (the §7 checklist). Until then it is
advisory so a missing/expired farm account can never turn `main` red.

---

## 5. How to run it (with a real account)

### Android — Firebase Test Lab

```bash
# one-time: a GCP project with Test Lab enabled + a service-account key (roles/firebase.testLab + storage)
gcloud auth activate-service-account --key-file="$GCP_SA_KEY"
gcloud config set project "$GCP_PROJECT"

# build the debug APK exactly as android-appium-e2e does (download the bundle, stage, assembleDebug),
# then submit the smoke + perf sweep on a REAL arm64 device:
DF_PROVIDER=firebase \
DF_DEVICE_MODEL=oriole DF_DEVICE_VERSION=34 \
APK=host/android/app/build/outputs/apk/debug/app-debug.apk \
  scripts/df-android.sh
```

`df-android.sh` (→ `df-firebase.sh`) submits the device session, runs `smoke.mjs` against it, triggers
the `perf-android.sh` fling capture, pulls the frame-metrics JSON via
`--directories-to-pull /sdcard/Android/data/org.canopy.echo/files/perf`, and runs
`perf-report.js --baseline harness/perf-baselines/oriole.json` to gate the trace. Artifacts land in
`df-out/android/`.

### iOS — BrowserStack App Automate

```bash
# one-time: a BrowserStack App Automate plan + a SIGNED .ipa (Apple Developer account — see §6)
export BROWSERSTACK_USERNAME=... BROWSERSTACK_ACCESS_KEY=...

DF_PROVIDER=browserstack \
DF_DEVICE='iPhone 15' DF_OS_VERSION=17 \
IPA=host/ios/build/CanopyHost.ipa \
  scripts/df-ios.sh
```

`df-ios.sh` (→ `df-browserstack.sh`) uploads the `.ipa`, opens a WebdriverIO session pointed at the
BrowserStack hub (`caps.mjs` emits the XCUITest caps unchanged), runs `smoke.mjs`, pulls the App
Performance (CPU/mem/fps) series, distils it into `frame-summary.json`, and gates it with
`perf-report.js`. Artifacts land in `df-out/ios/`.

> The hub session is driven through **`browserstack-node-sdk`** (it routes the WebdriverIO session to
> the BrowserStack cloud so `smoke.mjs` runs unchanged). That is the **one** new e2e dependency the
> iOS DF leg needs — add it to `e2e/package.json` devDependencies (`npm i -D browserstack-node-sdk`)
> when wiring the BrowserStack account. Until it is installed, `df-browserstack.sh` self-skips with
> exactly that instruction, so the missing dependency is never a crash.

> Android and iOS are **separate accounts/providers**; each writes its own `df-out/<platform>/`
> ledger. There is no cross-provider merge step — each platform's perf gate stands alone against its
> per-device baseline (a Pixel arm64 number is never compared to an iPhone number).

---

## 6. The Apple Developer account gate (iOS only)

The iOS device-farm leg is the **one** piece that needs more than a farm account: a **signed `.ipa`**.
BrowserStack/AWS install a real app on a real iPhone, which Apple requires be **code-signed**. The
options, cheapest first:

1. **BrowserStack resigning** — upload an `.ipa` built with a development profile; BrowserStack
   resigns it with its own provisioning profile for its device pool. Still needs a base signing
   identity (a free or paid Apple ID development cert).
2. **Your Apple Developer Program cert** ($99/yr) — build a properly-signed `.ipa` on the Mac runner
   (the `ios-build` job's toolchain) with `xcodebuild -exportArchive`, upload that. Required for AWS
   Device Farm and for any TestFlight/store path.

Until a signing identity is wired, `device-farm-ios` self-skips (its `if` requires
`BROWSERSTACK_KEY`), so the missing Apple account never blocks the Android leg or the tree. Building
the signed `.ipa` is a Mac step (no Mac on this box) — it reuses the `ios-build` job's `xcodebuild`
toolchain plus an `-exportArchive` step; the exact commands are in §7's flip checklist.

---

## 7. Flipping the device farm to REQUIRED (the DF-1 finish line)

Do each platform **independently**, only **after** its first green real-device run.

### Android (Firebase Test Lab)

1. Create a GCP project, enable **Test Lab**, mint a service-account key with `roles/firebase.testLab`
   + Cloud Storage object admin. Add it as the **`GCP_SA_KEY`** secret and `GCP_PROJECT` repo var.
2. Get a **green** `device-farm-android` run: the debug APK installs on a real Pixel (`oriole`/arm64),
   `smoke.mjs` passes (launch → `Count: 0` → `~increment` → `Count: N` → `~reset` → `Count: 0`), and
   `perf-android.sh`'s frame-metrics JSON comes back with jank% under the baseline. **Record the
   per-device baseline** (`harness/perf-baselines/oriole.json`) from that first clean run.
3. Set `device-farm-android`'s `continue-on-error: false`.
4. Add **`Device farm — Android smoke + perf (real arm64) — DF-1`** to `main`'s required checks.

### iOS (BrowserStack App Automate)

1. Wire the **Apple Developer** signing identity (§6) and a BrowserStack App Automate plan. Add
   **`BROWSERSTACK_KEY`** (+ `BROWSERSTACK_USER`) secrets.
2. Build a **signed `.ipa`** on the Mac runner (`ios-build` toolchain + `-exportArchive`), upload it
   (the `ios-app-ipa` artifact), and get a **green** `device-farm-ios` run: the `.ipa` installs on a
   real iPhone, `smoke.mjs` passes (the same spine), and the App Performance series yields a
   `frame-summary.json` under the iPhone baseline (`harness/perf-baselines/iphone-15.json`).
3. Set `device-farm-ios`'s `continue-on-error: false`.
4. Add **`Device farm — iOS smoke + perf (real iPhone) — DF-1`** to `main`'s required checks.

Until each platform's step 2 lands, its job stays advisory + schedule/dispatch-only — a missing or
expired farm/Apple account can never turn the tree red. This is the same flip discipline as
`android-appium-e2e` (E2E-1), `ios-appium-e2e` (E2E-2), and `ios-build` (CI-6).

---

## 8. Honest scope — what is verified vs. not

- **Verified on the Linux dev box / in this sandbox:**
  - the **smoke spec** (`e2e/smoke.mjs`) runs **green on the live x86_64 emulator** (the device-stack
    proof; the farm runs the identical body on arm64 — only `caps.mjs`/the hub URL differs);
  - the **perf trace** pipeline runs device-free: `harness/perf-report.js --selftest` proves the
    frame-metrics parser + the relative regression gate, and `perf-android.sh` is the exact capture
    the farm triggers (proven against the live emulator, `--no-build`);
  - the **driver scripts** (`scripts/df-android.sh`, `scripts/df-ios.sh`, `scripts/df-firebase.sh`,
    `scripts/df-browserstack.sh`, `scripts/df-aws.sh`, `scripts/df-ios-trace-summary.mjs`) are
    **shellcheck/node `--check`-clean** and self-skip with a clear message when their provider
    CLI/secret is absent (so they are safe to invoke on this box);
  - the **workflow** (`.github/workflows/ci.yml`, both DF jobs) is **actionlint-clean**
    (`actionlint 1.7.7`).
- **NOT verified here (account-/Mac-gated):** the actual Firebase Test Lab / BrowserStack / AWS Device
  Farm **submission** and the **real-device** install + run — there is **no farm account** wired to
  this repo, and the iOS leg additionally needs the **Apple Developer** signing identity and a **Mac**
  to build the `.ipa`. The provider command shapes are written against each provider's documented CLI
  (`gcloud firebase test android run`, `browserstack-node-sdk`, `aws devicefarm`), and the spec/perf
  bodies are proven against a green emulator run + the `perf-report.js` self-test respectively, but
  their **on-real-device execution is pending the first account-backed run** (the §7 flip checklist).
