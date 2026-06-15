# iOS CI — the Apple-toolchain gate (CI-6)

This page is the authoritative description of the **iOS** half of `.github/workflows/ci.yml`: the
`ios-build` job (build + XCTest + XCUITest on an Apple toolchain) and the `ios-remote-mac` fallback
job (drive a Mac you own over SSH). It records the **CI-6** work: pin the working RN 0.76.9 pod set,
put the XCUITest boot smoke in the gate, document a remote-Mac fallback, and — once a Mac runner
exists — flip the job to **required**.

> **Honest status (2026-06):** the iOS host has **never compiled** — there is no Mac (hosted or
> self-hosted) wired to this repo. The `ios-build` job is **authored + actionlint-clean** and is the
> CI home for the first green build, but it is **`continue-on-error: true`** (advisory, never red)
> until that first green run is pinned on a real Mac. Do **not** mark it required before then
> (CI-6 KEY NOTE). This page is the checklist for the flip.

---

## Why iOS needs a Mac at all

The iOS host is ObjC++/Swift/UIKit talking to Hermes + Yoga via JSI — only Xcode's `xcodebuild` can
compile it. The Linux dev box cannot. Everything else (the compiler, the JS bundle, the device-free
regression gate, the Android build) runs on Linux; iOS is the **one** platform whose host compile is
Apple-gated. So the iOS gate lives in CI on a macOS runner, not on the dev box.

The cross-platform JS bundle is **not** Apple-gated: it is built once on Linux by the `bundle` job
(CI-3) and handed to the iOS job as the `app-bundle` artifact, exactly like the Android jobs consume
it. The iOS job never builds the bundle itself.

---

## The pinned pod set (RN 0.76.9 — the load-bearing pin)

Hermes ships as the `hermes-engine` pod and Yoga as the `Yoga` pod, **both pinned to one React Native
release**. Pulling the matched trio from a single RN release is what guarantees the JSI
`Value`/`Runtime` ABI of the headers matches the linked Hermes binary (Risk #1 — a mismatch is a
silent crash). The pin is `host/ios/Podfile`:

```ruby
$RN_VERSION = '0.76.9'
```

This **must** equal Android's `hermes-android` pin (`host/android/.../cpp/CMakeLists.txt`) and
`host/vendor.lock.json`. The Linux `vendor-verify` job's `check-vendor-pins.sh` already grep-guards
that the Podfile, the C++ pin, the lock, and the Android CMake all agree. The iOS job adds a **second,
job-local** guard:

```yaml
- name: Guard — Podfile $RN_VERSION == the pinned pod set (RN 0.76.9)
```

It parses `$RN_VERSION` out of the Podfile and asserts it equals the `RN_VERSION` env this job
installs (`react-native@0.76.9`). A one-sided Podfile bump that the job didn't track turns this step
red **before** any pod install — so the installed Hermes/Yoga can never silently diverge from the
pin the job claims. The env `RN_VERSION` is the **one** source of truth in the job (the npm install
reads it), so the guard and the install can't drift either.

> **Bumping RN:** move **both** platforms together — the Podfile `$RN_VERSION`, the Android CMake
> `hermes-android` line, `host/vendor.lock.json`, and the `RN_VERSION` env in the iOS job — then
> re-run `pod install` so the ABI stays matched. The weekly `bump-check` job opens a tracking issue
> when upstream moves past the lock.

---

## What the `ios-build` job does (step by step)

| Step | What | Why |
|---|---|---|
| checkout / setup-node | runner bootstrap | Node for the RN npm install |
| **Guard — Podfile `$RN_VERSION`** | assert Podfile pin == job pin | fail closed on a one-sided bump |
| Cache node_modules + Pods + CocoaPods caches | keyed on Podfile + project.yml | `pod install` skips network on a hit |
| Install XcodeGen | `brew install xcodegen` | generate the `.xcodeproj` from `project.yml` |
| Bootstrap RN pods | `npm i react-native@$RN_VERSION` (cache-gated) | vends the matched Hermes + Yoga podspecs |
| Download `app-bundle` (CI-3) | the from-source bundle artifact | `canopy.bundle.js` is git-ignored — no committed copy |
| Stage bundle + assert manifest | `assert-bundle-manifest.sh` (`shasum -a 256`) | the staged bundle's sha256 == its manifest buildId |
| Generate project + install pods | `xcodegen generate && pod install` | writes `CanopyHost.xcworkspace` |
| **Build** (scheme `CanopyHost`) | `xcodebuild … build` | compile the app + the host static lib |
| **Test** (scheme `CanopyHost`) | `xcodebuild … test` | runs **both** test bundles — see below |
| Upload `ios-xcresult` | `actions/upload-artifact`, `always()` | failing test is diagnosable without a Mac |

### XCUITest is in the gate — via the scheme, not a target

The build/test use the **`CanopyHost` scheme** (defined in `project.yml`'s `schemes:`), not a bare
target. That is the load-bearing fix in CI-6: the scheme's `test:` action lists **both** test bundles —

- `CanopyHostCoreTests` — the renderer/bridge **XCTest** (`Tests/CanopyHostCoreTests/`), and
- `CanopyHostUITests` — the **XCUITest** boot smoke (`Tests/CanopyHostUITests/`): the app launches
  (booting Hermes, installing the `__fabric_*`/`__canopy_*` ABIs, evaluating `canopy.bundle.js`,
  mounting the program) and the test asserts it reaches `.runningForeground` and mounts a window with
  a non-zero frame. A red-box/SIGABRT anywhere in the native boot path fails it.

The previous job used `-scheme CanopyHostApp` (a **target**, which has no test action), so the
XCUITests never ran. Using the `CanopyHost` scheme gates them. The run writes a
`CanopyHost.xcresult` bundle (per-test logs + any UI-failure screenshots), uploaded on success **or**
failure.

---

## Two ways to run it on a Mac

### Fallback A — a self-hosted Mac registered as a runner (preferred)

Register a Mac with Xcode as a GitHub Actions self-hosted runner (Settings → Actions → Runners). It
advertises the labels `self-hosted`, `macOS`, and (Apple Silicon) `ARM64`. Then dispatch the workflow
re-targeting the iOS job to it:

```text
Actions → native-ci → Run workflow
  ios_runner = "self-hosted","macOS","ARM64"
```

`runs-on` reads that comma list (`fromJSON(format('[{0}]', inputs.ios_runner || '"macos-14"'))`), so a
plain push/PR keeps using the **hosted** `macos-14` runner and a dispatch can opt into the Mac you own.
The job body is identical on both runner kinds (`brew install xcodegen` is a no-op when XcodeGen is
already provisioned).

### Fallback B — a remote Mac over SSH (no runner registration)

If you can't register a runner but have a Mac with Xcode + **Remote Login** enabled, the `ios-remote-mac`
job drives it over SSH from a cheap Linux runner using `scripts/remote.sh ios` →
`host/ios/remote-build.sh` (the same harness the dev box uses). It is **opt-in** —
`workflow_dispatch` with `ios_remote_mac = true` — and **never** runs on a normal push/PR/schedule.

It downloads the `app-bundle` artifact, materializes the SSH key + `host/ios/.remote-build.env` from
secrets (all git-ignored paths), then runs `remote.sh ios provision` → `all` → `test`, pulling
`build.log` + `screen.png` + `canopy.log` + the test log back as the `ios-remote-mac-artifacts`
artifact. Required secrets:

| Secret | Contents | Default if unset |
|---|---|---|
| `MAC_SSH` | `user@host` of your Xcode Mac (e.g. `ci@mac.local`) | — (job errors out) |
| `MAC_SSH_KEY` | the **private** SSH key (PEM contents) for that Mac | use the agent/default key |
| `MAC_SSH_PORT` | SSH port | `22` |
| `MAC_REMOTE_DIR` | absolute checkout path on the Mac | `/Users/ci/canopy-ios-build` |

The same connection can be driven **locally** without CI:
`./scripts/provision-and-test.sh ios ci@<ip> -- examples/counter`.

---

## Flipping iOS to REQUIRED (the CI-6 finish line)

Do this **only after** the first green run on a Mac runner. It is the one remaining gated step.

1. Wire a Mac (Fallback A: register a self-hosted macOS runner; or keep the hosted `macos-14` runner
   and accept its cost).
2. Get a **green** `ios-build` run: the build compiles, `CanopyHostCoreTests` + `CanopyHostUITests`
   pass, and the `ios-xcresult` artifact shows no failures. Pin the toolchain that produced it
   (Xcode version, `macos-14` image SHA, or the self-hosted runner's Xcode).
3. In `.github/workflows/ci.yml`, set the `ios-build` job's `continue-on-error: false`.
4. In the repo's branch-protection rule for `main`, add **`iOS build + XCTest/XCUITest (Apple
   toolchain)`** to the required status checks.

Until step 2 lands, the job stays advisory (`continue-on-error: true`) so a missing Mac can never turn
the tree red. `ios-remote-mac` is **never** marked required (it is a manual, opt-in convenience).

---

## Honest scope — what is verified vs. not

- **Verified on the Linux dev box:** the workflow is **actionlint-clean** (`actionlint 1.7.7`); the
  RN-version pin guard parses `0.76.9` from the real `host/ios/Podfile`, agrees with the job's pin,
  and **fails on a simulated bump**; the `ios-remote-mac` SSH-config step is valid bash and writes a
  correct `.remote-build.env` (default port/dir applied when those secrets are empty); `.remote-build.env`
  is confirmed git-ignored. The device-free `ci-test.sh` gate is unaffected and stays green.
- **NOT verified here (Mac-gated):** the actual `xcodebuild` build, the XCTest/XCUITest runs, `pod
  install` against the pinned Hermes/Yoga, and the `remote-build.sh` SSH round-trip — there is no Mac
  on this box. The scheme-name fix (`CanopyHost`, was `CanopyHostApp`) is verified against
  `project.yml` but its on-Mac effect (XCUITests actually executing) is pending the first Mac run.
</content>
</invoke>
