// StreamingJniModule.h — the generic streaming-capable host module (Navigation/Lifecycle, C2).
//
// WHY THIS EXISTS (the streaming carve-out, generalized):
// Pure-Java capabilities reuse canopy::JniModule + jniResolve. But jniResolve ERASES the
// pending row on the first resolve (see CanopyJni.h §"Streaming is NOT supported through the
// JNI path"), so a SUBSCRIPTION (a Sub that emits many events on one callId) cannot ride it.
// canopy/billing solved this with a bespoke BillingModule that owns its stream sinks; this
// class is that pattern GENERALIZED so any subscription-bearing capability can reuse ONE C++
// class by name instead of writing its own. canopy/navigation (Lifecycle + AppShell) is the
// first consumer: appState / memoryPressure / backPressed (Lifecycle) and colorScheme
// (AppShell) are all live Subs.
//
// THE SHAPE (identical posture to BillingModule, but multi-channel + generic):
//   • One-shot methods (allowDefaultBack, setStatusBarStyle): delegated to Java EXACTLY like
//     canopy::JniModule — park ctx.complete in CanopyJni's pending table (jniRegisterPending)
//     and call com.canopyhost.modules.<Name>Module.invoke(method, argsJson, callId); the Java
//     class resolves via CanopyHostJni.resolveModule -> jniResolve -> ctx.complete (erased).
//     Whether a method is one-shot vs. streaming is decided by the Java side: a streaming
//     method is one this module was told to treat as a channel (see registerStreaming below).
//   • Streaming methods (the Subs): invoke() stores ctx.complete in a per-CHANNEL sink list
//     keyed by callId (NOT the erase-on-resolve jni table). The "channel" is just the method
//     name (appState, memoryPressure, backPressed, colorScheme). On first subscribe we ALSO
//     notify Java (a one-way invoke with a sentinel callId="") so the Java side can begin
//     observing the OS (register ProcessLifecycleOwner / onTrimMemory / the back dispatcher /
//     a uiMode listener) lazily; if a cached last value exists we prime the new subscriber.
//   • emit(channel, json): pushes one event to EVERY live sink subscribed on that channel,
//     caching it to prime future subscribers — exactly BillingModule::emit, but per-channel.
//     Each sink's ctx.complete hops to the JS thread via the registry's postToJs, so emit is
//     safe to call from any thread (the main Looper after onTrimMemory, a back-press callback).
//   • cancel(callId): drops the sink from whatever channel holds it (Process.kill ->
//     __canopy_cancel) and also drops any parked one-shot row.
//
// THE JNI EMIT BRIDGE: Java pushes events via the export
//   Java_com_canopyhost_modules_StreamingBridge_nativeEmit(String moduleName, String channel,
//                                                           String eventJson)
// (defined in StreamingJniModule.cpp). It routes to the named module's emit(channel, json).
// This is the ONE new exported symbol this file adds; it links into libcanopyhost.so beside
// the rest. Modules are looked up in a process-wide registry this class self-populates on
// construction (globalStreamingModule(name)).
//
// Depends only on the portable CanopyModules.h + the Android CanopyJni.h (for the shared jni
// pending table / callJavaModule / jniCancelPending). iOS would implement equivalent
// NativeModules directly against UIKit (UIApplication.statusBarStyle, NSNotificationCenter
// for app state / memory warnings / trait collection) and never include this file.

#pragma once

#include "CanopyModules.h"

#include <functional>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <unordered_map>

namespace canopy {

class StreamingJniModule : public NativeModule {
 public:
  using Complete = std::function<void(std::string /*errJson*/, std::string /*resultJson*/)>;

  // `name` is the module name routed on by __canopy_call (e.g. "Lifecycle", "AppShell").
  // `streamingMethods` is the set of method names that are SUBSCRIPTIONS (channels); every
  // other method is treated as a one-shot delegated to Java. The Java class is derived as
  // com.canopyhost.modules.<name>Module exactly like canopy::JniModule.
  StreamingJniModule(std::string name, std::set<std::string> streamingMethods);

  std::string name() const override { return name_; }
  bool invoke(CallContext& ctx) override;
  void cancel(const std::string& callId) override;

  // Push one event to every live sink subscribed on `channel`, caching it to prime future
  // subscribers. Safe from any thread (each sink hops to the JS thread via postToJs).
  void emit(const std::string& channel, const std::string& eventJson);

 private:
  bool isStreaming(const std::string& method) const {
    return streamingMethods_.count(method) != 0;
  }

  std::string name_;
  std::set<std::string> streamingMethods_;

  std::mutex mu_;
  // channel -> (callId -> sink). A channel is a streaming method name; each subscriber is one
  // open call. Distinct from CanopyJni's erase-on-resolve table because a stream resolves many
  // times.
  std::unordered_map<std::string, std::unordered_map<std::string, Complete>> streams_;
  // channel -> last emitted event JSON, to prime a fresh subscriber. Empty until first emit.
  std::unordered_map<std::string, std::string> lastByChannel_;
};

// The process-wide instance for `name`, created on first lookup with the given streaming
// methods. Subsequent lookups ignore the methods arg and return the existing instance. The
// integrator registers the SAME shared_ptr into the ModuleRegistry, and the JNI emit bridge
// routes to it by name. (Same lifetime posture as globalBillingModule / globalBlobRegistry.)
std::shared_ptr<StreamingJniModule> globalStreamingModule(
    const std::string& name, std::set<std::string> streamingMethods = {});

// Push one event to the named module's `channel`. Called from Java via the JNI export
// Java_com_canopyhost_modules_StreamingBridge_nativeEmit. No-op if the module was never
// created. Safe from any thread.
void streamingEmit(const std::string& moduleName, const std::string& channel,
                   const std::string& eventJson);

}  // namespace canopy
