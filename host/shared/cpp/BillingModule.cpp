// BillingModule.cpp — the canopy/billing host module (module "Billing"). See BillingModule.h.
//
// Android-leaning (the one-shot delegation + the nativeEmit JNI export speak <jni.h> via
// CanopyJni.h), but the streaming half is portable C++. The one-shot methods reuse the SAME
// shared JNI-module mechanism every pure-Java capability uses; only entitlementChanges needs
// the real-NativeModule streaming path.

#include "BillingModule.h"

#if defined(__ANDROID__)
#include "CanopyJni.h"  // jniRegisterPending / callJavaModule / jniCancelPending (Android)
#include <jni.h>
#endif

#include <vector>

namespace canopy {

namespace {

// The set of one-shot methods we delegate to Java unchanged (park ctx.complete in the shared
// jni pending table, call com.canopyhost.modules.BillingModule.invoke, resolve once).
bool isOneShot(const std::string& method) {
  return method == "getProducts" || method == "purchase" || method == "restore";
}

}  // namespace

std::shared_ptr<BillingModule> globalBillingModule() {
  static std::shared_ptr<BillingModule> instance = std::make_shared<BillingModule>();
  return instance;
}

bool BillingModule::invoke(CallContext& ctx) {
  const std::string method = ctx.method;

  // ---- one-shot: getProducts / purchase / restore -> delegate to Java ---------------------
  // Identical to canopy::JniModule::invoke: park the completion keyed by callId, then hand
  // off to the Java fake store. Java does the work (and persists/acknowledges) and calls
  // CanopyHostJni.resolveModule(callId, …) -> jniResolve -> this same ctx.complete (erased).
  if (isOneShot(method)) {
#if defined(__ANDROID__)
    jniRegisterPending(ctx.callId, ctx.complete);
    if (!callJavaModule(name(), ctx.method, ctx.argsJson, ctx.callId)) {
      jniCancelPending(ctx.callId);
      return false;  // no Java class/method -> dispatcher reports ModuleNotFound
    }
    return true;
#else
    // iOS: the ObjC CanopyBillingModule (StoreKit) is the registered "Billing" module and
    // handles the one-shots; this portable module is reused only for the streaming half.
    return false;
#endif
  }

  // ---- streaming: entitlementChanges -> a live sink this module owns -----------------------
  if (method == "entitlementChanges") {
    std::string primed;
    {
      std::lock_guard<std::mutex> g(mu_);
      streams_[ctx.callId] = ctx.complete;
      primed = lastEntitlementJson_;
    }
    // Prime a fresh subscriber with the current entitlement (if Java has emitted one yet), so
    // the UI's lock state is correct without waiting for the next change. We DO NOT send a
    // terminal {"$done":true}: an entitlement feed is open-ended; it ends only on unsubscribe.
    if (!primed.empty()) {
      ctx.complete("", primed);  // -> postToJs -> __canopy_resolve (a streamed event)
    }
    return true;  // keep the call open
  }

  return false;  // unknown method -> dispatcher reports -1 / ModuleNotFound
}

void BillingModule::cancel(const std::string& callId) {
  // Drop a stream sink (Process.kill -> __canopy_cancel). Also drop any parked one-shot row
  // in the shared jni table (best-effort; a Java job already in flight resolves to a no-op).
  {
    std::lock_guard<std::mutex> g(mu_);
    streams_.erase(callId);
  }
#if defined(__ANDROID__)
  jniCancelPending(callId);
#endif
}

void BillingModule::emit(const std::string& entitlementJson) {
  std::vector<Complete> sinks;
  {
    std::lock_guard<std::mutex> g(mu_);
    lastEntitlementJson_ = entitlementJson;  // cache for priming future subscribers
    sinks.reserve(streams_.size());
    for (auto& kv : streams_) { sinks.push_back(kv.second); }
  }
  // Each sink's ctx.complete hops to the JS thread via the registry's postToJs (the same hop
  // EchoModule::ticks rides), so this is safe to call from any thread — e.g. the Java worker
  // that just persisted a purchase.
  for (auto& sink : sinks) {
    if (sink) { sink("", entitlementJson); }
  }
}

void billingEmitEntitlement(const std::string& entitlementJson) {
  globalBillingModule()->emit(entitlementJson);
}

}  // namespace canopy

// ===========================================================================
// JNI ENTRY POINT for com.canopyhost.modules.BillingModule.nativeEmit(String).
//
// The Java fake store calls this whenever the entitlement changes (after purchase / restore,
// or — with real Play Billing — an out-of-band refund/lapse), to push the new entitlement to
// every live entitlementChanges Sub. This is the ONE new exported symbol billing adds; it
// lives here and links into the same libcanopyhost.so as the rest. (One-shot resolves still
// go through the shared Java_com_canopyhost_CanopyHostJni_resolveModule in CanopyJni.cpp.)
// ===========================================================================

#if defined(__ANDROID__)
extern "C" {

JNIEXPORT void JNICALL
Java_com_canopyhost_modules_BillingModule_nativeEmit(JNIEnv* env, jclass, jstring entitlementJson) {
  if (entitlementJson == nullptr) { return; }
  const char* c = env->GetStringUTFChars(entitlementJson, nullptr);
  std::string json(c ? c : "");
  if (c) { env->ReleaseStringUTFChars(entitlementJson, c); }
  canopy::billingEmitEntitlement(json);
}

}  // extern "C"
#endif  // __ANDROID__
