# canopy/native — Capability Conventions (the Foundation contract)

This document is the **contract every capability package follows**. The Foundation phase
(this document + `CanopyJni.{h,cpp}`, `CanopyImage.{h,cpp}`, the `canopy/image` package, the
`CanopyBlobs.java` blob bridge, and `ImageModule.java`) built the shared mechanism; every
later capability (Photos, Album, Share, Storage, Notify, Billing, RestoreEngine) plugs into
it **without editing shared wiring**. Read this before adding a capability.

The whole system rests on three already-built layers you do not touch:

- **The ABI** (`host/shared/cpp/CanopyModules.{h,cpp}` + `package/external/native-module.js`):
  one generic dispatcher, never one global per method.
  - `__canopy_call(module, method, argsJson, callId) -> 0|-1`  (JS → host)
  - `__canopy_cancel(callId)`                                   (JS → host)
  - `__canopy_resolve(callId, errJson, resultJson)`            (host → JS, self-installed by JS)
- **The blob registry** (`host/shared/cpp/CanopyBlobs.{h,cpp}`): binary lives native, keyed by
  an `int32` handle; only the int crosses the ABI.
- **The threading invariant**: the `jsi::Runtime` is touched **only on the JS thread**. Async
  work runs anywhere; its completion hops back via `postToJs` before `__canopy_resolve`.

---

## 1. Two ways to build a capability

### A. Pure Java/Kotlin (Photos, Album, Share, Storage, Notify, Billing, Image)

You write **no C++**. You reuse the ONE generic C++ module `canopy::JniModule`
(`host/shared/cpp/CanopyJni.h`). You do **not** hand-register it — you declare it in your
package's `native.json` (§6) and `canopy-native build` GENERATES the registration into the host's
registrant. The generated line is just:

```cpp
reg.registerModule(std::make_shared<canopy::JniModule>("Photos"));
```

`JniModule("Photos").invoke(ctx)` parks `ctx.complete` in a thread-safe pending map keyed by
`callId`, then calls the static Java method:

```java
com.canopyhost.modules.PhotosModule.invoke(String method, String argsJson, String callId)
```

Your Java class does the real async work (picker, decode, network, IPC) on whatever thread it
likes, and when done calls:

```java
com.canopyhost.CanopyHostJni.resolveModule(callId, errJson, resultJson);
// errJson "" (or null) => success;  resultJson is the JSON the caller's decoder reads
```

That native `resolveModule` calls `canopy::jniResolve(callId, …)`, which looks up + erases the
parked completion and invokes it → `postToJs` → `__canopy_resolve` (the C1 hop). The class name
is derived as `com.canopyhost.modules.<Name>Module`, so module `"Photos"` ⇒ `PhotosModule`.

**Optional cancel**: declare `static void cancel(String callId)` on your Java class; `JniModule`
will call it on `__canopy_cancel`. If you can't cancel, omit it — the parked completion is
dropped either way and a late `resolveModule` safely no-ops.

`ImageModule.java` is the **reference** for this style: header-only bounds decode, megapixel
downsample, worker-thread executor, `resolveModule` on completion.

### B. Real C++ NativeModule (RestoreEngine / ORT, anything heavy + pixel-touching)

Subclass `canopy::NativeModule` like `EchoModule` (worker `std::thread` → `ctx.complete`). Read
and write pixels **by blob handle** through `canopy::globalBlobRegistry()` (the same registry the
blob bridge and the renderer use), never as JSON. Streaming (progress, billing updates) uses
`callStreaming`: call `ctx.complete("", "<event>")` repeatedly, then `ctx.complete("", "{\"$done\":true}")`.

> **Effect modules vs. plain modules (Canopy side):** a capability that needs a *subscription*
> (streaming progress) MUST be a `canopy/*` package and declares an `effect module` using
> `Native.Module.callStreaming`. A one-shot `Cmd` is just `Native.Module.call` handed to
> `Task.attempt` in a **plain** module (see `Echo.can`, `Image.can`). Don't reach for an effect
> module unless you have a `subscription`.

---

## 2. The blob bridge (Bitmap ⇄ Blob ⇄ pixels)

Pixels never cross the ABI. A producer puts a Blob and returns its handle in JSON; a consumer
takes the handle in `argsJson`.

**Java side** (`com.canopyhost.CanopyBlobs`):

```java
int    handle = CanopyBlobs.put(bitmap);                 // ARGB_8888-coerced put -> handle (refcount 1)
int    handle = CanopyBlobs.nativeBlobPutBitmap(bitmap); // requires ARGB_8888
Bitmap bmp    = CanopyBlobs.nativeBlobGetBitmap(handle);  // reconstruct (null if unknown/freed)
CanopyBlobs.nativeBlobRelease(handle);                    // drop one ref
```

**C++ side** (`canopy::globalBlobRegistry()`): every native consumer shares this ONE registry.

```cpp
auto blob = canopy::globalBlobRegistry().get(handle);  // std::shared_ptr<Blob>, kind=="rgba8"
// blob->bytes is tightly-packed RGBA8 (R,G,B,A per pixel), width*height*4 bytes
```

**Pixel format**: `Blob.kind == "rgba8"`, straight RGBA8, row-major, no padding. The bridge
strips Bitmap row stride on the way in and re-applies it on the way out.

**Portable compositing** (no JNI): `host/shared/cpp/CanopyImage.h` —
`imageCompositeOver(dst, src, x, y)` and `imageWipeColumns(a, b, splitX)` operate on `"rgba8"`
blobs and return new handles.

---

## 3. Handle discipline (manual refcounting — the GC never sees pixels)

- A **producer** (`decode`/`resize`/`composite`, picker, inference) mints a handle with
  `put()` (refcount 1) and returns `{"image":<handle>, "width":w, "height":h}`.
- A **consumer** (`encodeToFile`, the `CanopyBitmap` renderer, ORT) `get()`s by handle and
  copies out what it needs.
- **`retain()`** when a second independent consumer claims the same handle; **`release()`** on
  every path that is done. A handle consumed by both "display" and "save" must be released
  twice. The Canopy side calls `Image.release` (or the capability's equivalent) per path.
- `BlobRegistry::liveCount()` is the leak assertion: a batch must return to its baseline.

**Producer result shape is fixed**: `{"image":<int handle>, "width":<int>, "height":<int>}`.
Decoders on the Canopy side (`Image.handleDecoder`) read exactly these fields.

---

## 4. Package layout (`canopy/<name>`)

A capability is a real package at `/home/quinten/projects/canopy/<name>/`:

```
<name>/
  canopy.json          type "package", name "canopy/<name>"; depends on canopy/native
  src/<Name>.can       plain module (one-shot Cmds) OR effect module (subscriptions)
  external/<name>.js    thin: documents the wire contract + a Node test-harness mock.
                        Usually NO `foreign import` — calls go through Native.Module.
```

Mirror `canopy/image`'s `canopy.json` (the `canopy/` name prefix is what permits effect
modules; there is no `author` field). Depend on `canopy/native` for `Native.Module`. The
`.can` module routes every op through `Native.Module.call "<Module>" "<method>" args decoder`
(see `Image.can`). `Native.Module.Error` is the shared failure taxonomy
(`ModuleNotFound | Rejected | Decode | Cancelled`).

**Wire marshalling**: JSON strings + ints only, identical to the `__fabric_*` discipline.
Args go out as one `argsJson`; the result is one `resultJson` decoded by the caller's
`Json.Decode.Decoder`. Binary is an int handle, never base64.

---

## 5. Custom views (the `CanopyBitmap` pattern)

To render native pixels (a decoded handle), a capability adds a **component tag**, not an
effect. `canopy/image` ships `CanopyBitmap`:

- Canopy: `Image.bitmap attrs handle` ⇒ `VirtualDom.node "CanopyBitmap"` with a
  `bitmapHandle` **property** (an `Int`). It flows through `facts.a__1_ATTR` →
  `props.__plain.bitmapHandle` → the host's `createView`/`updateProps` as a top-level prop.
- Host: `CanopyHost.makeView`'s DEFAULT case mounts an unknown tag through the
  `CanopyViewRegistry` once `register(tag, factory)` has been called for it — so the host switch
  is never edited per tag.
- A NEW custom tag from a capability package is autolinked: declare it in your `native.json`
  `"viewTags"` (with an `androidFactory` implementing `CanopyComponentFactory`, shipped in your
  package), and `canopy-native build` GENERATES the `CanopyViewRegistry.register(tag, factory)`
  call. No host edit. (`canopy/image`'s built-in `CanopyBitmap` is part of the host's default
  component set; a third-party tag rides the `viewTags` autolink path.)

A handle change is a single targeted `updateProps` — never a re-mount.

---

## 6. You don't edit the host — you ship a `native.json` and the build tool autolinks it

A capability is **self-contained and autolinked**, exactly like a web package ships its own
`external/*.js`. You never touch `canopy/native` or the host shell. There is no "integration
manifest" for a human to apply — that anti-pattern is gone (the hardcoded boot blocks in
`CanopyHostJni.cpp` / `CanopyModuleHost.mm` were deleted in Phase E). Instead:

1. **Ship a self-contained package.** Put your native impl IN the package, next to its `.can`:

   ```
   canopy/<name>/
     canopy.json                       deps (canopy/native for Native.Module)
     native.json                       the autolink manifest (below) — `canopy-native` reads it; the COMPILER never does
     src/<Name>.can                    your Canopy module (routes through Native.Module.call)
     native/android/<Name>Module.java  the JniModule("<Name>") dispatcher
     native/ios/Canopy<Name>Module.mm  the <CanopyModule> twin
     native/cpp/<Name>.cpp             OPTIONAL — only for a C++ NativeModule (e.g. ORT/StoreKit)
   ```

2. **Declare it in `native.json`.** This is the only "registration" — the native analogue of a
   web `foreign import` (`expo-module.config.json` / `react-native.config.js` are the same idea):

   ```jsonc
   {
     "modules": [
       { "name": "<Name>", "kind": "jni" }     // "jni" (default) | "cpp"; add "streaming": [...] for Subs
     ],
     "androidSource": "native/android",
     "iosSource": "native/ios",                 // omit if no iOS twin
     "cppSource": "native/cpp",                 // only for kind=cpp
     "viewTags": ["<MyTag>"],                   // custom host view tags -> generated CanopyViewRegistry.register
     "permissions": {
       "android": ["android.permission.INTERNET"],
       "ios": { "NSPhotoLibraryUsageDescription": "why you need it" }
     },
     "gradleDependencies": ["androidx.exifinterface:exifinterface:1.3.7"],
     "podDependencies": []
   }
   ```

3. **`canopy-native build` autolinks it.** It walks the app's dependency graph, finds every
   package's `native.json`, and GENERATES (into `build/generated/` + the host's gitignored
   autolink fragments — never committed shared files):
   - the **registrant** — `CanopyGeneratedRegistrant.h` (Android `registerModule(...)` calls) and
     `CanopyGeneratedCapsIOS.h` (the iOS `caps[]` array). The boot files `#if __has_include` these
     and call/iterate them; they carry ZERO per-capability knowledge.
   - the **build includes** — a Gradle source-set fragment + CMake fragment (folds your
     `native/android` + `native/cpp` in), an XcodeGen + Podfile fragment (folds your `native/ios`
     + `native/cpp` in), and the merged Android/iOS **permission** fragments.
   - the **view-tag** `CanopyViewRegistry.register(tag, factory)` calls for each `viewTags` entry.

**So adding a capability = adding a dependency.** An app gets `<Name>` by adding
`"canopy/<name>"` to its `canopy.json` and `import <Name>` — **no Java, no Swift, no boot lines,
no build-config edits** in the app or the host. Scaffold the whole self-contained package with:

```
canopy-native gen-capability <Name> --methods m1,m2
```

which emits `canopy/<name>/` with `canopy.json` + `native.json` + `src/<Name>.can` +
`native/android` + `native/ios` + a harness mock, ready to fill in and autolink.

**The two host-resident exceptions** (NOT autolinked, by design — each needs host-specific wiring
the autolinker can't synthesize): **Photos** (its picker rides `MainActivity`'s
`registerForActivityResult`) and **`canopy/inference`'s RestoreEngine** (its model bytes are handed
in after boot). These are the only capabilities the host shell still names directly.

**Files that are now capability-agnostic and must never grow a per-capability line again:**
`CanopyHostJni.cpp`, `CanopyModuleHost.mm`, `CanopyHost.java`/`makeView`, `CMakeLists.txt`,
`project.yml`, `app/build.gradle`, and the tool's `Component.hs`/`Build.hs`.
