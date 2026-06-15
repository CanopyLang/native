// BillingModule.h — the canopy/billing host module (module "Billing").
//
// WHY A REAL C++ NativeModule (not a bare canopy::JniModule):
// billing has a SUBSCRIPTION (entitlementChanges) — a streaming Sub via
// Native.Module.callStreaming. The shared pure-Java path (canopy::JniModule + jniResolve)
// CANNOT stream: jniResolve erases the pending row on the first resolve (see CanopyJni.h
// §"Streaming is NOT supported through the JNI path"), so a second resolveModule for the
// same callId no-ops. The contract is explicit: "a capability that needs a Sub graduates to
// a real C++ NativeModule with callStreaming." So Billing is that graduated module — the
// same carve-out as the ORT RestoreEngine.
//
// IT STILL DELEGATES THE STORE LOGIC TO JAVA. The one-shot methods (getProducts / purchase /
// restore) are handed to com.canopyhost.modules.BillingModule.invoke(method, argsJson, callId)
// over the SAME shared JNI-module mechanism every pure-Java capability uses: this module parks
// ctx.complete in CanopyJni's pending table (jniRegisterPending) and calls the Java class; the
// Java fake store does the work (and persists the entitlement) and calls back via
// CanopyHostJni.resolveModule(callId, …) → jniResolve → ctx.complete. So the per-call C++ here
// is a thin shim; the real billing logic lives in BillingModule.java (a fake store today, a
// Play Billing swap later — an internal change to that ONE Java file).
//
// THE STREAMING HALF (the part Java's resolveModule can't do):
//   • entitlementChanges: invoke() stores ctx.complete in a process-wide stream-sink list
//     keyed by callId (NOT the erase-on-first-resolve jni table) and immediately emits the
//     current entitlement, so a fresh subscriber gets the lock state at once.
//   • billingEmitEntitlement(json): pushes one entitlement event to EVERY live stream sink
//     (each ctx.complete("", json) hops to the JS thread via the registry's postToJs, exactly
//     like EchoModule::ticks). Java calls this — through the JNI export
//     Java_com_canopyhost_modules_BillingModule_nativeEmit (in BillingModule.cpp) — whenever
//     the entitlement changes (after a purchase, a restore, or a real out-of-band refund).
//   • cancel(callId): drops the stream sink (Process.kill → __canopy_cancel). A terminal
//     {"$done":true} is never sent for a live entitlement feed; it ends only on unsubscribe.
//
// Depends only on the portable CanopyModules.h + the Android CanopyJni.h (for the shared
// jni pending table / callJavaModule / jniEnv). iOS would implement a "Billing" NativeModule
// directly against StoreKit and never include this file.

#pragma once

#include "CanopyModules.h"

#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>

namespace canopy {

class BillingModule : public NativeModule {
 public:
  // The completion-sink type, matching CallContext::complete exactly.
  using Complete = std::function<void(std::string /*errJson*/, std::string /*resultJson*/)>;

  std::string name() const override { return "Billing"; }
  bool invoke(CallContext& ctx) override;
  void cancel(const std::string& callId) override;

  // Push one entitlement event to every live stream sink, caching it to prime future
  // subscribers. Called by the free billingEmitEntitlement() (which the JNI export forwards
  // to). Safe to call from any thread — each sink hops to the JS thread via postToJs.
  void emit(const std::string& entitlementJson);

 private:
  // Live entitlementChanges stream sinks: callId -> ctx.complete. Distinct from CanopyJni's
  // erase-on-resolve pending table precisely because a stream resolves many times. Guarded
  // by mu_.
  std::mutex mu_;
  std::unordered_map<std::string, Complete> streams_;

  // Cache the last entitlement JSON so a newly-registered stream can be primed immediately
  // (matches the Java fake store re-emitting current state on subscribe). Empty until the
  // Java side has emitted at least once.
  std::string lastEntitlementJson_;
};

// The process-wide BillingModule instance the registry registers and the JNI emit forwards
// to. Constructed on first use; lives for the process (same posture as globalBlobRegistry).
std::shared_ptr<BillingModule> globalBillingModule();

// Push one entitlement event (a JSON Entitlement {"isActive":…,"productId":…}) to every live
// entitlementChanges stream sink. Called from Java via the JNI export
// Java_com_canopyhost_modules_BillingModule_nativeEmit. Safe to call from any thread — each
// sink's ctx.complete hops to the JS thread via the registry's postToJs.
void billingEmitEntitlement(const std::string& entitlementJson);

}  // namespace canopy
