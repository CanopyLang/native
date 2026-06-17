# canopy/native + Lumen — Production Roadmap (every missing implementation)

> Companion to [`docs/production-readiness.md`](../docs/production-readiness.md) (the brutal audit).
> This is the *how*: a deep-researched, sequenced plan to close every gap, with concrete designs,
> ordered steps, acceptance gates, and **honest** effort split into *device-free-now* vs
> *needs-resources* (Mac / Apple+Play accounts / real devices / a training GPU). Eng-weeks are for one
> focused engineer; CI-iteration overhead is included where it dominates.

## How to read this

Each workstream has an ID used in commit/task tracking. "Device-free now" = I can build + CI-gate it
on Linux today. "Needs resources" = blocked on procurement only the owner can do. The
**Resource checklist** at the bottom lists exactly what to buy/provision and what it unblocks.

## Summary + effort

| ID | Workstream | Verdict gap it closes | Device-free | Needs resources |
|----|-----------|----------------------|------------|-----------------|
| **CI-HONEST** | Make a green push *mean* something | CI overstated; main red on every push | ~1.25 wk | hosted CI minutes |
| **MODEL-v1copy** | Stop the misleading "bring back to life" claim | App Store 2.3.1 / refund risk | 0.25 wk | — |
| **LUMEN-EXPORT** | Real free/paid (baked watermark + res cap) + OOM guard | monetization is fake; OOM crash risk | ~2.3 wk | — (Play acct for real purchase) |
| **TEL** | Telemetry sink + crash-free metric | reliability unmeasured (records → /dev/null) | ~2.5 wk | a sink endpoint + devices for a real denominator |
| **CAP** | Capability/component breadth + 2-sided parity gate | 67%/60% coverage; iOS-blind gate | ~5–7 wk | Mac for iOS runtime; FCM/APNs accounts for push |
| **MODEL** | Clean SR model + eval harness, then the real restore | stand-in upscaler; quality unmeasured | ~4 wk (harness+clean SR) | **A100 ~1 wk** for face-restore; eval-set sourcing |
| **SHIP** | First signed store artifact (build Lumen, not counter) | no AAB/.ipa ever; app-id split | ~1.5–2 wk | **Apple $99, Play $25, keystore, Mac** |
| **DEV** | Real-device validation (the ANE has never run) | zero device runs; perf is projection | ~2.5 wk | **device-farm acct** (Firebase/BrowserStack) |
| **SIG** | Native SIGSEGV/SIGABRT crash floor | hard signals uncaught below JS boundary | ~2 wk author | devices+Mac to validate; flag-off until then |

**Total: ~22–26 device-free eng-weeks** + procurement + ~1 GPU-week (face-restore training). The
device-free 22–26 weeks is everything I can land + CI-gate without buying anything; it gets the repo
honest, the framework measured, Lumen genuinely sellable on Android, and the model honest. The store
submission, real-device proof, ANE validation, and the full "restore" model are the resource-gated tail.

---

## Phase 0 — Honesty + the sellable core (do now, device-free)

### CI-HONEST — a green push on `main` must be a true signal
**Gap:** every push to `main` is red (the required `android-release` job fail-closes on the unset
`CANOPY_KEYSTORE_BASE64`); the only green runs are `schedule` crons that skip every real job; ~13 iOS
checks in `ci-test.sh` are source-*grep* gates; `security-scan` is advisory + red with HIGH CVEs
(`@xmldom/xmldom` 8.7, `axios`, `@appium/support` in `e2e/package-lock.json`); the perf gate is
widened to 100%.
**Approach + steps:**
1. **Secret-presence gating** — add a `preflight` job that outputs `has_keystore` / `has_apple` /
   `has_asc` from `secrets != ''`; gate `android-release` (and the iOS archive/TestFlight steps) on it
   so a no-secret push goes **green-by-skip**, *without* weakening fail-closed when a secret IS set
   (the `device-farm-*` jobs are the existing template for this pattern).
2. **Triage the SEC-1 CVEs** — bump `e2e` deps (`@xmldom/xmldom`, `axios`, `@appium/support`) or
   allowlist with a documented rationale in `osv-scanner.toml`; then flip `security-scan` to required.
3. **Make the iOS truth real, not grepped** — wire the `ios-build` job result (it genuinely compiles
   + runs 218 XCTest/XCUITest on the Simulator) as the iOS signal; keep the `check-ios-*.sh` grep
   gates only as structural backstops, clearly labelled "source-shape only".
4. **Re-tighten the perf gate** to a real tolerance (e.g. p50 25% / p95 50%) once a stable baseline
   exists; until then label it honestly as "regression-smoke, not a perf bar".
5. **Reconcile contradictory provenance comments** (`ci.yml` "first green Mac run" vs "no Mac wired").
**Acceptance:** a normal push to `main` goes green on the device-free + Simulator jobs and skips
(not fails) the resource-gated ones; `security-scan` required + green. **Effort:** ~1.25 wk device-free.
**Deps:** coordinate with SHIP/DEV so secret-gating isn't reverted.

### MODEL-v1copy — stop claiming a restore the model can't do (immediate)
**Gap:** `app/src/Main.can:702` markets "Bring old photos back to life." over a luma-only 3× ESPCN
**stand-in** (no face/scratch/colorize). Refund driver + App Store 2.3.1 (misleading metadata) risk.
**Approach:** change the copy to a truthful super-res claim ("Sharpen & enhance old photos"); hide
`restoreFaces`/`colorize` UI behind a build flag until the real model ships (MODEL). **This is a
30-minute edit that removes the single biggest customer-deception risk** and should land before any
submission. **Acceptance:** no marketing string promises a capability the shipped model lacks.
**Effort:** 0.25 wk, device-free. **Deps:** none (unblocks an honest v1).

### LUMEN-EXPORT — make the free/paid distinction real (the watermark fix) + stop OOM
**Gap:** `Album.save` writes the **raw** restored blob (`Main.can:275`); the watermark is an
on-screen overlay only and the resolution cap is a status string — free and paid exports are
**byte-identical**. Billing also grants the unlock free off-Play (`fakePurchase`). `Budget.can`
(the OOM clamp) is **never called** on the restore path → crash risk on 3–4 GB phones.
**Approach (primitives already exist in `canopy/image`: `resize`, `decode`, `composite`,
`encodeToFile`):**
1. **Bake export — ✅ DONE (compile-verified; pixel-verify on device pending).** On save/share, when
   `not exportEntitled`: `Image.resize` the restored handle to `Budget.maxEdgePx` (genuine smaller
   file) → `Image.composite` the bundled `lumen-watermark.png` over it → `Album.save`/`ShareImage` the
   baked result; paid path saves the full-res, watermark-free handle. Implemented as a TEA async chain
   (`WatermarkLoaded`→`ExportResized`→`ExportComposited`→`finishExport`) with strict handle release
   (`releaseTemps`). Required the new **`Image.adopt`** (wrap the RestoreEngine blob int as an
   `ImageHandle`). Commits: `canopy/image` `75b5d7d`, host asset `6acc5fa`, Lumen `d1f9615`. **Remaining:
   an on-device run to confirm the free file is visibly watermarked + smaller (add the CI export-diff
   assertion in step 7), and move the asset into Lumen's own bundle when it goes standalone.**
2. **Engine cap (defence in depth)** — add a `maxEdge` field to `RestoreEngine.Options` and clamp the
   model output in `RestoreEngineModule.cpp` / `.mm` so the cap holds even before the bake.
3. **Wire `Budget.can`** into the restore path: call `Budget.wouldExceed`/`downscaleFactor` to clamp
   the source before the 9× super-res pass (prevents the documented `lmkd`/jetsam kill).
4. **Real deviceTier probe** (replace the hardcoded `"cpu"`/`"ane"` with a real NNAPI/ANE query).
5. **Real Play purchase validation** — exercise `launchBillingFlow`+acknowledge against a real
   product (the `[PLAY-CONSOLE-VALIDATE]` path); keep the fake-store only for dev, gated so a
   *release* build can never silently grant.
6. **Standalone signed Lumen app** — reconcile the 3 bundle IDs to one (`app.lumen`); v1 route: a
   Lumen Gradle flavor; v2: the build tool emits a per-app project.
7. **CI builds Lumen** — a job that builds + e2e-tests the Lumen bundle (not `examples/counter`) and
   **asserts the free vs paid export differ** (sha + a watermark-pixel probe).
**Acceptance:** a device-free CI assertion that the free export file ≠ the paid export file (watermark
present + dimensions capped); `Budget` clamp unit-tested. **Effort:** ~2.3 wk device-free (steps 1–4
+ 7); step 5 +0.5 wk needs a Play account; step 6 overlaps the build-tool workstream.
**Deps:** step 1 (engine cap) is the spine for the cap + OOM guard.

### TEL — telemetry sink + crash-free metric (make reliability measured)
**Gap:** the crash floor writes a buildId-keyed record then **deletes it** (`CanopyCrashFloor.java
:120`, `.mm:131`); no sink, no session denominator, no crash-free %, no `docs/telemetry.md`, no
`check-crashfree-gate.sh`.
**Approach:**
1. **One merged schema** (`docs/telemetry-schema.json`, `schema:2`): common envelope
   (`eventType ∈ {session-start,crash}`, `platform`, `buildId`, `appVersion`, `osVersion`,
   anonymous per-launch `sessionId`, `timestampMs`, `caveatTag`); `crash` adds
   `kind ∈ {jvm-uncaught,nsexception,native-signal}`, `errorClass`, `message`, `frames:[]`, `fatal`.
   Unify the divergent Android/iOS record fields.
2. **Session beacon** — mint `sessionId` once at boot; write a `session-start` event; thread the same
   `sessionId` into the crash record (the load-bearing new coupling → the crash-free denominator).
3. **Sink** (`CanopyTelemetrySink.{java,mm}`): default **on-disk ring buffer** (cap ~200, reuse the
   `pruneOldRecords` idiom); `drainPending` forwards to the sink *before* delete (fills the existing
   TODO). Opt-in HTTP POST (NDJSON, 5 s timeout) gated on a consent flag **AND** a
   `telemetryEndpoint` in the manifest — **zero network** otherwise (the asserted invariant).
4. **`harness/crashfree-report.js`** (mirrors `perf-report.js`): group by `(platform,buildId)`,
   `crashFree = 1 - distinct(sessionId with fatal)/distinct(sessionId)`, emit per-group rows + the
   explicit denominator + a `source` (emulator/device) caveat; `--selftest` proves the math
   device-free; `--gate --floor 99.0`.
5. **iOS native-frame offline symbolication** — extend `symbolicate-offline.js` with an `atos`-based
   Apple-crash pass (parser device-free unit-tested; live `atos` Mac-gated).
6. **`scripts/check-crashfree-gate.sh`** — schema-validate sample events + assert the computation.
**Acceptance:** device-free gate validates schema + crash-free math + the no-network-without-consent
invariant. **Effort:** ~2.5 wk device-free; an honest *published* crash-free number needs real
shipped-device sessions (DEV/SHIP). **Deps:** REL-2 (done for the JVM/NSException kinds), REPRO-1.

---

## Phase 1 — Breadth + first ship

### CAP — capability/component breadth + a 2-sided parity gate
**Gap:** 67% capability / 60% component; absent high-value: Camera, Location, Filesystem, RemotePush
(no FCM/APNs); the parity gate inspects the **Android** module dir only.
**Approach + ordered steps:**
1. **Gate fix first (device-free):** extract `lib/capability-discovery.sh` (union of host + package
   `native.json` module names); rewire `check-compatibility-matrix.sh` + a new
   `check-ios-capability-parity.sh` to assert "have ⇒ Android module ∧ iOS twin" — breadth can't
   silently regress (and it'll finally see RestoreEngine).
2. **Filesystem** capability (twinned; Android emulator-verifiable, iOS structural).
3. **Camera** (extend `Autolink.hs` for an `androidRes`/FileProvider manifest entry; clone Photos).
4. **Location** — first add **streaming scaffolding to `gen-capability`** (reusable: a
   `--streaming` flag emitting the `.can` subscription + `StreamingJniModule` Android + iOS twin),
   then fill Location + `play-services-location`.
5. **RemotePush** — FCM service + token/message streams (Android) + APNs `AppDelegate` seam + the iOS
   bridge; needs FCM/APNs accounts to validate end-to-end.
**Acceptance:** matrix coverage ~85%/80%; the parity gate fails on a missing iOS twin. **Effort:**
gate 0.5 wk; Filesystem 1; Camera 1.5; Location 2; RemotePush ~2 — mostly device-free authoring; iOS
runtime + push delivery need Mac/accounts. **Deps:** Camera/RemotePush extend the autolinker.

### MODEL — clean model stack + eval harness (then the real restore)
**Gap:** a 240 KB ESPCN **stand-in**; `restoreFaces`/`colorize` are no-ops; no clean face-restore
checkpoint exists; quality never measured.
**Approach + steps:**
1. (MODEL-v1copy above — honest copy first.)
2. **Swap ESPCN → Real-ESRGAN-compact** (BSD-licensed) as the v1 SR model: export a 4× ONNX with a
   fixed 512²-tile static shape; generalize `convert_restore.py`→`convert_coreml.py` to validate
   *declared* IO shapes (not ESPCN topology); tile (512² + 32 px overlap) in the engine. Device-free.
3. **Eval harness** (`metrics.py`/`score.py`/`report.py`: PSNR/SSIM + a no-caveat-share rubric;
   `eval-report.html`). Device-free.
4. **200-photo eval set** (strata + rights log + `PROVENANCE.md`) — sourcing effort.
5. **Baseline-score v1 SR** + a repo **license ban-list + `model-provenance.md`** (the release gate).
6. **int8 quantization** (`quantize_ort.py` per-channel QDQ; CoreML fp16+int8) + a real deviceTier probe.
7. **The real restore (the product):** face-restore must be **self-trained** (no commercially-clean
   off-the-shelf weights — CodeFormer/GFPGAN/etc. are all NC). Plan: dataset (clean-licensed +
   synthetic degradation), a small restoration net, ~**1 week on an A100**, int8, eval ≥ the share-bar;
   colorize via DDColor-tiny (Apache) / DeOldify (MIT). Then re-enable the `restoreFaces`/`colorize`
   UI + the honest "restore" copy.
**Acceptance:** the eval harness gates every model swap on PSNR/SSIM + share-rate on the 200-set; the
license ban-list gate blocks an NC checkpoint from shipping. **Effort:** ~4 wk for the clean SR +
harness + provenance (device-free) + eval-set sourcing; the from-scratch face-restore is a separate
~1 GPU-week + iteration. **Deps:** LUMEN-EXPORT (cap), DEV (on-device int8 quality).

---

## Phase 2 — Real-device, iOS ship, native crash floor (resource-gated)

### SHIP — first signed store artifact (Android internal track first)
**Gap:** no signed AAB/.ipa ever; CI builds `examples/counter`; 3-way app-id split; placeholder iOS
version.
**Approach + steps:** (1) parameterize the build to take an app dir (abs paths); (2) a CI job that
builds + signs **Lumen** + repoints the release artifact; (3) iOS privacy manifest; (4) the model-
license gate before any *public* submission; (5) app-id reconciliation + auto-incrementing version;
(6–8) provide the keystore/Apple/Play secrets → produce the signed AAB → Play internal track →
TestFlight. **Acceptance:** a signed Lumen AAB downloadable from CI + installed from the Play internal
track. **Effort:** ~1.5–2 wk device-free (steps 1–5) + ~1–1.5 wk once accounts exist. **Deps:**
LUMEN-EXPORT (build Lumen), MODEL (license gate).

### DEV — real-device validation (the ANE has literally never run)
**Gap:** emulator/Simulator only; `device-farm-*` never run; signed-release boot unvalidated on hardware.
**Approach + steps:** (1) hub-connection refactor + selftest; (2) provider decision (Firebase Test Lab
for Android, a wired Mac+iPhone or BrowserStack for iOS); (3) an `android-release-security` job +
local-adb wrapper for the RB-3 on-device boot assertion; (4) stabilize the KVM emulator path; then
(5) first-green real-device iteration → arm64 perf baseline + RN head-to-head → flip the gates from
advisory to required. **Acceptance:** a green real-arm64 run that boots the signed release, asserts the
crash floor + the **ANE** restore actually execute, and records the perf baseline. **Effort:** ~2.5 wk
device-free prep + ~3–4 wk + procurement. **Deps:** feeds TEL (real denominator), SIG (on-device
fault test), MODEL (on-device int8 quality).

### SIG — native signal crash floor (SIGSEGV/SIGABRT below the JS boundary)
**Gap:** no `sigaction`/Mach handler anywhere; a native fault is a silent kill.
**Approach + steps:** (1) a pure, async-signal-safe record formatter (`CanopySignalRecord.c`,
write()-only, no malloc) unit-tested via `harness/run-host-fault.js`; (2) Android `CanopySignalFloor
.cpp` (altstack + `sigaction` + save-prior + re-raise) behind `CANOPY_NATIVE_SIGNAL_FLOOR` (default
**off**); (3) iOS twin behind an Info.plist flag (must not break Apple's reporter / a future
PLCrashReporter — evaluate adopting Crashpad/Breakpad instead of hand-rolling); (4) extend
`check-crash-floor.sh` with the device-free async-safety + chain + flag-gate asserts + wire
`run-host-fault.js`; (5) on-device fault tests (`continue-on-error` until the farm is green); (6)
after farm-green, flip the flag on + update the `guarantee.md` host-signals caveat. **Acceptance:** an
injected SIGSEGV at the JSI/Yoga boundary yields a captured `native-signal` record + a clean
fast-fail (verified on a device), not a worse crash. **Effort:** ~2 wk to author device-free
(off-by-default) + device validation. **Deps:** REL-1, DEV (the on-device gate), feeds TEL.

---

## Resource checklist (only the owner can provide — and what each unblocks)

| Resource | Cost | Unblocks |
|---|---|---|
| Apple Developer Program + ASC API key | $99/yr | iOS archive → `.ipa` → TestFlight (SHIP); device-farm-ios |
| Google Play Console + an upload keystore (as the `CANOPY_*` secrets) | $25 once | signed AAB → internal track (SHIP); real Play purchase (LUMEN step 5) |
| A Mac on Xcode 16 (hosted runner already works; a wired Mac is the fallback) | — | iOS archive + on-device iOS validation (SIG/DEV iOS halves) |
| Device-farm account (Firebase Test Lab / BrowserStack) | ~usage | real-device validation, the ANE run, perf baseline (DEV); the crash-free denominator (TEL) |
| An A100 (rented) + a clean-licensed training set | ~1 GPU-week | the real face-restore model (MODEL step 7) — Lumen's actual value prop |
| FCM + APNs project | free | RemotePush end-to-end (CAP) |

## Suggested sequence (maximize honest value per week)

1. **Now (device-free):** CI-HONEST → MODEL-v1copy → LUMEN-EXPORT (watermark+cap+OOM) → TEL. *(Repo
   becomes honest; main green-on-push; Lumen genuinely sellable on Android; reliability measured.)*
2. **Cheap procurement ($124 + a keystore):** SHIP Android internal track + LUMEN real purchase +
   MODEL clean-SR + eval harness. *(First real install; honest super-res v1.)*
3. **Mac + device-farm:** DEV real-device + SIG signal floor + SHIP iOS/TestFlight + MODEL int8.
   *(iOS shippable; the ANE actually validated; crash-free published.)*
4. **GPU-week:** MODEL the real face-restore + colorize → re-enable the full "restore" + honest copy.
   *(The marketed product exists.)*
