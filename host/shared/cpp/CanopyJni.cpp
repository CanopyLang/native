// CanopyJni.cpp — the shared JNI-module mechanism + the Bitmap<->Blob bridge.
//
// Android-only (speaks <jni.h> and <android/bitmap.h>), but depends only on the portable
// CanopyModules.h / CanopyBlobs.h. See CanopyJni.h for the full contract.

#include "CanopyJni.h"

#include <android/bitmap.h>
#include <android/log.h>

#include <cstring>

#define CANOPY_JNI_TRACE(...) __android_log_print(ANDROID_LOG_INFO, "CanopyJni", __VA_ARGS__)

namespace canopy {

namespace {

JavaVM* g_vm = nullptr;

// The pending-call table (callId -> ctx.complete). Guarded by g_pendingMu.
std::mutex g_pendingMu;
std::unordered_map<std::string, JniComplete> g_pending;

// Build a thrown-Java-exception error payload, clearing the pending exception so JNI is
// usable again. Returns a small {"code":"rejected","message":...} JSON string.
std::string drainJavaException(JNIEnv* env) {
  if (env->ExceptionCheck()) {
    env->ExceptionDescribe();  // logcat
    env->ExceptionClear();
    return R"({"code":"rejected","message":"java exception in module invoke"})";
  }
  return std::string();
}

}  // namespace

// ---------------------------------------------------------------------------
// JavaVM wiring
// ---------------------------------------------------------------------------

void jniSetJavaVM(JavaVM* vm) { g_vm = vm; }
JavaVM* jniJavaVM() { return g_vm; }

JNIEnv* jniEnv() {
  if (g_vm == nullptr) { return nullptr; }
  JNIEnv* env = nullptr;
  jint rc = g_vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6);
  if (rc == JNI_EDETACHED) {
    if (g_vm->AttachCurrentThread(&env, nullptr) != JNI_OK) { return nullptr; }
  }
  return env;
}

// ---------------------------------------------------------------------------
// Pending-call table
// ---------------------------------------------------------------------------

void jniRegisterPending(const std::string& callId, JniComplete complete) {
  std::lock_guard<std::mutex> g(g_pendingMu);
  g_pending[callId] = std::move(complete);
}

void jniResolve(const std::string& callId, const std::string& errJson,
                const std::string& resultJson) {
  JniComplete complete;
  {
    std::lock_guard<std::mutex> g(g_pendingMu);
    auto it = g_pending.find(callId);
    if (it == g_pending.end()) { return; }  // unknown / cancelled / already resolved — no-op
    complete = std::move(it->second);
    g_pending.erase(it);
  }
  CANOPY_JNI_TRACE("resolve: callId=%s err=%s", callId.c_str(), errJson.c_str());
  if (complete) { complete(errJson, resultJson); }  // -> postToJs -> __canopy_resolve (C1 hop)
}

void jniCancelPending(const std::string& callId) {
  std::lock_guard<std::mutex> g(g_pendingMu);
  g_pending.erase(callId);
}

// ---------------------------------------------------------------------------
// callJavaModule: com.canopyhost.modules.<Name>Module.invoke(method, argsJson, callId)
// ---------------------------------------------------------------------------

bool callJavaModule(const std::string& moduleName, const std::string& method,
                    const std::string& argsJson, const std::string& callId) {
  JNIEnv* env = jniEnv();
  if (env == nullptr) { return false; }

  const std::string className = "com/canopyhost/modules/" + moduleName + "Module";
  jclass cls = env->FindClass(className.c_str());
  if (cls == nullptr) {
    env->ExceptionClear();  // ClassNotFound -> report module-not-found upstream
    CANOPY_JNI_TRACE("callJavaModule: class not found: %s", className.c_str());
    return false;
  }
  jmethodID mid = env->GetStaticMethodID(
      cls, "invoke",
      "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)V");
  if (mid == nullptr) {
    env->ExceptionClear();
    env->DeleteLocalRef(cls);
    CANOPY_JNI_TRACE("callJavaModule: invoke(String,String,String) not found on %s",
                     className.c_str());
    return false;
  }

  jstring jMethod = env->NewStringUTF(method.c_str());
  jstring jArgs = env->NewStringUTF(argsJson.c_str());
  jstring jCallId = env->NewStringUTF(callId.c_str());
  env->CallStaticVoidMethod(cls, mid, jMethod, jArgs, jCallId);

  std::string err = drainJavaException(env);  // if Java threw synchronously, surface it
  if (!err.empty()) {
    // The Java side never got a chance to resolve; resolve the parked completion ourselves.
    jniResolve(callId, err, "");
  }

  env->DeleteLocalRef(jMethod);
  env->DeleteLocalRef(jArgs);
  env->DeleteLocalRef(jCallId);
  env->DeleteLocalRef(cls);
  return true;
}

// ---------------------------------------------------------------------------
// JniModule
// ---------------------------------------------------------------------------

bool JniModule::invoke(CallContext& ctx) {
  // Park the C1 completion sink keyed by callId, THEN hand off to Java. (Park first so a
  // synchronous Java resolveModule — rare but legal — finds the row.)
  jniRegisterPending(ctx.callId, ctx.complete);

  if (!callJavaModule(name_, ctx.method, ctx.argsJson, ctx.callId)) {
    // No Java class / no invoke method: resolve the parked completion with a module-not-found
    // style error and report success-of-dispatch=false so the registry erases its callOwner
    // and JS maps it the same way as an unknown (module, method).
    jniCancelPending(ctx.callId);
    return false;
  }
  return true;
}

void JniModule::cancel(const std::string& callId) {
  // Drop our parked completion; also notify the Java side so it can abort the job. The Java
  // method is OPTIONAL — a capability that can't cancel simply doesn't declare it.
  jniCancelPending(callId);

  JNIEnv* env = jniEnv();
  if (env == nullptr) { return; }
  const std::string className = "com/canopyhost/modules/" + name_ + "Module";
  jclass cls = env->FindClass(className.c_str());
  if (cls == nullptr) { env->ExceptionClear(); return; }
  jmethodID mid = env->GetStaticMethodID(cls, "cancel", "(Ljava/lang/String;)V");
  if (mid != nullptr) {
    jstring jCallId = env->NewStringUTF(callId.c_str());
    env->CallStaticVoidMethod(cls, mid, jCallId);
    env->ExceptionClear();
    env->DeleteLocalRef(jCallId);
  } else {
    env->ExceptionClear();  // no cancel() declared — fine
  }
  env->DeleteLocalRef(cls);
}

// ---------------------------------------------------------------------------
// The one process-wide BlobRegistry
// ---------------------------------------------------------------------------

BlobRegistry& globalBlobRegistry() {
  static BlobRegistry* registry = new BlobRegistry();  // never destroyed; lives for process
  return *registry;
}

// ---------------------------------------------------------------------------
// The Bitmap <-> Blob bridge (C++ side)
// ---------------------------------------------------------------------------

BlobHandle jniBlobPutBitmap(JNIEnv* env, jobject bitmap) {
  if (env == nullptr || bitmap == nullptr) { return 0; }

  AndroidBitmapInfo info;
  if (AndroidBitmap_getInfo(env, bitmap, &info) != ANDROID_BITMAP_RESULT_SUCCESS) {
    CANOPY_JNI_TRACE("blobPut: getInfo failed");
    return 0;
  }
  if (info.format != ANDROID_BITMAP_FORMAT_RGBA_8888) {
    CANOPY_JNI_TRACE("blobPut: not RGBA_8888 (format=%d) — caller must pass ARGB_8888",
                     info.format);
    return 0;
  }

  void* pixels = nullptr;
  if (AndroidBitmap_lockPixels(env, bitmap, &pixels) != ANDROID_BITMAP_RESULT_SUCCESS
      || pixels == nullptr) {
    CANOPY_JNI_TRACE("blobPut: lockPixels failed");
    return 0;
  }

  Blob blob;
  blob.kind = "rgba8";
  blob.width = static_cast<int>(info.width);
  blob.height = static_cast<int>(info.height);
  const size_t tightStride = static_cast<size_t>(info.width) * 4u;
  blob.bytes.resize(tightStride * info.height);
  // Copy row by row to drop any Bitmap row padding (info.stride may exceed width*4).
  const uint8_t* src = static_cast<const uint8_t*>(pixels);
  uint8_t* dst = blob.bytes.data();
  for (uint32_t y = 0; y < info.height; ++y) {
    std::memcpy(dst + y * tightStride, src + static_cast<size_t>(y) * info.stride, tightStride);
  }
  AndroidBitmap_unlockPixels(env, bitmap);

  BlobHandle h = globalBlobRegistry().put(std::move(blob));
  CANOPY_JNI_TRACE("blobPut: handle=%d %dx%d", h, blob.width, blob.height);
  return h;
}

jobject jniBlobGetBitmap(JNIEnv* env, BlobHandle handle) {
  if (env == nullptr) { return nullptr; }
  auto blob = globalBlobRegistry().get(handle);
  if (!blob || blob->kind != "rgba8" || blob->width <= 0 || blob->height <= 0) {
    CANOPY_JNI_TRACE("blobGet: handle=%d not a live rgba8 blob", handle);
    return nullptr;
  }

  // Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
  jclass bitmapCls = env->FindClass("android/graphics/Bitmap");
  jclass configCls = env->FindClass("android/graphics/Bitmap$Config");
  if (bitmapCls == nullptr || configCls == nullptr) { env->ExceptionClear(); return nullptr; }

  jmethodID createMid = env->GetStaticMethodID(
      bitmapCls, "createBitmap",
      "(IILandroid/graphics/Bitmap$Config;)Landroid/graphics/Bitmap;");
  jfieldID argbFid = env->GetStaticFieldID(configCls, "ARGB_8888",
                                           "Landroid/graphics/Bitmap$Config;");
  if (createMid == nullptr || argbFid == nullptr) { env->ExceptionClear(); return nullptr; }

  jobject argbConfig = env->GetStaticObjectField(configCls, argbFid);
  jobject bitmap = env->CallStaticObjectMethod(bitmapCls, createMid,
                                               blob->width, blob->height, argbConfig);
  if (bitmap == nullptr || env->ExceptionCheck()) {
    env->ExceptionClear();
    return nullptr;
  }

  void* pixels = nullptr;
  if (AndroidBitmap_lockPixels(env, bitmap, &pixels) != ANDROID_BITMAP_RESULT_SUCCESS
      || pixels == nullptr) {
    CANOPY_JNI_TRACE("blobGet: lockPixels failed");
    return bitmap;  // return the (uninitialised) bitmap rather than null; still well-formed
  }
  AndroidBitmapInfo info;
  AndroidBitmap_getInfo(env, bitmap, &info);
  const size_t tightStride = static_cast<size_t>(blob->width) * 4u;
  const uint8_t* src = blob->bytes.data();
  uint8_t* dst = static_cast<uint8_t*>(pixels);
  const size_t copyBytes = blob->bytes.size();
  for (int y = 0; y < blob->height; ++y) {
    const size_t off = static_cast<size_t>(y) * tightStride;
    if (off + tightStride > copyBytes) { break; }
    std::memcpy(dst + static_cast<size_t>(y) * info.stride, src + off, tightStride);
  }
  AndroidBitmap_unlockPixels(env, bitmap);
  return bitmap;
}

void jniBlobRelease(BlobHandle handle) {
  globalBlobRegistry().release(handle);
}

BlobHandle jniBlobPutBytes(JNIEnv* env, jbyteArray bytes) {
  if (env == nullptr || bytes == nullptr) { return 0; }
  const jsize n = env->GetArrayLength(bytes);
  Blob blob;
  blob.kind = "bytes";
  blob.width = 0;
  blob.height = 0;
  blob.bytes.resize(static_cast<size_t>(n));
  if (n > 0) {
    env->GetByteArrayRegion(bytes, 0, n, reinterpret_cast<jbyte*>(blob.bytes.data()));
  }
  BlobHandle h = globalBlobRegistry().put(std::move(blob));
  CANOPY_JNI_TRACE("blobPutBytes: handle=%d len=%d", h, static_cast<int>(n));
  return h;
}

jbyteArray jniBlobGetBytes(JNIEnv* env, BlobHandle handle) {
  if (env == nullptr) { return nullptr; }
  auto blob = globalBlobRegistry().get(handle);
  if (!blob) { return nullptr; }
  const jsize n = static_cast<jsize>(blob->bytes.size());
  jbyteArray arr = env->NewByteArray(n);
  if (arr == nullptr) { return nullptr; }
  if (n > 0) {
    env->SetByteArrayRegion(arr, 0, n, reinterpret_cast<const jbyte*>(blob->bytes.data()));
  }
  return arr;
}

}  // namespace canopy

// ===========================================================================
// JNI ENTRY POINTS for com.canopyhost.CanopyBlobs (the blob bridge) and
// com.canopyhost.CanopyHostJni.resolveModule (the JNI-module resolve path).
//
// These are the ONLY exported symbols. They forward to the canopy:: functions above. The
// host's CanopyHostJni.cpp does NOT need to declare them — they live here and are linked
// into the same libcanopyhost.so.
// ===========================================================================

extern "C" {

// com.canopyhost.CanopyBlobs.nativeBlobPutBitmap(Bitmap) : int
JNIEXPORT jint JNICALL
Java_com_canopyhost_CanopyBlobs_nativeBlobPutBitmap(JNIEnv* env, jclass, jobject bitmap) {
  return static_cast<jint>(canopy::jniBlobPutBitmap(env, bitmap));
}

// com.canopyhost.CanopyBlobs.nativeBlobGetBitmap(int) : Bitmap
JNIEXPORT jobject JNICALL
Java_com_canopyhost_CanopyBlobs_nativeBlobGetBitmap(JNIEnv* env, jclass, jint handle) {
  return canopy::jniBlobGetBitmap(env, static_cast<canopy::BlobHandle>(handle));
}

// com.canopyhost.CanopyBlobs.nativeBlobRelease(int) : void
JNIEXPORT void JNICALL
Java_com_canopyhost_CanopyBlobs_nativeBlobRelease(JNIEnv*, jclass, jint handle) {
  canopy::jniBlobRelease(static_cast<canopy::BlobHandle>(handle));
}

// com.canopyhost.CanopyBlobs.nativeBlobPutBytes(byte[]) : int
JNIEXPORT jint JNICALL
Java_com_canopyhost_CanopyBlobs_nativeBlobPutBytes(JNIEnv* env, jclass, jbyteArray bytes) {
  return static_cast<jint>(canopy::jniBlobPutBytes(env, bytes));
}

// com.canopyhost.CanopyBlobs.nativeBlobGetBytes(int) : byte[]
JNIEXPORT jbyteArray JNICALL
Java_com_canopyhost_CanopyBlobs_nativeBlobGetBytes(JNIEnv* env, jclass, jint handle) {
  return canopy::jniBlobGetBytes(env, static_cast<canopy::BlobHandle>(handle));
}

// com.canopyhost.CanopyHostJni.resolveModule(String callId, String errJson, String resultJson)
// Called from a Java capability when its async work finishes. errJson "" / null => success.
JNIEXPORT void JNICALL
Java_com_canopyhost_CanopyHostJni_resolveModule(JNIEnv* env, jclass, jstring callId,
                                                jstring errJson, jstring resultJson) {
  auto str = [env](jstring s) -> std::string {
    if (s == nullptr) { return std::string(); }
    const char* c = env->GetStringUTFChars(s, nullptr);
    std::string out(c ? c : "");
    if (c) { env->ReleaseStringUTFChars(s, c); }
    return out;
  };
  canopy::jniResolve(str(callId), str(errJson), str(resultJson));
}

}  // extern "C"
