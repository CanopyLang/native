# Canopy Native Modules: How They Work, Why They Don't Scale Yet, and the Autolinking Design That Fixes It

**Audience:** owner / lead review. **Date:** 2026-06-15. Every claim below is grounded in direct code reading or the cited research briefs.

---

## 1. Direct answer

**Is it hardcoded? Partly — and the hardcoded part is exactly the part that doesn't scale.**

The runtime substrate is *not* hardcoded and is genuinely good:

- The **C1 ABI is generic**: `__canopy_call(module, method, argsJson, callId)` dispatched by a `ModuleRegistry`. Methods are never hardcoded.
- **Module lookup is by name-convention reflection.** Android C++ does `FindClass("com/canopyhost/modules/<Name>Module")` and calls a static `invoke(method,args,callId)` (`host/shared/cpp/CanopyJni.cpp:92`). iOS `+registerModuleNamed:` resolves `Canopy<Name>Module` through a Swift module-prefix list (`host/ios/CanopyHostCore/Boot/CanopyModuleHost.mm:163-204`). Neither dispatcher is edited per capability.

But everything *around* that substrate violates the web model:

- **Registration is a hand-maintained, per-capability list in TWO shared host files.** Android: one `g_registry->registerModule(std::make_shared<canopy::JniModule>("Image"))` line per capability — Image, Photos, Album, ShareImage, StorageSecure, Notify, Http, Platform, Vibration, Battery, DeviceInfo, NetInfo, Haptics, Brightness, plus inline C++ instances (`RestoreEngineModule`, `globalBillingModule()`, two `globalStreamingModule(...)`) — `host/android/app/src/main/jni/CanopyHostJni.cpp:243-274`. iOS: the same list as the `caps[]` `NSArray` in `registerAll` — `host/ios/CanopyHostCore/Boot/CanopyModuleHost.mm:175-205`. **Adding a capability edits both shared boot files.**
- **The capability's native impl lives IN THE HOST APP, not in the package.** 18 Java modules under `host/android/app/src/main/java/com/canopyhost/modules/*.java` and 13 ObjC++ under `host/ios/CanopyHostCore/Modules/Canopy*Module.mm`. By contrast `canopy/image/` ships only `canopy.json + src/Image.can + external/image.js` — **zero native code**. The package is not self-contained.
- **Many capability `.can` modules even live inside the core `canopy/native` package** (`package/src/Native/Http.can`, `NetInfo.can`, `Battery.can`, `DeviceInfo.can`, `Brightness.can`, `Haptics.can`, `Platform.can`, `Vibration.can`) — so even the *Canopy* half of a capability is often not a separable dependency.
- **The build tool never reads the dependency graph.** `runBuild` loads only `native.config.json` (appName/bundleId/mainModule/entry/outputDir — no deps field) and shells to `canopy make` (`tool/src/Canopy/Native/Build.hs:38-79`, `Config.hs:19-38`). No resolution, no scan, no autolink. Its only codegen is a *fixed* built-in component set hand-authored in Haskell (`Component.hs:50-58`).
- **C++ capabilities cost two MORE shared edits:** `host/android/app/src/main/cpp/CMakeLists.txt:31-42` lists each `.cpp` by name and iOS `project.yml:110-131` references each `../shared/cpp/*.cpp` explicitly (deliberately not globbed).
- `CONVENTIONS.md §6` (`:162-174`) **formalizes this anti-pattern**: it lists files an author may not edit and instructs them to instead hand a human integrator an "integration manifest" of edits to apply to core/host.

**Does it scale? No.** Adding the Nth capability is O(edits-to-shared-core-files), and those edits are applied by a human, not a tool. That is the definition of not scaling.

**Do you always edit the native package?**

- **For an *existing* capability: no.** An app developer adds `import Image`, and it works — pure Canopy. The two-persona ideal already holds for what's already wired.
- **For a *new* capability: yes, today you must edit core/host.** The definitive edit list to add one new native capability today:
  1. create the `.can` module (today usually dropped into `canopy/native/package/src/Native/`, not its own package);
  2. create `host/android/.../modules/<Name>Module.java` (auto-compiled);
  3. create `host/ios/.../Modules/Canopy<Name>Module.mm` (auto-compiled on `xcodegen generate`);
  4. **edit** `CanopyHostJni.cpp:243-274` (+1 line);
  5. **edit** `CanopyModuleHost.mm:175-205` (+1 entry);
  6. if C++: **edit** `CMakeLists.txt` (+1 source) and `project.yml` (+1 ref);
  7. if it ships a view: a `makeView` case or `CanopyViewRegistry.register` call + `Component.hs` entry.

  `canopy-native gen-capability` automates only steps 1–2 (as a scaffold) and *prints* step 4's line for manual paste (`tool/app/Main.hs:58-81`, `tool/src/Canopy/Native/CapabilityCodegen.hs`). The rest is hand-applied.

**So: the gap is precisely "a NEW capability forces core/host edits."** Closing it means app devs stay pure-Canopy *and* capability authors stop touching core.

---

## 2. The web model is the spec

The north star is already in the tree and fully self-contained. A web capability package is one `.can` + one FFI file:

```
canopy/http/
  src/Http.can          -- foreign import javascript "external/http.js" as HttpFFI   (Http.can:67)
  external/http.js      -- the impl calling browser APIs
```

The invariant the compiler enforces, stated verbatim at `compiler/packages/canopy-core/src/Generate/JavaScript.hs:5-10` (repeated at `Generate/JavaScript/FFI.hs:17-19`):

> **NO HARDCODING OF FFI FILE PATHS! All FFI file paths MUST come from the actual foreign import statements** … This allows the FFI system to work with ANY project structure and ANY file paths.

The full pipeline, which native must mirror:

1. **The foreign-import statement IS the registration.** `foreign import javascript "external/http.js" as HttpFFI` is a first-class top-level construct (`Parse/Module.hs:484-511`, `AST/Source.hs:658-661`). There is no registry of FFI paths anywhere.
2. **Discovery = read the file relative to the package root.** For each foreign import, validate (relative, no `..`, ends `.js/.mjs`) and read `rootDir </> validPath` (`Canonicalize/Module/FFI.hs:118-125, 134-151`). `rootDir` is the package root.
3. **The alias becomes a real module.** `ffiModuleName = ModuleName.Canonical (packageOf home) alias`; FFI functions are typed from `@name`/`@canopy-type` JSDoc and registered qualified + unqualified (`FFI.hs:188-194, 576-585, 418-426`). So `HttpFFI.toTask` type-checks like any import — the app dev writes pure Canopy.
4. **`FFIInfo { path, content, alias }` is the carrier, Binary-serializable** into the package artifact (`Generate/JavaScript/FFI.hs:89-106`), so a *compiled dependency carries its FFI downstream* without re-reading source.
5. **Dependency-graph aggregation, deduped by path key.** `ffiInfoMap = Map.union (Map.unions (map mrFFIInfo moduleResults)) depFFIInfo` (`Compiler/Parallel.hs:558`); the key is the JS path string (`Driver.hs:357-368`), so the same file imported by multiple modules collapses to one entry.
6. **Concatenation + tree-shaking at codegen.** `generateFFIContent` emits every reachable file's JS into the one IIFE (`JavaScript.hs:116-118, 172`), with usage driven by `extractFFIAliases`/`computeFFIUsage`.
7. **The web BUILD TOOL does no FFI wiring at all.** The vite plugin just runs the compiler and reads the emitted `.js` (`vite-plugin-canopy/src/compiler.ts:63-70`). All inclusion happened inside the compiler.
8. **Permissions travel with the package** via JSDoc `@capability permission X` → `Capability X ->` type params (`FFI.hs:457-465, 694-710`).

**The invariant native must meet:** *Adding a capability = adding a dependency. A declaration in the package's own source is the sole source of truth; discovery is driven by the dep graph resolved relative to each package's root; the build artifact carries the impl; zero core/host files are touched.*

---

## 3. Best practice confirms it

This is not a novel or risky invention. **Every mature cross-platform framework implements the exact pattern, the same four ways**, and it is the unanimous documented best practice:

| Invariant | Expo Modules | React Native CLI | Flutter | Capacitor |
|---|---|---|---|---|
| **(1) Self-contained package** carrying native code + a small manifest naming the entry class | `expo-module.config.json` + Swift/Kotlin; `Module` self-describes via `definition()` DSL | `react-native.config.js` + `.podspec` | `pubspec.yaml` `flutter.plugin.platforms.<p>` (package + pluginClass) | `package.json` `"capacitor"` field + `@CapacitorPlugin(name=...)` |
| **(2) Build-time dependency-graph scan**, no central list | autolinking walks app deps + nested deps (Node resolution); SDK 54 = pure graph walk | `react-native config` reads package.json deps | build reads pubspec dep graph | `npx cap sync` inspects package.json |
| **(3) Generated registrant glue** | `GeneratePackagesListTask` → ExpoModulesPackage list | generated `PackageList.java` via `autolinkLibrariesWithApp()` | `GeneratedPluginRegistrant` (regenerated each build; "should not be manually edited") | generated plugin list on sync |
| **(4) Generated build includes** | Gradle plugin + iOS `autolinking_manager.rb` emit Podspecs/Podfile | `settings.gradle autolinkLibrariesFromCommand()`; iOS `use_native_modules!` | generated Gradle/Podfile entries | installs into Podfile/Gradle on sync |

RN's docs state it verbatim: *"That's it. No more editing build config files to use native code"* — workflow is `yarn add <pkg>` + `pod install`. Expo: *"neither AppDelegate nor MainActivity requires modification … discovered and registered automatically during the build process."*

**The crucial honest point, confirmed by all four:** a genuinely-new native capability *requires the library author to write Kotlin/Swift/Java* — Expo, RN, Flutter, and Capacitor all require it. **You cannot eliminate native code from capability authors.** What you *can* and must guarantee is that it stays **isolated inside the library package and never leaks into the app or the framework core.** Canopy's design goal is the industry-standard pattern; the "hardest unscoped piece" in the plan is precisely what these four already solved identically.

---

## 4. The design: Canopy-native autolinking

The runtime substrate already exists. **This is a codegen + build-tool change, not an ABI change.** The generic `__canopy_call` ABI, the reflective name-convention lookup, and the `CanopyViewRegistry` self-register hook (`host/android/.../CanopyViewRegistry.java:1-43`) are the three pieces that make per-capability *runtime* code unnecessary — we only need discovery, packaging, and glue generation.

### 4.1 Extend `foreign import` to native targets

Mirror `foreign import javascript` exactly. The grammar already produces `Src.ForeignImport { FFITarget, alias, region }` and parses an unused `WebAssemblyFFI` target — add native targets:

```
-- in canopy/image/src/Image.can, alongside the existing JS FFI line:
foreign import javascript "external/image.js"            as ImageWeb
foreign import kotlin     "native/android/ImageModule.kt"  as ImageNative
foreign import swift      "native/ios/ImageModule.swift"   as ImageNative
-- (or a single platform-resolving form:)
foreign import native     "native/Image"                   as ImageNative   -- resolves native/android/Image.kt + native/ios/Image.swift
```

This statement **is the registration** — the native analogue of the JS path string, and the sole source of truth. No `g_registry->registerModule` line, no `caps[]` entry, no boot edit, ever again.

Reuse the web mechanics verbatim:
- **Discovery** = `rootDir </> validPath` relative to each dependency's package root (mirror `Canonicalize/Module/FFI.hs:118-125`). Driven by the dep graph, never by `native.config.json`.
- **Carrier** = a `NativeFFIInfo { artifactPath, content/handle, alias, target :: Kotlin | Swift | Cpp }`, Binary-serializable into the package artifact so a compiled dependency carries its native impl downstream (mirror `FFIInfo`, `FFI.hs:89-106`).
- **Dedup** = keyed by artifact path so the same native file referenced by multiple modules collapses to one (mirror `Parallel.hs:558` `Map.union (Map.unions ...)`).
- **Types** = from annotations in/alongside the native file (the `@name`/`@canopy-type` analogue), so `ImageNative.crop` type-checks and the app dev still writes pure Canopy (reuse `ffiModuleName = ModuleName.Canonical (packageOf home) alias`).
- **Permissions** = the package's native manifest declares iOS Info.plist keys / Android manifest permissions; these autolink the same way `@capability permission X` travels with web FFI.

### 4.2 Package layout (self-contained, mirrors `canopy/http`)

```
canopy/image/
  canopy.json                       -- deps + a "native" manifest block (schema below)
  src/Image.can                     -- foreign import javascript "external/image.js" as ImageWeb
                                    -- foreign import native "native/Image" as ImageNative
  external/image.js                 -- web impl (unchanged)
  native/android/ImageModule.kt     -- Android impl, class com.canopyhost.modules.ImageModule (by convention)
  native/ios/ImageModule.swift      -- iOS impl, class CanopyImageModule (by convention)
  native/cpp/Image.cpp              -- OPTIONAL, only if a C++ NativeModule (e.g. ORT inference)
```

### 4.3 `canopy.json` native manifest schema

Small and declarative — the Canopy analogue of `expo-module.config.json` / `react-native.config.js` / pubspec platforms. Most fields are inferred from the foreign-import statements; the manifest only carries what cannot be inferred (build deps, streaming method specs, permissions, view tags):

```jsonc
{
  "name": "canopy/image",
  "dependencies": { /* ... */ },
  "native": {
    "modules": [
      {
        "name": "Image",                 // -> com.canopyhost.modules.ImageModule / CanopyImageModule
        "streaming": [],                 // method names that emit Subs (mirrors iOS caps[] streaming spec)
        "kind": "jni"                    // "jni" (default) | "cpp" (needs CMake/podspec source include)
      }
    ],
    "viewTags": ["canopy-bitmap"],       // -> generated CanopyViewRegistry.register calls
    "permissions": {
      "android": ["android.permission.READ_MEDIA_IMAGES"],
      "ios": { "NSPhotoLibraryUsageDescription": "Access photos to crop" }
    },
    "gradleDependencies": ["androidx.exifinterface:exifinterface:1.3.7"],
    "podDependencies": []
  }
}
```

### 4.4 What `canopy-native` generates (the autolink step)

The build tool gains the dependency-graph awareness it completely lacks today. `runBuild` must, before shelling to `canopy make`:

1. **Resolve + walk the dep graph** (parse the resolved `canopy.json` dep set the compiler already understands), and **scan each dependency for a `native` manifest + native foreign imports** — the direct analogue of the compiler's "FFI paths come only from foreign-import statements" rule.

Then it GENERATES (all into a `build/generated/` tree, none hand-edited):

**(a) Build includes** so out-of-tree native sources compile in:
- Android: a generated Gradle fragment adding each package's `native/android/` as a source set + `gradleDependencies` (mirror `settings.gradle autolinkLibrariesFromCommand`). C++ packages append their `native/cpp/*.cpp` to a generated CMake fragment that the existing `CMakeLists.txt` merely `include()`s — closing the two-extra-edits C++ gap.
- iOS: a generated xcodegen fragment / Podfile include packaging each `native/ios/` (mirror `use_native_modules!`), plus generated Info.plist permission keys.

**(b) The registrant** — replaces the hand-edited lists:
- Android: a generated `CanopyGeneratedRegistrant.cpp` containing the `g_registry->registerModule(std::make_shared<canopy::JniModule>("Image"))` lines (and `StreamingJniModule` instances for streaming modules) for every discovered module. `CanopyHostJni.cpp:243-274`'s per-capability block is deleted and replaced by a single call into the generated registrant.
- iOS: a generated `caps[]`-equivalent array (name + streaming spec) consumed by the existing `registerAll` loop, replacing the hardcoded `NSArray` at `CanopyModuleHost.mm:175-205`.
- Views: generated `CanopyViewRegistry.register(tag, factory)` init calls for every `viewTags` entry — the missing codegen that supplies today's unsolved "someone must still call `register()`" seam.

**(c) JS FFI inclusion** — already works, untouched (the compiler does it).

### 4.5 Why this is codegen-only (no per-capability runtime code)

- **The ABI is method-agnostic.** `__canopy_call(module, method, argsJson, callId)` never changes per capability.
- **Lookup is reflective by name.** Android `JniModule("Image")` → `com.canopyhost.modules.ImageModule.invoke`; iOS resolves `CanopyImageModule` via the prefix list. The generated registrant just needs to *name* the discovered modules; the dispatchers are immutable.
- **Views already self-register.** `CanopyViewRegistry` lets an unknown tag mount via `makeView`'s default case without editing the switch (`CanopyHost.java:272-303`). We only generate the init-time `register()` calls.
- **The iOS loop is already failure-tolerant** — a not-yet-landed module logs info, not error (confirmed at `CanopyModuleHost.mm`), so a generated, possibly-partial `caps[]` is already the expected shape.

So the boot files become **immutable**: they `#include`/call the generated registrant and stop carrying capability knowledge — the exact native analogue of `generateFFIContent` concatenating every `FFIInfo` into the bundle.

---

## 5. Migration

Sequenced, lowest-risk first. Effort is rough engineering-week estimates.

**Phase A — Compiler: native foreign imports (≈1.5–2 wk).** Extend the parser's existing `chompForeignTarget` to accept `kotlin`/`swift`/`cpp`/`native`; add `NativeFFIInfo` (Binary instance) flowing through `Driver.hs`/`Parallel.hs` exactly like `FFIInfo`, deduped by artifact path; resolve `rootDir </> validPath` per dependency; type the alias from native-side annotations. **No behavior change yet** — the info is just collected and serialized into artifacts.

**Phase B — Build tool: dep-graph scan + generated registrant (≈2–3 wk).** Give `runBuild` dep-graph awareness (`Build.hs`/`Config.hs`), scan for the `native` manifest + native FFIInfo, and generate the Android `CanopyGeneratedRegistrant.cpp` and the iOS `caps[]` array fragment. Wire the boot files to consume the generated registrant **in addition to** the existing hardcoded block (additive — both run, dedup tolerates it). This lets a new capability register with zero boot edits while nothing existing breaks.

**Phase C — Generated build includes (≈2 wk).** Generate the Gradle source-set/dependency fragment and the iOS xcodegen/Podfile fragment + Info.plist permissions, including the C++ CMake/podspec source append. After this, an out-of-tree package's native code compiles in with zero shared-file edits.

**Phase D — Extract the ~12 in-host modules into `canopy/*` packages (≈2–3 wk, mechanical).** Move each `host/android/.../modules/<Name>Module.java` + `host/ios/.../Canopy<Name>Module.mm` into its package's `native/android` / `native/ios`, and move the in-core `.can` (`package/src/Native/{Http,NetInfo,Battery,DeviceInfo,Brightness,Haptics,Platform,Vibration}.can`) into standalone packages with the native foreign import + manifest. Do the pure-JNI ones first (Image/Photos/Album/…); the C++/streaming ones (Billing's bespoke C++ module, the two `StreamingJniModule` instances for Lifecycle/AppShell, `RestoreEngineModule`) last, since they exercise the C++ and streaming codegen paths and the model-bytes-after-boot wiring.

**Phase E — Delete the hardcoded boot block (≈0.5 wk).** Once every capability is package-resident and the generated registrant covers them, remove `CanopyHostJni.cpp:243-274` and `CanopyModuleHost.mm:175-205`, and rewrite `CONVENTIONS.md §6` from "propose an integration manifest a human applies" to "ship a `native` manifest; the build tool autolinks it." Evolve `gen-capability` from scaffold+print into a generator that emits a **full self-contained package** (`canopy.json` + `src/<Name>.can` with the native foreign import + `native/android` + `native/ios`).

**What stays manual — and that's correct:** the **capability author writes the actual Kotlin/Swift** (and C++ if the capability needs it) for a genuinely-new native capability. This is irreducible — Expo/RN/Flutter/Capacitor all require it. The guarantee is that this code lives **only in that package's `native/` directory** and never touches core/host. App developers write **zero** native code.

**What must never be touched again after Phase E:** `CanopyHostJni.cpp`, `CanopyModuleHost.mm`, `CanopyHost.java`/`makeView`, `CMakeLists.txt`, `project.yml`, `build.gradle`, and the tool's `Component.hs`/`Build.hs` — all become capability-agnostic.

---

## 6. Definition of done

**The acceptance test, stated as the owner's principle:**

> Adding `"canopy/foo": "^1.0"` to an app's `canopy.json` dependencies makes `Foo` work on **both iOS and Android** with **no edits to `canopy/native` or the host shell**. The app contains **only Canopy source + a dependency list** — no Java, no Swift, no boot lines, no build-config edits.

Concretely, all of the following must hold:

1. `canopy/foo` is self-contained: `canopy.json` + `src/Foo.can` (with native foreign imports) + `native/android` + `native/ios` (+ `native/cpp` if needed). It ships its own native impl — like `canopy/http` ships `external/http.js`.
2. An app that did **not** previously depend on `Foo` adds the dependency line and `import Foo`, runs `canopy-native build`, and `Foo.someEffect` runs on a device on both platforms.
3. Diffing the app repo for that change shows **only** the dependency line — no native files, no `native.config.json` capability entry.
4. Diffing `canopy/native` and `host/` shows **zero** changes (the registrant and build fragments are generated into `build/generated/`, not committed shared files).
5. The same dependency, used by two different packages, links once (path-keyed dedup), and its declared permissions appear in the built Info.plist / AndroidManifest automatically.
6. `gen-capability foo` produces a package that satisfies (1) with no manual file placement.

When that test passes, the native model has reached parity with the web model: **adding a capability = adding a dependency**, the two personas are clean (app dev = pure Canopy always; capability author = Canopy + isolated native code in their own package), and the architecture scales like a real framework.

---

**Key file references for the implementing team:**
- Web north star: `compiler/packages/canopy-core/src/Generate/JavaScript.hs:5-10`; `Generate/JavaScript/FFI.hs:89-106`; `Canonicalize/Module/FFI.hs:118-125`; `canopy-builder/src/Compiler/Parallel.hs:558`; `canopy-driver/src/Driver.hs:357-368`; `http/src/Http.can:67`.
- Hardcoded boot blocks to replace then delete: `host/android/app/src/main/jni/CanopyHostJni.cpp:243-274`; `host/ios/CanopyHostCore/Boot/CanopyModuleHost.mm:175-205`.
- Generic substrate to build on: `host/shared/cpp/CanopyJni.cpp:92`; `host/android/.../CanopyViewRegistry.java:1-43` + `CanopyHost.java:272-303`.
- Build tool to extend: `tool/src/Canopy/Native/Build.hs:38-79`; `Config.hs:19-38`; `Component.hs:50-58`; `tool/app/Main.hs:58-81`; `tool/src/Canopy/Native/CapabilityCodegen.hs`.
- C++/iOS explicit-source edits to autogenerate: `host/android/app/src/main/cpp/CMakeLists.txt:31-42`; `host/ios/project.yml:110-131`.
- In-core `.can` to extract: `native/package/src/Native/{Http,NetInfo,Battery,DeviceInfo,Brightness,Haptics,Platform,Vibration}.can`.
- Anti-pattern to rewrite: `CONVENTIONS.md §6` (`:162-174`).