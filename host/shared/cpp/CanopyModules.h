// CanopyModules.h — the portable C++ native-module ABI (plan C1 §2.4).
//
// This is the effect-system sibling of CanopyFabric.h. CanopyFabric installs the
// __fabric_* RENDER surface; CanopyModules installs the __canopy_* EFFECT surface —
// the single generic dispatcher every Canopy native capability (image decode, ORT/Core
// ML inference, StoreKit/Play Billing, photo picker, share, notifications) is invoked
// through. It is the C++ counterpart of external/native-module.js.
//
// THE ABI (one generic dispatcher, never one global per method):
//   __canopy_call(module, method, argsJson, callId) -> 0 accepted / -1 not found  JS->host
//   __canopy_cancel(callId)                          -> void                        JS->host
//   __canopy_resolve(callId, errJson, resultJson)    -> void   (host CALLS this)    host->JS
//
// A capability is a NativeModule registered into a ModuleRegistry; registering adds NO
// new JSI global. The dispatcher routes (module, method) to the module, which may run
// inline or hand work to a worker thread and call ctx.complete() later — from ANY thread.
// The registry marshals that completion back onto the JS thread (postToJs) before invoking
// __canopy_resolve, so the single-threaded Hermes runtime is only ever touched on its own
// thread. This is the generalization of CanopyFabric's requestFrame hop (CanopyFabric.cpp
// :89-96) into a reusable postToJs(std::function<void()>).
//
// Survival rule (architecture.md §3): like CanopyFabric, this binds JS only to a tiny,
// stable surface (3 globals). No platform headers, no React component headers — portable
// across iOS and Android. Platform-specific capabilities (StoreKit, PHPicker, Play Billing)
// implement NativeModule in their own platform file and self-register; the shared C++
// never mentions them.

#pragma once

#include <jsi/jsi.h>

#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>

namespace canopy {

// One in-flight call handed to a module. `complete` is the thread-safe completion sink
// the module calls when its work finishes (errJson "" = success). It may be called from a
// worker thread, and repeatedly for a stream (each event errJson="", a final
// {"$done":true} resultJson tears the JS-side listener down).
struct CallContext {
  std::string module;
  std::string method;
  std::string argsJson;
  std::string callId;
  std::function<void(std::string /*errJson*/, std::string /*resultJson*/)> complete;
};

// What a native capability implements. `name()` is the PascalCase capability name matching
// the .can module ("Echo", "RestoreEngine", "Billing", …).
class NativeModule {
 public:
  virtual ~NativeModule() = default;

  // The capability name routed on by __canopy_call(module, …).
  virtual std::string name() const = 0;

  // Dispatch one call. Sync modules call ctx.complete() before returning; async modules
  // kick off worker-thread work and call ctx.complete() later. Return false if `method`
  // is unknown (the dispatcher then reports -1 / ModuleNotFound to JS).
  virtual bool invoke(CallContext& ctx) = 0;

  // Cancel an in-flight call previously started under `callId`. Best-effort and idempotent:
  // a job that already completed may still resolve, and the JS side drops it.
  virtual void cancel(const std::string& /*callId*/) {}
};

// The dispatcher. The host creates one, wires the runtime + the JS-thread post, registers
// modules, and installs the three globals. Thread-safe for registration-at-boot + the
// callId bookkeeping cancel() needs.
class ModuleRegistry {
 public:
  // The Hermes runtime, and the host-owned hop that runs a fn ON the JS thread (Looper on
  // Android, the main run loop on iOS) — the generalization of requestFrame. Both set once
  // by the host at boot, before any call can arrive.
  void setRuntime(facebook::jsi::Runtime* rt) { rt_ = rt; }
  void setPostToJs(std::function<void(std::function<void()>)> post) { postToJs_ = std::move(post); }

  // Register a capability. Adds NO new JSI global. Safe to call from shared boot or from a
  // platform host file (a Swift/Kotlin-backed module self-registers).
  void registerModule(std::shared_ptr<NativeModule> m);

  // Invoked by __canopy_call. Builds the CallContext (whose complete() hops to the JS
  // thread) and dispatches. Returns 0 accepted / -1 (module, method) not found.
  int dispatch(const std::string& module, const std::string& method,
               const std::string& argsJson, const std::string& callId);

  // Invoked by __canopy_cancel. Routes to the owning module's cancel().
  void cancel(const std::string& callId);

 private:
  facebook::jsi::Runtime* rt_ = nullptr;
  std::function<void(std::function<void()>)> postToJs_;
  std::unordered_map<std::string, std::shared_ptr<NativeModule>> modules_;
  std::mutex mu_;                                         // guards callOwner_
  std::unordered_map<std::string, std::string> callOwner_;  // callId -> module name (for cancel)
};

// Installs __canopy_call + __canopy_cancel onto `runtime`, backed by `registry`. Call once,
// right after installCanopyFabric and before evaluating the bundle. (__canopy_resolve is
// self-installed by external/native-module.js, exactly as native.js self-installs
// __canopy_dispatchEvent — the host only CALLS it, via canopyResolveCall.)
void installCanopyModules(facebook::jsi::Runtime& runtime, std::shared_ptr<ModuleRegistry> registry);

// Deliver a module-call completion (or streamed event) into JS on the JS thread: invokes
// globalThis.__canopy_resolve(callId, errJson, resultJson). errJson "" => success;
// resultJson "" => error. Called only from inside a postToJs hop. The module analogue of
// canopyEmitEvent (CanopyFabric.cpp:99-108).
void canopyResolveCall(facebook::jsi::Runtime& runtime, const std::string& callId,
                       const std::string& errJson, const std::string& resultJson);

}  // namespace canopy
