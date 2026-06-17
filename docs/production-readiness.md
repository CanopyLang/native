# canopy/native — Production-Readiness Audit (brutal, evidence-based)

> Date: 2026-06-17. Method: 6 parallel code-grounded audits, each re-checked by an independent
> skeptic (the multi-agent audit behind this doc). Verdicts cite `file:line` / CI run IDs, not
> comments. This file is the honest counterweight to the optimistic prose elsewhere in the repo.

## TL;DR verdict

**Not production-ready. canopy/native is a sophisticated, device-free-validated PROTOTYPE; Lumen is
not a shippable product; the restore model is a stand-in.** All three need substantial work — see
[`plans/PRODUCTION-ROADMAP.md`](../plans/PRODUCTION-ROADMAP.md) for the detailed implementation plan.

| Dimension | Verdict |
|---|---|
| Framework — reliability/runtime | **NOT READY** (strong correctness core; reliability *proof loop* absent) |
| Framework — platform/feature completeness | **NOT READY** (no real-device run ever; ~67%/60% coverage) |
| Lumen app | **NOT READY** (shell complete; monetization is fake; not a standalone app) |
| ML models | **NOT READY** (real plumbing, but a stand-in upscaler; product model doesn't exist) |
| Shipping / store | **NOT READY** (no signed AAB/.ipa ever built; procurement-gated) |
| CI honesty | **OVERSTATED** (green-on-main = a cron that skips every real job) |

## The one thing to internalize

As of this writing, **everything good described here lives on the `ios-first-light` branch, not on
`main`.** `origin/main` (`5a7b5cc`) is red on every push (the required `android-release` job
fail-closes on the unset `CANOPY_KEYSTORE_BASE64` secret) and has none of the iOS compile, crash
floor, `.hbc`, RTL, or KVM-emulator work. The only green runs on `main` are nightly `schedule` crons
that `skip` every build/test/device job. "Green CI" on main today proves only that caching works.

---

## 1. Framework — reliability / runtime correctness → NOT READY

**Real and enforced (credit where due):**
- `guardJsCall` catches `jsi::JSError` / `std::exception` at every JS↔host re-entry → red-box, not
  `std::terminate` (`host/android/app/src/main/jni/CanopyHostJni.cpp:164-176`). `_Native_safeDraw`
  wraps every draw (`package/external/native.js:1126`).
- Reconciler fuzzer: 6 invariants, seeded PRNG, depth-30/breadth-5000, LIS move-minimality, hard
  per-commit gate + a persisted 20-seed corpus (`harness/run-stress.js`, `harness/run-fuzz-corpus.js`).
- Capability/marshalling fuzz: 257 inputs, malformed JSON → structured `{code,message}`, never a
  throw (`harness/run-capability-fuzz.js`).
- The uncaught-crash floor (JVM `Throwable` / `NSException`) is correctly implemented, chains the
  prior handler, wired into boot (`MainActivity.java`, `AppDelegate.swift`). `docs/guarantee.md` is
  honest — leads with the caveats and is itself CI-enforced.

**Disqualifying gaps:**
1. **No crash-free metric, no telemetry sink.** REL-4/TEL-1 are comments. `drainPending` reads a
   crash record, logs it, then **deletes it** (`CanopyCrashFloor.java`, `.mm`) — no consumer.
   `scripts/check-crashfree-gate.sh` and `docs/telemetry.md` do not exist. Reliability is unmeasured
   on shipped builds. The crash floor writes breadcrumbs to `/dev/null`.
2. **Native SIGSEGV/SIGABRT below the JS boundary is uncaught** (no `sigaction`/Mach handler in
   `host/`; signal half of REL-2 deliberately deferred — defensible, but the framework's own
   "biggest hole" per `MASTER-PLAN.md`). `harness/run-host-fault.js` does not exist.
3. **iOS reliability is grep-asserted + runtime-unproven.** The crash floor/red-box iOS half has
   never executed a crash; `ios-appium-e2e` (the runtime boot→render→tap path) is advisory and has
   never been green. No real-device run feeds the (nonexistent) crash-free metric.

## 2. Framework — platform / feature completeness → NOT READY

- **RestoreEngine inference is REAL on both platforms** (not a stub): Android ONNX Runtime
  `session.Run` on a worker thread; iOS CoreML `predictionFromFeatures` on `MLComputeUnitsAll`,
  lazy `.mlpackage`→`.mlmodelc` compile. (The older "iOS process() is a TODO stub" note is stale.)
- **But the on-ANE prediction has literally never executed.** The only thing exercising it is an iOS
  UI test that has only run on the Simulator (no Neural Engine); `deviceTier` hardcodes `"ane"` with
  no probe. The "ANE super-resolution" claim is, today, a projection that has never run on the
  hardware it names.
- **Coverage: 67% capability (18/27), 60% component (12/20)** vs RN/Expo. Absent/high-priority:
  Camera, Location, Filesystem, RemotePush (no FCM/APNs — `Notify` is local-only). Partial:
  TextInputMultiline, RefreshControl, SafeAreaView, DeepLinks.
- **Parity is asserted, not enforced.** `scripts/check-compatibility-matrix.sh` derives the live
  capability set from the **Android** module dir only — an iOS-only regression or missing twin
  wouldn't fail CI. It can't even enumerate RestoreEngine (iOS `.mm`, Android C++).
- **Zero real-device validation, ever, on either platform.** Emulator (x86_64) / Simulator only.
  `device-farm-android/-ios` are `continue-on-error`, secret-gated, and have never run.

## 3. Lumen app → NOT READY

The TEA flow is complete and the pick→restore→compare→save happy path runs on an Android emulator.
But:
1. **The monetization is fiction.** A free user's saved photo is **byte-for-byte identical** to a
   paid user's: no watermark is baked into the file (it's an on-screen overlay only), no resolution
   cap is applied (`Album.save` writes the raw blob; `optionsFor` passes no cap — `RestoreEngine
   .Options` has no cap field). Billing **grants the lifetime unlock for free** whenever Play isn't
   configured (dev/CI/emulator/sideload). Nothing to sell, given away anyway.
2. **The OOM budget is dead code.** `Budget.can` (the guard meant to stop a 12MP restore from being
   `lmkd`-killed on a 3–4GB phone) is never called on the restore path — a crash risk on exactly the
   low-end devices the design says decide whether v1 ships. `deviceTier` is a hardcoded `"cpu"` stub.
3. **Not a standalone app.** No committed bundle (gitignored); no Lumen-specific signed Android/iOS
   project; runs as a JS payload inside the `org.canopy.echo` dev host. Three unreconciled bundle
   IDs: `org.canopy.echo` / `com.canopyhost.app` / `app.lumen`.

## 4. ML models → NOT READY

- **Real plumbing, but a stand-in model.** Both platforms ship a 240KB public **ESPCN luma-only 3×
  super-resolution** model (`super-resolution-10.onnx` / a matching 239KB CoreML conversion) — the
  code literally labels it a "STAND-IN". `restoreFaces` and `colorize` are **disabled no-ops**.
- **The product's headline promise is unmet.** "Bring old photos back to life." is backed by a
  generic sharpener — no face reconstruction, scratch removal, or colorization. Refund driver +
  plausible App Store 2.3.1 (misleading metadata) rejection.
- **The real model doesn't exist and has no commercially-clean off-the-shelf source.**
  CodeFormer/GFPGAN/RestoreFormer/GPEN weights are all non-commercial (FFHQ/StyleGAN2-NC); detectors
  are WIDER-FACE-tainted. A clean face-restore checkpoint must be self-trained (~1 week + an A100).
- **Quality has never been measured on a real photo.** No PSNR/SSIM/eval harness exists anywhere;
  the only test asserts the *output dimensions*. The fixture is a 400×400 synthetic JPEG.

## 5. Shipping / store → NOT READY

- **No signed Android AAB or iOS .ipa has ever been produced in CI.** `android-release` dies at the
  keystore-materialize step (unset `CANOPY_KEYSTORE_BASE64`); the assemble/verify/upload steps all
  skip. (The fail-closed guard is correct — it's just never been given a real key. The upload key
  is gitignored, not committed — but a public-password dev key exists in the working tree.)
- **iOS archive→.ipa→TestFlight self-skips** on the unset `APPLE_TEAM_ID` / ASC secrets.
- **CI builds `examples/counter`, not Lumen** (`compiler-pin.env`). No job compiles the Lumen app.
- **Procurement blockers (only the owner can clear):** Mac on Xcode 16, Apple Developer ($99/yr) +
  ASC API key, Google Play Console ($25) + a real upload keystore as secrets, a device-farm account
  (Firebase Test Lab / BrowserStack). Plus the Lumen model-license gate (self-train before submission).

## 6. CI honesty → OVERSTATED

- Every `push`/`pull_request` run on `main` is **red**; the only green runs are `schedule` crons that
  `skip` every real job. A green badge on main means "caching works."
- The ~13 iOS `check-ios-*.sh` steps inside `ci-test.sh` are **source-grep gates** — they prove text
  exists in a committed file; they do not compile, link, boot, or run anything.
- **Hidden failures:** `security-scan` (osv-scanner) reports HIGH-severity CVEs (e.g. `@xmldom/xmldom`
  CVSS 8.7, `axios`, `@appium/support`) in `e2e/package-lock.json` but is `continue-on-error` — a
  permanently-advisory, currently-red supply-chain gate.
- The perf gate is widened to 100% p50/p95 tolerance — it only catches gross O(n²) blowups.

---

## What "green on the branch" actually means (honest framing)

On `ios-first-light` the **required** device-free + build/test checks are green: the canonical gate
(`ci-test.sh`), `vendor-verify`, `abi-gate`, `bundle` (with a real `.hbc`), `ios-build`
(compile + 218 XCTest/XCUITest on the Simulator), and both Android **emulator** jobs (UIAutomator +
Appium counter smoke). That is real and worth having. It is **not** the same as production-ready:
no real device, no crash-free measurement, fake Lumen monetization, a stand-in model. "Required
checks green on an unmerged branch" ≠ "shippable".

See [`plans/PRODUCTION-ROADMAP.md`](../plans/PRODUCTION-ROADMAP.md) for the detailed plan to close
every gap above.
