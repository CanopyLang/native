# Phase 4 — Execution Progress

> Execution ledger for [`09-phase4-ecosystem.md`](09-phase4-ecosystem.md) (Ecosystem, OTA & DX).
> Everything below is **implemented and device-validated on Android** (emulator, API 34) unless
> marked otherwise. iOS legs are authored-on-Linux and gated on a Mac build (see the campaign notes).

## Status at a glance

| Item | Plan ref | Status | Proof |
|---|---|---|---|
| Source-maps end-to-end | DX M0 / Obs M0 | ✅ device-validated | red-box shows `Main.can:25` / `Native.Css.can:91` |
| Content-hashed asset manifest | OTA M0 / Build M1 | ✅ device-validated | boot logs `bundle integrity OK — buildId f5b9db14e544` |
| Bytes-blob JNI bridge | Capability M0 | ✅ device-validated | `blob bytes bridge self-test: OK` |
| Frozen extension ABI | Escape-hatch M0 | ✅ | `CanopyAbi.h` compiles portable; `__canopy_abi_version=1` ships |
| Pure-`.can` navigator | Navigation M0 | ✅ device-validated | push `Open 1 → Detail 1`, pop `← → Home` |
| **gen-capability codegen** | Capability M1 | ✅ device-validated | generated `Vibration` ran on device |
| **Capability fan-out** | Capability M2+ | ✅ device-validated | Battery/DeviceInfo/NetInfo/Haptics/Brightness real data |
| **HostComponent registry** | Escape-hatch M1+M2 | ✅ device-validated | third-party `RatingBar` mounts, zero host-switch edit |

---

## 1. Starter tickets (the M0 substrate)

### 1.1 Source-maps end-to-end (DX M0 / Observability M0)
Four layers, all authored on Linux:
- **Compiler** (`compiler/packages/canopy-core/src/Generate/JavaScript.hs`): the emitted map was a
  skeleton (`sources:[]`, hardcoded `srcIndex 0`). Added `State._smSrcIndices`; `emitMapping` threads
  each `Opt.Global`'s home `ModuleName` → per-mapping `srcIndex` via `resolveSrcIndex`; `buildSourceMap`
  populates `_smSources` (renders `<Module>.can`). Map now lists **14 real `.can` modules**.
- **Build tool** (`tool/src/Canopy/Native/Bundle.hs`, `Build.hs`): `compiledLineOffset` (=45,
  golden-pinned), `shiftSourceMap` (prepend N `;` = exact preamble shift), `stripSourceMapRef`;
  `finishBundle` writes an aligned `canopy.bundle.js.map`, embeds it as `globalThis.__canopy_sourcemap`
  (bare Hermes can't fetch the sibling `.map`), and appends the trailer. Golden tests in `tool/test/Spec.hs`.
- **Runtime** (`package/external/native.js`): `_Native_symbolicate` (VLQ decode + per-genLine index +
  nearest-preceding lookup) installed as `__canopy_symbolicate`. Node-tested (`harness/run-symbolicate.js`).
- **Host** (`host/android/.../jni/CanopyHostJni.cpp`): `symbolicateStack()` (best-effort JSI call) wired
  into `guardJsCall`'s catch before the red-box.

**Proof:** `examples/redboxtest` (Debug.todo on tap) → red-box renders `at $author$project$Main$boom (Main.can:25)` /
`at A2 (Native.Css.can:91)` instead of bundle offsets. *Granularity is per-global/line-level (genCol=0);
sub-line precision is a future refinement.*

### 1.2 Content-hashed asset manifest (OTA M0 / Managed-build M1)
- `tool/src/Canopy/Native/Assets.hs` — `AssetEntry`/`AssetManifest`, `sha256Hex` (via `cryptohash-sha256`),
  `buildId = sha256(bundle)`.
- `Config.hs` — `+ncRuntimeVersion`, `+ncAssets`.
- `Build.hs/finishBundle` — writes `canopy.manifest.json` + env-gated deploy to `CANOPY_HOST_ASSETS`
  (`copyIfChanged`, skips on matching sha).
- `MainActivity.verifyBundleIntegrity` — sha-checks the booted bundle vs the manifest.
- The bundle is now git-ignored build-output (`host/android/app/src/main/assets/.gitignore`).
- Enabled `buildFeatures { buildConfig true }` (for `BuildConfig.DEBUG`).

**Proof:** boot logs `bundle integrity OK — buildId f5b9db14e544` (a hand-`cp` of a stale bundle now
surfaces as a loud mismatch).

### 1.3 Bytes-blob JNI bridge (Capability M0)
- `jniBlobPutBytes(jbyteArray)` / `jniBlobGetBytes → jbyteArray` in `host/shared/cpp/CanopyJni.{h,cpp}`
  (Blob `kind="bytes"`, reuses `globalBlobRegistry`) + `Java_..._nativeBlobPutBytes/GetBytes` exports.
- `CanopyBlobs.java` — `nativeBlobPutBytes/GetBytes`, `putBytes/getBytes`, `selfTest()`.

**Proof:** `blob bytes bridge self-test: OK` (a real put→get→release byte-array round-trip). Non-bitmap
binary (Http bodies, file reads, tensors) now moves as int handles, not base64.

### 1.4 Frozen extension ABI (Escape-hatch M0)
- `host/shared/cpp/CanopyAbi.h` — `CANOPY_ABI_VERSION = 1`, `CanopyViewRef`, abstract `CanopyViewFactory`
  (`tag/create/applyProps/reset/isLeaf`), the frozen `__fabric_*` / `__canopy_*` surface, and a semver
  survival rule.
- `native.js` installs `__canopy_abi_version = 1` at boot.
- `docs/extension-abi.md` — the published contract.

### 1.5 Pure-`.can` navigator (Navigation M0)
- `navigation/src/Native/Navigation/Stack.can` — `Config route msg {screen,title,back}` +
  `stack : Config -> NavStack route -> Node msg` (header row with a back chevron when `!isRoot`, over the
  current screen). Built over `canopy/native` + `canopy/css` (added the `canopy/css` dep + exposed the module).

**Proof:** `examples/navtest` (Home → Detail) — on device, **push** (`Open 1 → Detail 1`) and **pop**
(`← → Home`) both work. *The back chevron sits in the emulator's left-edge gesture zone; taps need
3-button nav.*

---

## 2. Deep milestones

### 2.1 `gen-capability` codegen — the fan-out spine (Capability M1)
The #1 ecosystem deficit was that every native capability is a 3–5-file hand-build (why breadth stalled
at ~12% of Expo). Now it's one command.
- `tool/src/Canopy/Native/CapabilityCodegen.hs` — `CapabilitySpec{capName,capMethods}` +
  `renderCanModule` / `renderJavaModule` / `renderBootLine` / `renderMockEntry`.
- `Main.hs` — `canopy-native gen-capability <Name> --methods m1,m2 [--out DIR]`.

Emits from ONE spec: a `Native.<Name>.can` effect module (`NM.call` Task wrappers), a `<Name>Module.java`
JniModule dispatcher skeleton, the C++ boot line, and a harness mock. One-shot capabilities (streaming is later).

**Proof:** generated `Vibration` (`vibrate,cancel`); placed the **as-generated** `.can` (compiled +
integrated into `examples/captest` with zero edits); hand-filled **only** the Java `Vibrator` body; on
device tapping BUZZ → `dispatch module=Vibration method=vibrate` → `Vibration.vibrate(200ms) — generated
capability ran` → Task resolved → "Buzzed N times".

### 2.2 Capability fan-out (uses the codegen)
Scaffolded the Expo-comparable set with `gen-capability` (one command each), filled the Android bodies via
a 5-agent parallel workflow, and wired them (exposed modules, boot lines, `ACCESS_NETWORK_STATE` perm).

| Capability | Methods | On device (`examples/fanouttest`) |
|---|---|---|
| `Native.Battery` | `status → {level,charging}` | `100% charging=true` |
| `Native.DeviceInfo` | `info → {model,manufacturer,systemVersion,sdkInt}` | `Google sdk_gphone64_x86_64 · sdk 34` |
| `Native.NetInfo` | `status → {connected,kind}` | `connected=true wifi` |
| `Native.Brightness` | `get → {level}` | `40%` |
| `Native.Haptics` | `impact/notification/selection` | `dispatch module=Haptics … {"style":"success"}` |

Every call dispatched through the C1 ABI (logged), decoded into typed `.can` records, no `ModuleNotFound`.
*(NetInfo uses field `kind`, not the reserved `type`.)*

### 2.3 HostComponent registry — third-party native views (Escape-hatch M1+M2)
The other half of the moat: a library ships its own native view with **no edit to the host's `makeView`
switch**.
- `host/android/.../CanopyComponentFactory.java` — interface `create/applyProp/reset` (Java side of
  `CanopyAbi.h`'s `CanopyViewFactory`; `reset` mandatory so a recycled view doesn't leak state).
- `host/android/.../CanopyViewRegistry.java` — `ConcurrentHashMap` tag→factory + `register`/`create`.
- `CanopyHost.makeView` default case now consults the registry before `YogaViewGroup` (built-in tags keep
  the fast in-switch path).
- `Native.hostComponent : String -> List Attr -> List Node -> Node` (= `VirtualDom.node tag`), exposed in
  `Native.can`.

**Proof:** `MainActivity` registers an Android `RatingBar` under tag `"CanopyRatingBar"` (a real library
would register in its own init); `examples/hosttest` renders `Native.hostComponent "CanopyRatingBar" …`;
on device `class="android.widget.RatingBar"` is in the live view tree (screenshot
`/tmp/hostcomponent-ratingbar.png`) — a view the switch doesn't know, mounted with zero host edit.

**Net:** both extensibility-moat halves are open — native **modules** (`gen-capability`) and native
**views** (HostComponent registry).

---

## 3. Example apps added (validation harnesses)

| App | Proves |
|---|---|
| `examples/redboxtest` | source-map symbolication in the red-box |
| `examples/navtest` | the `stack` navigator (push/pop) |
| `examples/captest` | a generated capability (`Vibration`) dispatches |
| `examples/fanouttest` | the 5-capability fan-out returns real device data |
| `examples/hosttest` | a third-party native view via `Native.hostComponent` |

---

## 4. Recipes & gotchas discovered (for the next session)

- **Editing `native.js` / adding a package module** does not propagate until you re-sync the package:
  `cd <pkg> && canopy link` (refreshes the `~/.canopy/packages/<pkg>` cache — it is a copy/symlink, not the
  live source) **then** `rm <pkg>/artifacts.dat` and `canopy setup` (compiles MISSING-artifacts packages).
  Symptom of skipping it: `UNKNOWN IMPORT [E0321] could not find module`.
- **Adding a package dependency** (e.g. navigation needed `canopy/css` for styling): add it to the package's
  `canopy.json` `dependencies`, then `canopy link` + `canopy setup`. Symptom: `could not find a Css module`.
- **Gradle asset/native cache:** a plain `assembleDebug` can ship a stale bundle or skip the C++ recompile.
  Force with `--no-build-cache` + `rm -rf app/build/intermediates/{merged_assets,assets}` +
  (for C++) `rm -rf app/.cxx`. Verify with `unzip -p app-debug.apk assets/canopy.bundle.js | grep <marker>`.
- **`BuildConfig.DEBUG`** needs `buildFeatures { buildConfig true }` on AGP 8 (now enabled).
- **`adb input tap`** near the screen's left edge is eaten by the gesture-nav back zone; switch to 3-button
  nav for edge taps: `adb shell cmd overlay enable com.android.internal.systemui.navbar.threebutton`.
- **Deploy a built app to the host:** `CANOPY_HOST_ASSETS=<host>/app/src/main/assets canopy-native build <app>`
  copies bundle + map + manifest in (skips on matching sha).

---

## 5. Remaining (next deep milestones)

In rough dependency order:
1. **OTA publish + client updater** (OTA M1/M2) — signed `update.json` + content-hashed HBC + atomic swap;
   rollback branches off the existing red-box guard. Builds on the manifest (§1.2).
2. **`gen-library` SDK scaffolder + sample** (Escape M4/M5) — package the module + view hatches into a
   `canopy-native-sdk` and a worked out-of-tree sample built with zero host edits (the autolinking story).
3. **Structured-error taxonomy + per-call streaming** (completes Capability M0) — `Rejected {code,message}`.
4. **Dev server + Fast Refresh** (DX M2) — the Metro-class watch→push loop.
5. **Native nav header + transitions** (Nav M2), tab/drawer navigators (Nav M3).
6. **iOS run-legs** — every milestone above has an iOS leg authored on Linux, gated on a Mac build
   (`host/ios/remote-build.sh`).
