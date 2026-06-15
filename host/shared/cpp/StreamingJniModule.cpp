// StreamingJniModule.cpp — the generic streaming-capable host module. See the header.
//
// Android-leaning (the one-shot delegation + the nativeEmit JNI export speak <jni.h> via
// CanopyJni.h), but the streaming bookkeeping is portable C++. Modeled on BillingModule.cpp.

#include "StreamingJniModule.h"

#include "CanopyJni.h"  // jniRegisterPending / callJavaModule / jniCancelPending (Android)

#include <jni.h>

#include <mutex>
#include <unordered_map>
#include <vector>

namespace canopy {

namespace {

// The process-wide table of streaming modules by name, so the JNI emit bridge can find one.
std::mutex g_modulesMu;
std::unordered_map<std::string, std::shared_ptr<StreamingJniModule>> g_modules;

}  // namespace

StreamingJniModule::StreamingJniModule(std::string name, std::set<std::string> streamingMethods)
    : name_(std::move(name)), streamingMethods_(std::move(streamingMethods)) {}

std::shared_ptr<StreamingJniModule> globalStreamingModule(const std::string& name,
                                                          std::set<std::string> streamingMethods) {
  std::lock_guard<std::mutex> g(g_modulesMu);
  auto it = g_modules.find(name);
  if (it != g_modules.end()) { return it->second; }
  auto m = std::make_shared<StreamingJniModule>(name, std::move(streamingMethods));
  g_modules[name] = m;
  return m;
}

bool StreamingJniModule::invoke(CallContext& ctx) {
  const std::string method = ctx.method;

  // ---- streaming: a Sub channel -> a live sink this module owns ---------------------------
  if (isStreaming(method)) {
    std::string primed;
    bool firstOnChannel = false;
    {
      std::lock_guard<std::mutex> g(mu_);
      auto& channel = streams_[method];
      firstOnChannel = channel.empty();
      channel[ctx.callId] = ctx.complete;
      auto last = lastByChannel_.find(method);
      if (last != lastByChannel_.end()) { primed = last->second; }
    }
    // First subscriber on this channel: tell Java to begin observing the OS for it (register a
    // ProcessLifecycleOwner observer / onTrimMemory / the back dispatcher / a uiMode listener).
    // A one-way notify with a sentinel callId="" — the Java side does NOT resolve it; it just
    // starts the observation and later pushes events via nativeEmit. Idempotent on the Java
    // side (subscribing twice is a no-op there).
    if (firstOnChannel) {
      callJavaModule(name_, method, ctx.argsJson, std::string());
    }
    // Prime a fresh subscriber with the last known value (if any) so the UI is correct at once
    // without waiting for the next change. No terminal {"$done":true}: these feeds are
    // open-ended and end only on unsubscribe.
    if (!primed.empty()) {
      ctx.complete("", primed);  // -> postToJs -> __canopy_resolve (a streamed event)
    }
    return true;  // keep the call open
  }

  // ---- one-shot: delegate to Java exactly like canopy::JniModule --------------------------
  jniRegisterPending(ctx.callId, ctx.complete);
  if (!callJavaModule(name_, ctx.method, ctx.argsJson, ctx.callId)) {
    jniCancelPending(ctx.callId);
    return false;  // no Java class/method -> dispatcher reports ModuleNotFound
  }
  return true;
}

void StreamingJniModule::cancel(const std::string& callId) {
  // Drop the sink from whatever channel holds it (Process.kill -> __canopy_cancel). Also drop
  // any parked one-shot row (best-effort; a Java job already in flight resolves to a no-op).
  {
    std::lock_guard<std::mutex> g(mu_);
    for (auto& kv : streams_) { kv.second.erase(callId); }
  }
  jniCancelPending(callId);
}

void StreamingJniModule::emit(const std::string& channel, const std::string& eventJson) {
  std::vector<Complete> sinks;
  {
    std::lock_guard<std::mutex> g(mu_);
    lastByChannel_[channel] = eventJson;  // cache to prime future subscribers
    auto it = streams_.find(channel);
    if (it != streams_.end()) {
      sinks.reserve(it->second.size());
      for (auto& kv : it->second) { sinks.push_back(kv.second); }
    }
  }
  // Each sink's ctx.complete hops to the JS thread via the registry's postToJs (the same hop
  // EchoModule::ticks rides), so this is safe from any thread — e.g. the main Looper after
  // onTrimMemory, or the OnBackPressedCallback.
  for (auto& sink : sinks) {
    if (sink) { sink("", eventJson); }
  }
}

void streamingEmit(const std::string& moduleName, const std::string& channel,
                   const std::string& eventJson) {
  std::shared_ptr<StreamingJniModule> mod;
  {
    std::lock_guard<std::mutex> g(g_modulesMu);
    auto it = g_modules.find(moduleName);
    if (it != g_modules.end()) { mod = it->second; }
  }
  if (mod) { mod->emit(channel, eventJson); }
}

}  // namespace canopy

// ===========================================================================
// JNI ENTRY POINT for com.canopyhost.modules.StreamingBridge.nativeEmit(String,String,String).
//
// A Java capability calls this to push one event onto a live Sub channel: e.g. LifecycleModule
// calls StreamingBridge.nativeEmit("Lifecycle","appState","{\"state\":\"background\"}") from its
// ProcessLifecycleOwner observer. This is the ONE new exported symbol this file adds; it lives
// here and links into the same libcanopyhost.so. (One-shot resolves still go through the shared
// Java_com_canopyhost_CanopyHostJni_resolveModule in CanopyJni.cpp.)
// ===========================================================================

extern "C" {

JNIEXPORT void JNICALL
Java_com_canopyhost_modules_StreamingBridge_nativeEmit(JNIEnv* env, jclass, jstring moduleName,
                                                       jstring channel, jstring eventJson) {
  auto str = [env](jstring s) -> std::string {
    if (s == nullptr) { return std::string(); }
    const char* c = env->GetStringUTFChars(s, nullptr);
    std::string out(c ? c : "");
    if (c) { env->ReleaseStringUTFChars(s, c); }
    return out;
  };
  canopy::streamingEmit(str(moduleName), str(channel), str(eventJson));
}

}  // extern "C"
