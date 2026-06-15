// RestoreEngineModule.h — the ORT-backed photo-restoration capability (the canopy/inference
// host module). The ONE C++ NativeModule among the C2 capabilities, the heavy-compute sibling
// of EchoModule: where EchoModule sleeps on a worker thread and echoes, RestoreEngineModule
// runs an ONNX Runtime session over a real model on a worker thread and writes pixels.
//
// THE CONTRACT (module "RestoreEngine"):
//   process     args {image:<handle>, options:{upscale,restoreFaces,colorize,strength}}
//                                                   -> {image:<handle>, width, height}
//   release     args {image:<handle>}              -> null
//   deviceTier  args {}                            -> {tier:"cpu"}   (stub)
//
// THREADING — identical to EchoModule's invariant (CONVENTIONS §1.B): invoke() spawns a
// std::thread, runs ORT there, and calls ctx.complete() from the worker. The worker NEVER
// touches the jsi::Runtime; only ctx.complete (→ the registry's postToJs hop → __canopy_resolve)
// does. cancel() flips a per-callId atomic the worker polls between tensor steps.
//
// PIXELS — never JSON. The input is an "rgba8" Blob in canopy::globalBlobRegistry() named by
// the int handle in argsJson; the output is a fresh "rgba8" Blob put() back into the SAME
// registry (the one the blob bridge and the CanopyBitmap renderer share), returned as a handle.
//
// MODEL — ESPCN super-resolution-10.onnx (bundled in assets/models). It is SINGLE-CHANNEL (Y):
// input tensor [1,1,224,224] float in [0,1], output [1,1,672,672] (3x). This is a STAND-IN
// that proves the ORT path end to end, NOT a face/colorize model. process() converts RGBA→YCbCr,
// resizes Y to 224x224, runs the session, then recombines the 672x672 super-res Y with
// bicubic-upscaled CbCr to a plausible RGBA result and blends by options.strength over a plain
// bicubic baseline. restoreFaces/colorize are accepted and ignored (documented in RestoreEngine.can).
//
// MODEL LOADING — the .onnx lives in the APK assets, not the filesystem, so the integrator
// reads its bytes at boot (AAssetManager on Android / the bundle on iOS) and hands them in via
// setModelBytes() BEFORE the first call. The module lazily builds the Ort::Session from those
// bytes on first process() (off the JS thread). If no model bytes were set, process() resolves
// a {"code":"rejected"} error rather than crashing — the rest of the app keeps working.
//
// Portable C++: <onnxruntime_cxx_api.h> + std::thread + the portable CanopyModules/CanopyBlobs.
// No JNI here (the model-bytes handoff is a plain byte vector); Android wires the AAsset read in
// CanopyHostJni boot, iOS wires the NSBundle read — both just call setModelBytes().

#pragma once

#include "CanopyModules.h"

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

namespace canopy {

class RestoreEngineModule : public NativeModule {
 public:
  RestoreEngineModule() = default;

  std::string name() const override { return "RestoreEngine"; }
  bool invoke(CallContext& ctx) override;
  void cancel(const std::string& callId) override;

  // Hand the bundled model's raw .onnx bytes to the module BEFORE the first call (integrator
  // reads the asset at boot). Copies the buffer; safe to call once at boot. Without it,
  // process() resolves a rejected error.
  void setModelBytes(const uint8_t* data, size_t len);

  // Convenience for the integrator: load the model bytes from a filesystem path the host
  // extracted the asset to (returns false if the file can't be read). Either this or
  // setModelBytes must be called before the first process().
  bool loadModelFromFile(const std::string& path);

 private:
  // Per-callId cancel flag shared with the worker thread (worker polls; cancel() sets).
  std::shared_ptr<std::atomic<bool>> trackCall(const std::string& callId);
  void untrackCall(const std::string& callId);

  // The real work for "process", run on the worker thread. Reads the input blob, runs ORT,
  // puts the output blob, and resolves via `complete`. Honors `cancelled`.
  void runProcess(const std::string& argsJson,
                  std::shared_ptr<std::atomic<bool>> cancelled,
                  std::function<void(std::string, std::string)> complete);

  std::mutex mu_;
  std::unordered_map<std::string, std::shared_ptr<std::atomic<bool>>> cancelFlags_;

  // Model bytes + the lazily-built session. Guarded by sessionMu_ (built once, off the JS
  // thread, on the first process()). Opaque pImpl-style pointer so this header does not force
  // every translation unit that includes it to pull in the ORT headers.
  std::mutex sessionMu_;
  std::vector<uint8_t> modelBytes_;
  struct OrtState;                 // defined in the .cpp (holds Ort::Env / Session / names)
  std::shared_ptr<OrtState> ort_;  // nullptr until first successful build
};

}  // namespace canopy
