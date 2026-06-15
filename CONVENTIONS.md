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
(`host/shared/cpp/CanopyJni.h`). The integrator registers one instance per capability:

```cpp
g_registry->registerModule(std::make_shared<canopy::JniModule>("Photos"));
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
- Host: `CanopyHost.makeView` maps `"CanopyBitmap"` → `ImageView`; `applyProps` reads
  `bitmapHandle` → `CanopyBlobs.nativeBlobGetBitmap(h)` → `imageView.setImageBitmap(bmp)`.
- The component tag must also be added to `native.js`'s KNOWN list and the `tool/` Component
  codegen so the walker emits it. (Foundation lists the exact edits in its manifest.)

A handle change is a single targeted `updateProps` — never a re-mount.

---

## 6. What you may NOT edit (return as a manifest instead)

These are shared wiring; propose edits in your integration manifest, do not modify them:

`host/android/app/src/main/jni/CanopyHostJni.cpp`, `…/java/com/canopyhost/CanopyHost.java`,
`CanopyHostJni.java`, `MainActivity.java`, `app/build.gradle`, `app/src/main/cpp/CMakeLists.txt`,
`package/external/native.js`, `tool/*.hs`.

Create only NEW files: your `canopy/<name>` package, your
`com.canopyhost.modules.<Name>Module.java` (or a C++ `NativeModule` subclass), and any new
shared `host/shared/cpp/*` helpers. Everything else — the one-line module registration, the
CMake source addition, the gradle dep, the `makeView`/`applyProps` case, the component-tag
codegen — is a manifest entry the integrator applies.
