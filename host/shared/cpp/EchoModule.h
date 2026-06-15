// EchoModule.h — the C1 reference capability (plan C1 §6, the "first-light" module).
//
// The smallest NativeModule that exercises the whole ABI on a real worker thread, so the
// thread-hop is proven before any heavy capability (ORT/Core ML, StoreKit) is built on it:
//
//   • "send"  — one-shot: does (trivial) work on a WORKER thread, then echoes the args
//               JSON back via ctx.complete("", argsJson). This is the C1 gate, end to end:
//               call → worker thread → ctx.complete → postToJs → __canopy_resolve → update.
//   • "ticks" — streaming: emits an incrementing counter via ctx.complete("", "<n>")
//               repeatedly until cancelled, then a terminal {"$done":true}. The
//               billing-updates / batch-progress shape.
//   • cancel  — flips a per-callId flag the worker observes (Process.kill → __canopy_cancel).
//
// Portable C++: std::thread + an atomic cancel flag. iOS/Android both register it from
// shared boot; it is the executable proof of the C1 §3 threading invariant — the worker
// NEVER touches the jsi::Runtime; only ctx.complete (→ postToJs) does.

#pragma once

#include "CanopyModules.h"

#include <atomic>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>

namespace canopy {

class EchoModule : public NativeModule {
 public:
  std::string name() const override { return "Echo"; }
  bool invoke(CallContext& ctx) override;
  void cancel(const std::string& callId) override;

 private:
  // Per-callId cancel flag, shared with the worker thread (the worker polls it; cancel()
  // sets it). Guarded by mu_.
  std::shared_ptr<std::atomic<bool>> trackCall(const std::string& callId);
  void untrackCall(const std::string& callId);

  std::mutex mu_;
  std::unordered_map<std::string, std::shared_ptr<std::atomic<bool>>> cancelFlags_;
};

}  // namespace canopy
