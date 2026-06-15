// EchoModule.cpp — the C1 reference capability. Portable; no platform headers.

#include "EchoModule.h"

#include <chrono>
#include <thread>

namespace canopy {

std::shared_ptr<std::atomic<bool>> EchoModule::trackCall(const std::string& callId) {
  auto flag = std::make_shared<std::atomic<bool>>(false);
  std::lock_guard<std::mutex> g(mu_);
  cancelFlags_[callId] = flag;
  return flag;
}

void EchoModule::untrackCall(const std::string& callId) {
  std::lock_guard<std::mutex> g(mu_);
  cancelFlags_.erase(callId);
}

void EchoModule::cancel(const std::string& callId) {
  std::lock_guard<std::mutex> g(mu_);
  auto it = cancelFlags_.find(callId);
  if (it != cancelFlags_.end()) { it->second->store(true); }  // worker observes this
}

bool EchoModule::invoke(CallContext& ctx) {
  const std::string method = ctx.method;

  if (method == "send") {
    auto cancelled = trackCall(ctx.callId);
    std::string callId = ctx.callId;
    std::string argsJson = ctx.argsJson;
    auto complete = ctx.complete;
    // OFF the JS thread: a real capability runs ORT/Core ML/StoreKit here for seconds. The
    // worker NEVER touches the runtime — it only calls ctx.complete, which hops to the JS
    // thread via the registry's postToJs.
    std::thread([this, cancelled, callId, argsJson, complete]() {
      std::this_thread::sleep_for(std::chrono::milliseconds(5));  // stand-in for real work
      if (cancelled->load()) {
        complete(R"({"code":"cancelled"})", "");
      } else {
        complete("", argsJson.empty() ? "null" : argsJson);       // echo the args back
      }
      untrackCall(callId);
    }).detach();
    return true;
  }

  if (method == "ticks") {
    auto cancelled = trackCall(ctx.callId);
    std::string callId = ctx.callId;
    auto complete = ctx.complete;
    std::thread([this, cancelled, callId, complete]() {
      // Stream an incrementing counter until cancelled (capped defensively so a leaked
      // subscription can't spin forever).
      for (int i = 1; i <= 100000 && !cancelled->load(); ++i) {
        complete("", std::to_string(i));                          // one streamed event
        std::this_thread::sleep_for(std::chrono::milliseconds(16));
      }
      complete("", R"({"$done":true})");                          // terminal: tear the listener down
      untrackCall(callId);
    }).detach();
    return true;
  }

  return false;  // unknown method -> dispatcher reports -1 / ModuleNotFound
}

}  // namespace canopy
