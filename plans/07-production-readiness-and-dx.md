# 07 — Production Readiness & Developer Loop

Area: **prod-readiness-dx**. This is the plan that decides adoption: today a single JS
typo is a `SIGABRT` with no stack, the bundle reaches the device by a manual `cp`, and
there is no `canopy-native run`. RN/Expo win on the *loop* (red-box + Fast Refresh +
`expo run`), not on the framework. We close that gap.

**Build order (do these first, in this order):**
1. Red-box / graceful-error (kills the SIGABRT footgun — every other task gets easier to debug).
2. Bundle/asset sync (kills the manual-`cp` footgun — makes every iteration deterministic).
3. Dev loop: `canopy-native run` + dev server + Fast Refresh.
Then: source maps → release pipeline → CI → OTA (design) → symbolication.

---

## 0. Current state (file:line evidence)

### 0.1 Error handling — four unguarded JS↔host re-entry sites = SIGABRT

The host crosses into Hermes in exactly five spots; **none** catch `jsi::JSError`, so any
thrown JS error (or a `__canopy_boot` that throws) unwinds C++ through a `noexcept`
boundary and `std::terminate`s → `SIGABRT`, no message, no stack:

- `host/shared/cpp/CanopyFabric.cpp:117` — `canopyBoot()` calls `__canopy_boot(rootTag, flags)`; the bundle's `bootTail` throws a bare `Error` if the main module is missing (`tool/src/Canopy/Native/Bundle.hs:107`), and `view(model)` runs synchronously inside `init` on first frame.
- `host/shared/cpp/CanopyFabric.cpp:105` — `canopyEmitEvent()` calls `__canopy_dispatchEvent(view,name,payload)`; a decoder/update crash on a tap propagates here.
- `host/shared/cpp/CanopyModules.cpp:118` — `canopyResolveCall()` calls `__canopy_resolve(callId,err,result)`; a Cmd/Sub continuation that throws crashes here, on the JS thread, after a worker hop.
- The `installFn` HostFunctions in both files (`CanopyFabric.cpp:38`, `CanopyModules.cpp:24`) — a `getString`/`getObject` on an unexpected JS value throws `jsi::JSError` *out of the host function*, which Hermes turns into a JS exception, but the *call sites above* still don't catch it.
- `host/android/app/src/main/jni/CanopyHostJni.cpp:223` — `evaluateJavaScript(...)` of the 363 KB bundle; a syntax error or top-level throw aborts here with no red box.

The only JS-side guard is `_Native_safeDraw` (`package/external/native.js:695`) which
swallows draw errors into `console.error` — invisible on device unless you have `logcat`
open, and it does **not** cover `init`, `update`, Cmd/Sub continuations, or boot.

### 0.2 Bundle → device is a manual copy (the sync footgun)

- `tool/src/Canopy/Native/Bundle.hs:25` `assembleBundle = hermesPreamble ++ compiledJs ++ bootTail`. `Build.hs:83-85` writes it to `<outputDir>/canopy.bundle.js`.
- Nothing copies that to `host/android/app/src/main/assets/canopy.bundle.js` (363 860 bytes, hand-placed, dated later than the build output — `assets/canopy.bundle.js`).
- `MainActivity.java:73` reads it by name: `CanopyHostJni.boot(readAsset("canopy.bundle.js"), "{}")`. `MainActivity.java:76` hand-loads `models/super-resolution-10.onnx`; `assets/lumen-test.jpg` is also hand-placed.
- `external/native.js` is **not** a sync risk: it is embedded by `foreign import javascript "external/native.js" as NativeFFI` (`package/src/Native.can:47`) and rides the compiler (147 `_Native_*`/`__fabric_*` refs confirmed inside the bundle). The footgun is the *bundle blob + binary assets* (model, images, future fonts), which today have no manifest, no content hash, and no Gradle hook.

### 0.3 Source maps exist in the compiler but are broken by bundling

- The compiler already generates V3 maps (`compiler/.../Generate/JavaScript/SourceMap.hs`), appends `//# sourceMappingURL=` and writes `<out>.js.map` (`compiler/.../Make/Output.hs:150,498-500`), populating `sourcesContent` from `.can`.
- **But** `Bundle.hs:27` prepends `hermesPreamble` (~55 lines) and the `// ---- compiled ----` banner *before* the IIFE, shifting every generated line down. The emitted `app.iife.js.map` (if any) no longer lines up with `canopy.bundle.js`.
- The host names the eval buffer `"canopy.bundle.js"` (`CanopyHostJni.cpp:224`) and never feeds a map to Hermes, so a Hermes stack trace shows `canopy.bundle.js:1:NNNNN` (one giant line) — useless.

### 0.4 No dev loop

- `tool/app/Main.hs:19-29`: commands are `init | build | codegen | doctor | version | help`. No `run`, no `dev`, no `start`.
- Build is fire-and-forget JS assembly (`Build.hs:runBuild`); there is no socket, no file watcher, no reinstall, no bundle push.

### 0.5 No release pipeline

- `host/android/app/build.gradle:51-53`: only `buildTypes { debug { debuggable true } }`. No `release`, no `minifyEnabled`, no `signingConfigs`, no `proguardFiles`.
- `build.gradle:17`: `abiFilters 'arm64-v8a','x86_64'` for *all* builds (x86_64 ships to the Play Store needlessly).
- No `bundleRelease` wiring, no `.aab` story, no Hermes bytecode precompile (`hermesc`), no ProGuard keep-rules for `com.canopyhost.**` / `com.facebook.{yoga,jni}.**` / ORT JNI.

### 0.6 No CI, no symbolication, no OTA. Confirmed absent across `host/`, `tool/`, repo root.

---

## 1. Target design (RN/Expo parity)

| Capability | RN/Expo today | Canopy Native target |
|---|---|---|
| JS error in dev | LogBox red box, tap to expand symbolicated stack | **CanopyRedBox** full-screen overlay, symbolicated `.can` stack, "Reload" + "Dismiss" |
| JS error in prod | graceful error screen / crash report | **CanopyErrorScreen** (branded), one breadcrumb line to logcat/console, optional crash upload |
| Stack traces | Metro symbolication server | bundle ships `.can` `sourcesContent`; host loads the map into a JS-side `Error.prepareStackTrace`; dev server symbolicates |
| Hot reload | Metro Fast Refresh over WS | `canopy-native run` → watcher → recompile → push bundle over WS → host re-evals + re-boots, model state preserved when possible |
| Bundle delivery | Metro packager / embedded | content-hashed asset pipeline owned by `canopy-native`, Gradle-integrated |
| Release | `./gradlew bundleRelease`, R8, ABI splits, signing | `canopy-native build --release` drives `bundleRelease`: R8 + ABI splits + Hermes bytecode + signing + ProGuard |
| CI | EAS / GH Actions | GH Actions: tool build + harness unit + emulator smoke |
| OTA | CodePush / EAS Update | **design-only**: signed bundle manifest, host checks-on-boot, atomic swap |

**Data-flow invariant we must preserve:** the JS thread is the UI thread
(`CanopyHostJni.cpp:171-178`). Every guard, red box, and hot-reload re-eval runs **on that
thread**. The red box is itself a `CanopyHost` native view tree (no WebView), mounted on
the same root the program uses, so it works even when the program's `view` is the thing
that crashed.

---

## 2. Red-box + graceful error (DO FIRST)

### 2.1 C++: wrap the re-entry sites — `host/shared/cpp/`

Add a shared dispatch helper and route all five sites through it. New file
**`host/shared/cpp/CanopyError.h` / `.cpp`** (portable, no platform headers):

```cpp
namespace canopy {
// Set once at boot by the host; receives (message, jsStack, isFatal).
using ErrorSink = std::function<void(const std::string& msg,
                                     const std::string& jsStack,
                                     bool fatal)>;
void setErrorSink(ErrorSink sink);

// Run a JSI call; on jsi::JSError extract .what()/.getStack(), route to the sink,
// and (dev) keep the runtime alive / (prod) keep alive but show error screen.
// Returns true on success.
bool guardJsCall(jsi::Runtime& rt, const char* site,
                 const std::function<void()>& fn);
}
```

`guardJsCall` body:
```cpp
try { fn(); return true; }
catch (jsi::JSError& e) {
  reportError(e.getMessage(), e.getStack(), /*fatal=*/false); // <- via the sink
  return false;
}
catch (const std::exception& e) {
  reportError(std::string("native: ") + e.what(), "", /*fatal=*/true);
  return false;
}
```

**Edits:**
- `CanopyFabric.cpp:46-98` — wrap each of the 8 `installFn` lambda bodies in
  `try{...}catch(jsi::JSError&){ canopy::reportError(...); return Value::undefined(); }`
  so a bad arg from JS becomes a red box, not a thrown JSI value that the *caller* must
  re-catch. (Cheapest correctness win: a host function must never let a C++ exception
  escape into Hermes' calling frame.)
- `CanopyFabric.cpp:101 canopyEmitEvent` → wrap the `dispatch.call(...)` in `guardJsCall`.
- `CanopyFabric.cpp:112 canopyBoot` → wrap the `boot.call(...)`; on failure show the error
  screen (boot failure is fatal-ish: there is no program).
- `CanopyModules.cpp:110 canopyResolveCall` → wrap the `resolve.call(...)`. This is the
  highest-frequency site (every Cmd/Sub completion).
- `CanopyHostJni.cpp:223 evaluateJavaScript` → wrap in `try/catch(jsi::JSError&)`; a bundle
  syntax error / top-level throw becomes a red box instead of `SIGABRT`.

### 2.2 The sink → red box vs error screen — `CanopyHostJni.cpp` + new Java view

- In `CanopyHostJni.cpp:boot`, after creating `g_host`, call
  `canopy::setErrorSink([](msg,stack,fatal){ postToJs([...]{ showRedBox(msg,stack); }); })`.
  The sink hops to the JS/UI thread via the existing `postToJs` (`CanopyHostJni.cpp:60`)
  so it can mount native views safely.
- New **`host/android/app/src/main/java/com/canopyhost/CanopyRedBox.java`**: a
  `FrameLayout` overlay added on top of the `surface` (`MainActivity.java:68`). Dark
  background, scrollable monospace `TextView` for `msg` + symbolicated `stack`, two
  buttons: **Reload** (calls `CanopyHostJni.reload()` — see §4) and **Dismiss**. Built
  with plain Android views (NOT through the Canopy walker, so it survives a walker crash).
- Dev vs prod switch: a build flag `canopy.dev` (BuildConfig field, set by the Gradle
  variant). Dev → `CanopyRedBox`. Prod → **`CanopyErrorScreen.java`** (branded "Something
  went wrong / Restart" — no stack), plus one `Log.e("Canopy", msg)` and an optional
  crash-upload hook (§9).
- New native + Java method pair `CanopyHostJni.showRedBox(String msg, String stack)` /
  `nativeShowRedBox` is **not** needed if the sink lambda calls a *Java static* directly;
  add `static void onJsError(String msg, String stack, boolean fatal)` to
  `CanopyHostJni.java` and have the C++ sink call it via JNI (mirror of `scheduleOnJs`,
  `CanopyHostJni.java:56`). Cache its `jmethodID` in `install` (`CanopyHostJni.cpp:124`).

### 2.3 JS-side error boundaries + unhandled rejections — `package/external/native.js`

- Broaden `_Native_safeDraw` (`native.js:695`) into a **`_Native_guard(label, fn)`** used
  around `init`, `update`, and the animator callback (`native.js:745`). On catch, instead
  of only `console.error`, call a new host global
  `__canopy_onError(label, String(e), e && e.stack)` (installed by C++ in §2.1 as a host
  function that routes to the sink). This gives JS-origin errors the same red box without
  a C++ throw round-trip.
- **Unhandled promise rejections:** Hermes supports
  `HermesInternal.enablePromiseRejectionTracker`. In `CanopyHostJni.cpp:boot` (after eval),
  call it via JSI to register a tracker that forwards `(id, reason)` to `__canopy_onError`.
  Fallback if unavailable: wrap `_Native_resolve` continuations (the JS side of
  `__canopy_resolve`) in `_Native_guard`.
- The compiler's runtime `Process.sleep`/Task scheduler (`Bundle.hs:45`) uses the
  `setTimeout` shim; wrap the shim's `job()` (`Bundle.hs:48`) in a try/catch → `__canopy_onError`.

### 2.4 iOS

- `CanopyError.h/.cpp` is portable — same `guardJsCall`/sink, no changes.
- The sink's UIKit side (a `CanopyRedBoxView` / `CanopyErrorViewController`) is **blocked on
  the iOS Xcode-project bring-up** (host is two loose `.mm` files, no project). Stub: until
  then, the iOS sink logs via `os_log` and the boot guard prevents the abort. Wire the
  overlay when the project exists (cross-ref: the iOS-bringup plan).

**Effort: M.** Highest ROI. Unblocks debugging of every later task.

---

## 3. Bundle + asset sync pipeline (DO SECOND)

Goal: `canopy-native build` is the single owner of "what lands in `assets/`", deterministic
and content-hashed; Gradle consumes its output; no human `cp`.

### 3.1 `canopy-native` owns assembly + an asset manifest — `tool/src/Canopy/Native/`

- New **`tool/src/Canopy/Native/Assets.hs`**:
  - `data AssetEntry = AssetEntry { aeName, aeSrcPath, aeSha256, aeBytes }`.
  - `data AssetManifest = AssetManifest { amBundle :: AssetEntry, amExtra :: [AssetEntry] }`.
  - `collectAssets :: NativeConfig -> IO AssetManifest` reads a new `assets` array from
    `native.config.json` (e.g. `models/super-resolution-10.onnx`, `lumen-test.jpg`) plus
    the assembled bundle; computes sha256 of each (use `cryptohash-sha256` or shell
    `sha256sum`); writes **`assets/canopy.manifest.json`** = `[{name, sha256, bytes}]`.
- Extend `NativeConfig` (`tool/src/Canopy/Native/Config.hs`) with `ncAssets :: [FilePath]`
  and `ncAndroidAssetsDir`/`ncIosResourcesDir` (default
  `host/android/app/src/main/assets`).
- Rewrite `finishBundle` (`Build.hs:76-87`) so after writing `canopy.bundle.js` it:
  1. content-hashes the bundle,
  2. copies bundle + every `ncAssets` entry into `ncAndroidAssetsDir`,
  3. writes `canopy.manifest.json`,
  4. **skips the copy if the dest sha matches** (deterministic, fast no-op rebuild).
- The manual `cp` and the stale 363 KB blob in `assets/` are deleted; `assets/` becomes a
  build *output* dir (gitignore it, keep a `.gitkeep`).

### 3.2 Gradle consumes the tool's output — `host/android/app/build.gradle`

- Add a `preBuild`-dependent task `syncCanopyAssets` that shells
  `canopy-native build [--release]` (path from a `canopy.toolPath` gradle property) and
  fails the Gradle build if the tool fails. Wire `tasks.named('preBuild').dependsOn('syncCanopyAssets')`.
  This makes `./gradlew assembleDebug` always rebuild the bundle — no drift.
- Read `canopy.manifest.json` in `MainActivity` (`readAsset` already exists,
  `MainActivity.java:126`) and **verify the boot bundle's sha** before `boot()`; mismatch →
  `CanopyErrorScreen` "stale bundle, rebuild". Catches the embed gotcha at runtime too.
- Replace the hard-coded `readAssetBytes("models/super-resolution-10.onnx")`
  (`MainActivity.java:76`) with a manifest-driven loader so adding a model is a config edit,
  not a Java edit.

### 3.3 iOS

- `Assets.hs` writes to `ncIosResourcesDir` too; the actual Xcode "Copy Bundle Resources"
  build phase is **blocked on project bring-up**. Until then `collectAssets` still produces
  the manifest + copies into a `Resources/` folder the future project will reference.

**Effort: M.** Kills the second footgun; precondition for a reliable dev loop.

---

## 4. Dev loop: `canopy-native run` + dev server + Fast Refresh (DO THIRD)

### 4.1 `canopy-native run` — `tool/app/Main.hs` + `tool/src/Canopy/Native/Run.hs`

- Add `("run" : rest) -> cmdRun rest` to `dispatch` (`Main.hs:19`). Flags:
  `--device <id>`, `--release`, `--no-dev-server`, `--port 8088`.
- `cmdRun`:
  1. `runBuild` (debug) → assemble + sync assets (§3).
  2. `./gradlew installDebug` via `System.Process` (cwd = `host/android`), or `assembleDebug` +
     `adb install -r` for speed.
  3. `adb shell am start -n com.canopyhost/.MainActivity`.
  4. `adb reverse tcp:8088 tcp:8088` so the device can reach the dev server on localhost.
  5. start the dev server (§4.2) unless `--no-dev-server`.
- Update `usage` (`Main.hs:88`).

### 4.2 Dev server — `tool/src/Canopy/Native/DevServer.hs`

Keep it dependency-light (the tool currently has no web deps). Two options, pick **B**:

- **(A)** a tiny WebSocket server in Haskell (`websockets` pkg) — adds a heavy dep.
- **(B) recommended:** ship a small **Node dev server** under
  `tool/devserver/canopy-dev-server.js` (Node already required for the harness,
  `harness/package.json`), and have `DevServer.hs` spawn it with `node`. Rationale: file
  watching (`chokidar`) + WS (`ws`) are trivial in Node and the harness already proves Node
  is in the toolchain.

Dev server responsibilities:
- Watch `app/src/**/*.can` (+ `package/external/native.js`).
- On change: shell `canopy-native build` (incremental), read the new
  `assets/canopy.bundle.js` + manifest, and push `{type:"bundle", sha, code, map}` over WS.
- Serve the source map by sha for symbolication requests (`{type:"symbolicate", frames}`).
- Debounce; on compile error push `{type:"error", report}` → red box (§2) shows the
  compiler error, not a runtime crash.

### 4.3 Host side: receive + re-boot — `CanopyHostJni` + a dev WS client

- New **`host/android/app/src/main/java/com/canopyhost/DevClient.java`** (debug variant
  only — under `app/src/debug/java/...` so it is stripped from release): opens a WS to
  `ws://localhost:8088` (reachable via `adb reverse`). On `bundle` message → call new native
  `CanopyHostJni.reload(String bundleJs)`.
- New native **`Java_com_canopyhost_CanopyHostJni_reload`** in `CanopyHostJni.cpp`:
  - On the JS thread (post via `scheduleOnJs`): tear down the current program — call a new
    JS hook `__canopy_teardown()` (added in `native.js`: removes the root's child, clears
    the event registry, cancels live Subs) — then `evaluateJavaScript(newBundle)` and
    `canopyBoot(rootTag, flags)` again.
  - **Fast Refresh (stretch):** preserve `model`. Add `__canopy_getState()` /
    `__canopy_bootWithState(rootTag, flags, state)` to `native.js` so a reload re-mounts
    with the prior model when the `Model` type is unchanged (best-effort; fall back to full
    re-init on shape mismatch). Full reload first; state-preserving second.
- `WebSocket` dep: use `okhttp` (debug-only `implementation` in `build.gradle`,
  `debugImplementation 'com.squareup.okhttp3:okhttp:4.12.0'`) — no need to hand-roll.

### 4.4 Errors as part of the loop

- `{type:"error"}` from the dev server (compile failure) → `CanopyRedBox` with the compiler
  report (reuse §2 overlay). This is the "edit, see error inline" loop RN has.

### 4.5 iOS

- `DevClient` equivalent + `reload` is portable C++ once the iOS host has a runloop;
  **blocked on iOS project bring-up**. The dev server + `canopy-native run --platform ios`
  (drive `xcodebuild` + `xcrun simctl`) is designed but parked behind that.

**Effort: L.** The headline DX feature. §2 + §3 are prerequisites.

---

## 5. Source maps end-to-end

The compiler already emits maps; we must keep them aligned through bundling and load them
into Hermes for symbolicated traces.

### 5.1 Keep the map aligned — `tool/src/Canopy/Native/Bundle.hs`

The preamble shifts lines. Two fixes (pick **B**):
- **(A)** Re-offset the V3 mappings by the preamble's line count and merge with an identity
  map for the preamble/tail. Correct but re-implements VLQ math in the tool.
- **(B) recommended:** make `assembleBundle` emit the preamble + boot tail as **trailing**
  code where possible, or—simpler—have the tool ask the compiler for the map and call a new
  `Bundle.shiftSourceMap :: Int -> SourceMap -> SourceMap` that adds the preamble line count
  to every segment's generated-line (the preamble has no mappings, so a constant line offset
  is exact). Write the shifted `canopy.bundle.js.map` next to the bundle and append
  `//# sourceMappingURL=canopy.bundle.js.map`.
- Confirm `canopy make --output-format=iife` actually writes the `.map` (the writer exists,
  `Make/Output.hs:150,498`; verify it fires for the iife format path, `Build.hs:68`). If
  iife skips it, add `--source-map` plumbing in `runCanopyMake` (`Build.hs:66`).

### 5.2 Load the map into the runtime — `CanopyHostJni.cpp` + `native.js`

- Hermes does not auto-consume sourceMappingURL at runtime. Install a JS-side
  `Error.prepareStackTrace` (or a `__canopy_symbolicate(stack)`ized in `native.js`) that, in
  **dev**, reads the bundled `.map` (passed in as a second eval input or fetched from the dev
  server, §4.2) and rewrites `canopy.bundle.js:1:NNNNN` → `Main.can:42:7`. The red box (§2)
  calls this before display.
- In **prod**, leave raw frames; symbolicate offline (§9) from the archived `.map`.

### 5.3 iOS — same JS-side mechanism; portable. Not blocked.

**Effort: M.** Big debugging multiplier; depends on §2 (red box renders the result).

---

## 6. Release pipeline — `host/android/app/build.gradle` (+ `canopy-native build --release`)

### 6.1 Build types + ABI splits + signing

```gradle
buildTypes {
  debug   { debuggable true;  buildConfigField "boolean","CANOPY_DEV","true" }
  release {
    minifyEnabled true
    shrinkResources true
    proguardFiles getDefaultProguardFile('proguard-android-optimize.txt'), 'proguard-rules.pro'
    signingConfig signingConfigs.release
    buildConfigField "boolean","CANOPY_DEV","false"
    ndk { abiFilters 'arm64-v8a' }          // drop x86_64 for store builds
  }
}
signingConfigs {
  release {
    storeFile file(System.getenv("CANOPY_KEYSTORE") ?: "release.keystore")
    storePassword System.getenv("CANOPY_KEYSTORE_PW")
    keyAlias System.getenv("CANOPY_KEY_ALIAS")
    keyPassword System.getenv("CANOPY_KEY_PW")
  }
}
android.buildFeatures.buildConfig true
// release: ABI splits OR rely on .aab to do per-device delivery
splits { abi { enable true; reset(); include 'arm64-v8a','armeabi-v7a'; universalApk false } }
```
- The debug `abiFilters 'arm64-v8a','x86_64'` (`build.gradle:17`) moves into the `debug`
  type only (x86_64 for the emulator); release excludes x86_64.

### 6.2 ProGuard keep-rules — new **`host/android/app/proguard-rules.pro`**

JNI-reached classes/methods must survive R8 (their methods are looked up by signature from
C++, `CanopyHostJni.cpp:80,85,108`):
```pro
-keep class com.canopyhost.** { *; }            # CanopyHost.createView/updateProps/... called by name from JNI
-keepclasseswithmembernames class * { native <methods>; }
-keep class com.facebook.jni.** { *; }
-keep class com.facebook.yoga.** { *; }         # Yoga JNI
-keep class com.facebook.soloader.** { *; }
-keep class ai.onnxruntime.** { *; }            # ORT JNI (canopy/inference)
-keepattributes LineNumberTable,SourceFile      # keep native crash symbolication usable
```

### 6.3 Hermes bytecode precompile (HBC)

- Add a `canopy-native build --release` step that runs `hermesc -emit-binary -out
  canopy.bundle.hbc canopy.bundle.js` (the matching `hermesc` ships in the 0.76.9 Hermes
  toolchain already vendored, `build.gradle:30` references those AARs). Ship `.hbc` in
  `assets/`; `MainActivity` boots whichever exists (`.hbc` preferred). Faster startup, no
  source in the APK. `evaluateJavaScript` already accepts a buffer (`CanopyHostJni.cpp:223`);
  pass the HBC bytes.
- Strip `sourceMappingURL` from the shipped JS; archive the `.map` for §9.

### 6.4 `.aab`

- `canopy-native build --release --aab` → `./gradlew bundleRelease` → signed `.aab`. Document
  Play App Signing. Add `--apk` for sideload (`assembleRelease`).

### 6.5 iOS — `xcodebuild archive` + `exportArchive`, code-signing via `xcrun`. **Blocked on
project bring-up.** Design parity noted (Release config, bitcode-off, dSYM archived for §9).

**Effort: L** (Android), iOS blocked.

---

## 7. CI — emulator build + smoke (`.github/workflows/`)

New **`.github/workflows/canopy-native.yml`**:
- **job: tool** — `stack build` + `stack test` for `tool/` (`tool/test/Spec.hs`).
- **job: harness** — `node run.js && node run-compiled.js && node run-echo.js`
  (`harness/package.json` already defines `test`). This is the mock-fabric unit gate.
- **job: android** — checkout, set up JDK 17 + Android SDK/NDK 26.3, build the `canopy`
  compiler (or pull a cached binary, `Build.hs:findCanopy`), `canopy-native build`,
  `./gradlew assembleDebug`. Then `reactivecircus/android-emulator-runner` to boot an
  arm64/x86_64 AVD and run a **smoke test**: `adb install`, launch, and assert the program
  mounted (see §8.2 E2E driver — grep logcat for a boot sentinel + a testID dump).
- Cache: `~/.stack`, Gradle, NDK. Gate PRs on tool + harness (fast); android job on a label
  or nightly (slow emulator).

**Effort: M.** Depends on §3 (deterministic bundle) and §8.2 (smoke assertion).

---

## 8. Testing strategy

### 8.1 Mock-fabric unit (exists, extend) — `harness/`

- `harness/mock-fabric.js` already implements the full `__fabric_*` surface and records a
  mutation log (`mock-fabric.js:16-30`). Reuse for **all** new JS-side work:
  - Error boundaries: feed a `view` that throws → assert `__canopy_onError` fired and no
    further mutations (no half-rendered tree).
  - Hot-reload: drive `__canopy_teardown` + re-`boot` against the mock → assert the tree is
    rebuilt and the old event registry is empty.
  - Source map: unit-test `Bundle.shiftSourceMap` in `tool/test/Spec.hs` with a known
    preamble offset (golden V3 map).
- Add `harness/run-errors.js` + `harness/run-reload.js` to `package.json` `test`.

### 8.2 Device E2E driver

- **Blocker today: `testID` is a no-op on both hosts** (per audit) — a driver can't find
  elements. Prereq (own its own plan, cross-ref the components plan): make `testID` set a
  `View.setTag`/`contentDescription` on Android so UIAutomator/Espresso can locate it, and
  emit a JSON **view-dump** over a debug-only native method `CanopyHostJni.dumpTree()` →
  `{handle, tag, testID, text, rect}[]`.
- E2E driver (Node, under `tool/e2e/`): `adb` + the dump endpoint. Asserts: boot mounts a
  tree; a tap (`adb shell input tap`) on a testID's rect produces the expected single
  `updateProps` (the §8 criterion, now on-device). Used by the CI smoke job (§7).

**Effort: M** (driver) + the testID prereq (S, in another plan).

---

## 9. OTA + crash symbolication

### 9.1 OTA (design only)

- `canopy-native publish --channel <c>`: content-hash the release `.hbc` + manifest, sign
  with the app's update key, upload to a static bucket as `manifest.json` +
  `<sha>.hbc.gz`.
- Host (new `CanopyUpdater` Java, debug-disabled): on boot, fetch `manifest.json`, compare
  sha to the embedded/last-applied bundle, download if newer to internal storage, verify
  signature, then **atomic swap**: `MainActivity.boot` prefers the OTA bundle over the
  embedded asset (`readAsset` → `readOtaOrAsset`). Rollback: keep N-1; if boot guard (§2)
  reports a fatal within X ms of an OTA boot, revert to embedded.
- Reuses §3's manifest format and §6.3's HBC. **No code now; spec only.**

### 9.2 Crash symbolication

- **JS crashes:** already covered — archive `canopy.bundle.js.map` per release (§5.1);
  the dev server symbolicates live, prod stacks symbolicate offline with the archived map.
- **Native crashes (C++/JNI/ORT):** keep `LineNumberTable,SourceFile` (§6.2) and the
  unstripped `.so` debug symbols. `canopy-native build --release` archives
  `app/build/intermediates/cmake/release/obj/<abi>/*.so` (with symbols) before stripping;
  use `ndk-stack`/`addr2line` against a logcat tombstone. Document in the plan; optionally
  integrate a crash SDK later (Crashlytics) gated behind the prod error screen (§2.2).

**Effort: OTA = L (later), symbolication = S (archive + doc).**

---

## 10. Web-package reuse

- **Source maps:** *reuse* the compiler's existing `SourceMap.hs` + `Make/Output.hs` writer
  end-to-end; only add a line-offset shim in the tool (§5.1). Do **not** re-back.
- **Error reporting JS:** *reuse* the runtime's existing `console` + `_Native_safeDraw`
  pattern (`native.js:695`); generalize rather than re-back.
- **Mock fabric / harness:** *reuse* `harness/mock-fabric.js` as the unit substrate for
  every new behavior — it is already the third-walker's test double.
- **Dev server:** *re-back* (new), but lean on Node (already a toolchain dep via the
  harness) for watch+WS rather than adding Haskell web deps.
- **Red box:** *re-back* natively (Java/UIKit) — it must survive a walker crash, so it
  cannot be a Canopy view tree.

---

## 11. Milestones (ordered)

| # | Milestone | Effort | Key files |
|---|---|---|---|
| M1 | **Red-box + graceful error** | M | `CanopyError.h/.cpp` (new), `CanopyFabric.cpp:46-118`, `CanopyModules.cpp:110`, `CanopyHostJni.cpp:124,171,223`, `CanopyHostJni.java`, `CanopyRedBox.java`+`CanopyErrorScreen.java` (new), `native.js:695,745` |
| M2 | **Bundle + asset sync** | M | `Assets.hs` (new), `Config.hs`, `Build.hs:76`, `build.gradle` (syncCanopyAssets), `MainActivity.java:73,76` |
| M3 | **Dev loop: `run` + dev server + Fast Refresh** | L | `Main.hs:19,88`, `Run.hs`+`DevServer.hs` (new), `tool/devserver/*.js` (new), `DevClient.java` (new, debug variant), `CanopyHostJni.cpp` reload, `native.js` teardown/state hooks |
| M4 | **Source maps end-to-end** | M | `Bundle.hs:25` (shift), `runCanopyMake`, `CanopyHostJni.cpp` map load, `native.js` symbolicate |
| M5 | **Release pipeline** | L | `build.gradle:51` (release/splits/signing), `proguard-rules.pro` (new), `Build.hs` (hermesc/aab) |
| M6 | **CI** | M | `.github/workflows/canopy-native.yml` (new) |
| M7 | **E2E driver + testID prereq** | M | `tool/e2e/*` (new), `CanopyHost.java` (testID→tag), `CanopyHostJni.dumpTree` |
| M8 | **OTA (design) + symbolication** | S→L | `CanopyUpdater.java` (later), build archive step, docs |

---

## 12. Risks & open questions

1. **Red box must outlive the crash.** If the crash corrupts the Hermes runtime (not just
   throws), even the sink can't re-enter JS. Mitigation: the overlay is pure Java mounted
   directly on `surface`; the sink JNI call (`onJsError`) takes only strings, no runtime
   re-entry. Open: should a *second* error while the red box is up force-kill vs loop?
2. **Fast Refresh state preservation** is best-effort: a changed `Model` type makes the old
   state undecodable. Ship full-reload first; gate state-preserving behind a type-hash check.
3. **Source-map alignment after `--optimize`.** Minified/optimized builds may not emit maps
   (verify `Make/Output.hs` for the optimize path). Dev uses unoptimized; prod symbolication
   may need a separate "release + map" build. Open question.
4. **HBC version coupling.** `hermesc` must exactly match the vendored `libhermes.so`
   (0.76.9). A mismatch is a silent boot failure. Pin and check in `doctor`.
5. **R8 stripping JNI lookups.** `CanopyHost` methods are resolved by *name+signature* from
   C++ (`CanopyHostJni.cpp:80`); a missed keep-rule is a runtime `NoSuchMethodError` only in
   release. Mitigation: a release smoke test in CI (§7) that actually mounts a tree.
6. **`adb reverse` for the dev server** requires USB/emulator; a Wi-Fi device needs the host
   LAN IP instead. Handle both in `canopy-native run`.
7. **iOS is blocked** on the Xcode-project bring-up for: red-box overlay (§2.4), asset copy
   phase (§3.3), dev-loop reload (§4.5), release/archive (§6.5). The *portable C++* pieces
   (`CanopyError`, `guardJsCall`, sink, map-shift) are written platform-agnostic so iOS
   inherits them for free once the project exists. Cross-reference the iOS-bringup plan as
   the hard dependency.
8. **Tool dependency creep.** Spawning Node for the dev server keeps Haskell deps minimal but
   adds a Node requirement to `run`/`dev` (not to `build`). `doctor` must check for it.
