// CanopyJni.h — the shared JNI-module mechanism (Foundation, C2).
//
// This is the ONE piece of Android-specific glue every PURE-JAVA/KOTLIN capability
// (Photos, Album, Share, Storage, Notify, Billing, Image) is built on, so none of them
// has to write C++. It is the JNI sibling of EchoModule: where EchoModule does its async
// work on a C++ std::thread and calls ctx.complete(), a canopy::JniModule instead hands
// the work to a Java class (com.canopyhost.modules.<Name>Module) and lets THAT do the
// async work, calling back through CanopyHostJni.resolveModule(callId, …) when done.
//
// THE CONTRACT (one generic C++ module class, one Java class per capability):
//
//   JS:  Native.Module.call("Photos", "pick", argsJson, decoder)
//         -> __canopy_call("Photos","pick",argsJson,callId)          (CanopyModules.cpp)
//         -> ModuleRegistry::dispatch -> JniModule("Photos").invoke(ctx)
//              registers ctx.complete in a pending map keyed by callId  (jniRegisterPending)
//              calls com.canopyhost.modules.PhotosModule.invoke(method, argsJson, callId)
//   Java: PhotosModule does the real async work (picker, decode, network, …) then calls
//         CanopyHostJni.resolveModule(callId, errJson, resultJson)
//         -> native jniResolve(callId, errJson, resultJson)            (this file)
//              looks up + erases the pending complete, calls it
//         -> ctx.complete -> postToJs -> __canopy_resolve               (the C1 hop)
//
// So the threading invariant is identical to EchoModule's: the capability's async work
// NEVER touches the jsi::Runtime; only ctx.complete (→ postToJs) does. The Java side runs
// on whatever thread it likes (a worker, the main Looper after a picker result, an OkHttp
// callback); resolveModule just needs the callId.
//
// This header also owns:
//   • the BLOB BRIDGE C++ side (jniBlobPutBitmap / jniBlobGetBitmap / jniBlobRelease) so
//     Java capabilities can move android.graphics.Bitmap pixels in/out of the ONE shared
//     C1 BlobRegistry — binary never crosses the ABI as JSON, only as an int handle.
//   • globalBlobRegistry(): the single process-wide BlobRegistry every native consumer
//     (the blob bridge, the host's CanopyBitmap renderer, the ORT RestoreEngine) shares,
//     so a handle minted in ImageModule.decode is the same handle ORT and the renderer see.
//
// Android-only by nature (it speaks <jni.h>), but it depends ONLY on the portable
// CanopyModules.h / CanopyBlobs.h — no React, no platform-view headers. iOS capabilities
// implement NativeModule directly in Objective-C++ and never include this file.

#pragma once

#include "CanopyModules.h"
#include "CanopyBlobs.h"

#include <jni.h>

#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>

namespace canopy {

// ---------------------------------------------------------------------------
// JavaVM wiring. The host's JNI_OnLoad (CanopyHostJni.cpp) already caches the JavaVM;
// it passes it here once at boot so JniModule::invoke and the blob bridge can reach JNI
// from any thread (AttachCurrentThread). Set exactly once, before any call can arrive.
// ---------------------------------------------------------------------------
void jniSetJavaVM(JavaVM* vm);
JavaVM* jniJavaVM();

// Attach the current thread to the JVM and return its JNIEnv (idempotent; a thread already
// attached is returned as-is). Used by JniModule::invoke (called on the JS thread) and by
// the blob bridge JNI fns (called on whatever thread Java invoked them from).
JNIEnv* jniEnv();

// ---------------------------------------------------------------------------
// The pending-call table: callId -> the C1 completion sink (ctx.complete). JniModule::invoke
// parks ctx.complete here keyed by callId; jniResolve (called from Java via the native
// CanopyHostJni.resolveModule) looks it up, invokes it, and erases it. Thread-safe.
//
// Streaming is NOT supported through the JNI path in C2 (pure-Java capabilities are all
// one-shot Cmds: pick, decode, save, share). A capability that needs a Sub graduates to a
// real C++ NativeModule with callStreaming, exactly like the ORT RestoreEngine. So jniResolve
// always erases — one completion per callId.
// ---------------------------------------------------------------------------
using JniComplete = std::function<void(std::string /*errJson*/, std::string /*resultJson*/)>;

void jniRegisterPending(const std::string& callId, JniComplete complete);

// Look up the pending completion for callId, invoke it (errJson "" => success, exactly the
// CallContext::complete contract), and erase the row. No-op if the callId is unknown (the
// call was cancelled, already resolved, or never registered) — safe and idempotent, the
// same posture as __canopy_resolve's `if (!p) return`.
void jniResolve(const std::string& callId, const std::string& errJson, const std::string& resultJson);

// Drop a pending row without resolving it (cancel). Best-effort; a Java job already in flight
// may still call resolveModule later, and jniResolve will then no-op.
void jniCancelPending(const std::string& callId);

// ---------------------------------------------------------------------------
// JniModule — the generic NativeModule every pure-Java/Kotlin capability reuses. Construct
// one per capability name and register it; it owns no per-method logic. Its invoke() parks
// ctx.complete keyed by callId, then calls the static Java method
//   com.canopyhost.modules.<Name>Module.invoke(String method, String argsJson, String callId)
// and returns true. The Java class does the real work and calls back via resolveModule.
//
//   registry.registerModule(std::make_shared<canopy::JniModule>("Photos"));
//   registry.registerModule(std::make_shared<canopy::JniModule>("Image"));
//   registry.registerModule(std::make_shared<canopy::JniModule>("Share"));
//
// The Java class name is derived as "com.canopyhost.modules." + name + "Module", so module
// "Image" -> com.canopyhost.modules.ImageModule. A missing Java class (or a thrown Java
// exception) resolves the call with a {"code":"rejected"} error rather than crashing.
// ---------------------------------------------------------------------------
class JniModule : public NativeModule {
 public:
  explicit JniModule(std::string name) : name_(std::move(name)) {}

  std::string name() const override { return name_; }
  bool invoke(CallContext& ctx) override;
  void cancel(const std::string& callId) override;

 private:
  std::string name_;
};

// Low-level: call com.canopyhost.modules.<moduleName>Module.invoke(method, argsJson, callId)
// over JNI. Returns true if the static method was found and called; false if the class or
// method was missing (so the caller can resolve a ModuleNotFound-style error). Used by
// JniModule::invoke; exposed for tests/diagnostics.
bool callJavaModule(const std::string& moduleName, const std::string& method,
                    const std::string& argsJson, const std::string& callId);

// ---------------------------------------------------------------------------
// The ONE process-wide BlobRegistry. Every native consumer shares it: the blob bridge
// (Java Bitmap <-> Blob), the host's CanopyBitmap renderer, and the ORT RestoreEngine.
// Constructed on first use; lives for the process. The host does NOT need its own g_blobs
// once everything routes through this — but for back-compat the host may set its g_blobs
// to &globalBlobRegistry() (see the integration manifest).
// ---------------------------------------------------------------------------
BlobRegistry& globalBlobRegistry();

// ---------------------------------------------------------------------------
// The BLOB BRIDGE (C++ side). These are the bodies of the native methods declared in
// com.canopyhost.CanopyBlobs.java; the JNI entry points in CanopyJni.cpp forward to them.
//
//   • jniBlobPutBitmap(env, bitmap): read an ARGB_8888 android.graphics.Bitmap into a fresh
//     "rgba8" Blob (premultiplied RGBA, row-major, width*height*4 bytes), put it in the
//     global registry (refcount 1), and return the int handle. Returns 0 on failure.
//   • jniBlobGetBitmap(env, handle): create a new ARGB_8888 android.graphics.Bitmap from the
//     "rgba8" Blob behind handle and return it (a local ref). nullptr if the handle is
//     unknown/freed or not a bitmap blob.
//   • jniBlobRelease(handle): release one reference on the handle (frees at zero).
//
// Pixel format note: android Bitmap ARGB_8888 stores bytes as R,G,B,A in memory (the
// Java int is 0xAARRGGBB but Bitmap.copyPixelsToBuffer yields R,G,B,A byte order on
// little-endian via getPixels? — we use the byte-buffer path which is R,G,B,A premultiplied).
// The Blob.kind is "rgba8"; consumers (ORT) read it as tightly-packed RGBA8.
// ---------------------------------------------------------------------------
BlobHandle jniBlobPutBitmap(JNIEnv* env, jobject bitmap);
jobject    jniBlobGetBitmap(JNIEnv* env, BlobHandle handle);
void       jniBlobRelease(BlobHandle handle);

//   • jniBlobPutBytes(env, byte[]): copy a Java byte[] into a fresh "bytes" Blob, return its
//     handle (refcount 1). The currency for NON-bitmap binary across the C1 ABI — Http bodies,
//     filesystem reads, picked-file bytes, model tensors — so capabilities move binary as an int
//     handle, never base64 through JSON.
//   • jniBlobGetBytes(env, handle): a new (copied) Java byte[] of the bytes behind a handle,
//     null if the handle is unknown/freed.
BlobHandle jniBlobPutBytes(JNIEnv* env, jbyteArray bytes);
jbyteArray jniBlobGetBytes(JNIEnv* env, BlobHandle handle);

}  // namespace canopy
