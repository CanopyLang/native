// CanopyModules.cpp — portable JSI installer for the __canopy_* native-module ABI.
// Portable across iOS & Android (no platform headers); mirrors CanopyFabric.cpp's style.

#include "CanopyModules.h"

// Optional platform-guarded trace of the ABI's two ends (dispatch entry + resolve exit),
// so the call→worker→postToJs→resolve round-trip is observable in logcat on device. No-op
// off Android; keeps the file portable.
#if defined(__ANDROID__)
#include <android/log.h>
#define CANOPY_TRACE(...) __android_log_print(ANDROID_LOG_INFO, "CanopyABI", __VA_ARGS__)
#else
#define CANOPY_TRACE(...) ((void)0)
#endif

using namespace facebook::jsi;

namespace canopy {

namespace {

// Install one host function as a global named `name` (same primitive as
// CanopyFabric.cpp:36-40). Used ONLY for the dispatcher globals — never per module-method.
void installFn(Runtime& rt, const char* name, unsigned argc, HostFunctionType fn) {
  auto f = Function::createFromHostFunction(rt, PropNameID::forAscii(rt, name), argc, std::move(fn));
  rt.global().setProperty(rt, name, f);
}

std::string asString(Runtime& rt, const Value& v) {
  return v.isString() ? v.getString(rt).utf8(rt) : std::string();
}

}  // namespace

void ModuleRegistry::registerModule(std::shared_ptr<NativeModule> m) {
  if (m) { modules_[m->name()] = std::move(m); }
}

int ModuleRegistry::dispatch(const std::string& module, const std::string& method,
                             const std::string& argsJson, const std::string& callId) {
  CANOPY_TRACE("dispatch: module=%s method=%s callId=%s args=%s",
               module.c_str(), method.c_str(), callId.c_str(), argsJson.c_str());
  auto it = modules_.find(module);
  if (it == modules_.end()) { return -1; }  // (module, method) not found -> JS ModuleNotFound

  {
    std::lock_guard<std::mutex> g(mu_);
    callOwner_[callId] = module;
  }

  CallContext ctx;
  ctx.module = module;
  ctx.method = method;
  ctx.argsJson = argsJson;
  ctx.callId = callId;

  // The completion sink. The module may call this from a worker thread; we capture the
  // runtime + the host's JS-thread post and marshal back onto the JS thread BEFORE touching
  // the runtime. This is the one invariant the whole ABI rests on: jsi::Runtime is only
  // ever touched on its own thread (plan C1 §3.2). Streaming modules call complete()
  // repeatedly; each event hops independently.
  Runtime* rt = rt_;
  auto post = postToJs_;
  std::string owner = callId;
  ctx.complete = [rt, post, owner](std::string err, std::string result) {
    if (rt == nullptr || !post) { return; }
    post([rt, owner, err, result]() {  // now on the JS thread
      canopyResolveCall(*rt, owner, err, result);
    });
  };

  if (!it->second->invoke(ctx)) {  // unknown method on a known module
    std::lock_guard<std::mutex> g(mu_);
    callOwner_.erase(callId);
    return -1;
  }
  return 0;
}

void ModuleRegistry::cancel(const std::string& callId) {
  std::shared_ptr<NativeModule> mod;
  {
    std::lock_guard<std::mutex> g(mu_);
    auto it = callOwner_.find(callId);
    if (it == callOwner_.end()) { return; }  // unknown / already done — safe no-op
    auto m = modules_.find(it->second);
    if (m != modules_.end()) { mod = m->second; }
    callOwner_.erase(it);
  }
  if (mod) { mod->cancel(callId); }
}

void installCanopyModules(Runtime& runtime, std::shared_ptr<ModuleRegistry> registry) {
  // __canopy_call(module, method, argsJson, callId) -> 0 accepted / -1 not found
  installFn(runtime, "__canopy_call", 4,
    [registry](Runtime& rt, const Value&, const Value* a, size_t n) -> Value {
      if (n < 4) { return Value(-1); }
      return Value(registry->dispatch(asString(rt, a[0]), asString(rt, a[1]),
                                      asString(rt, a[2]), asString(rt, a[3])));
    });

  // __canopy_cancel(callId)
  installFn(runtime, "__canopy_cancel", 1,
    [registry](Runtime& rt, const Value&, const Value* a, size_t n) -> Value {
      if (n >= 1) { registry->cancel(asString(rt, a[0])); }
      return Value::undefined();
    });
}

void canopyResolveCall(Runtime& runtime, const std::string& callId,
                       const std::string& errJson, const std::string& resultJson) {
  CANOPY_TRACE("resolve:  callId=%s err=%s result=%s",
               callId.c_str(), errJson.c_str(), resultJson.c_str());
  auto resolve = runtime.global().getProperty(runtime, "__canopy_resolve");
  if (!resolve.isObject() || !resolve.getObject(runtime).isFunction(runtime)) { return; }
  resolve.getObject(runtime).getFunction(runtime).call(
      runtime,
      String::createFromUtf8(runtime, callId),
      errJson.empty() ? Value::null() : Value(String::createFromUtf8(runtime, errJson)),
      resultJson.empty() ? Value::null() : Value(String::createFromUtf8(runtime, resultJson)));
}

}  // namespace canopy
