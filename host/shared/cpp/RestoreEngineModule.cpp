// RestoreEngineModule.cpp — the ORT-backed photo-restoration capability. Portable C++:
// onnxruntime + std::thread + the portable CanopyModules/CanopyBlobs. No platform headers.
//
// See RestoreEngineModule.h for the contract, the threading invariant, and the STAND-IN
// model note. The ESPCN super-resolution-10.onnx model is single-channel (Y) 3x super-res;
// we convert RGBA->YCbCr, resize Y to the model's fixed 224x224, run, then recombine the
// 672x672 super-res Y with bicubic-upscaled CbCr and blend by options.strength over a plain
// bicubic baseline.

#include "RestoreEngineModule.h"

#include "CanopyBlobs.h"
#include "RestoreTiling.h"   // pure seamless-tiling geometry (Tile1D / tileCover), shared with the iOS .mm

// The ONE shared, process-wide BlobRegistry. On Android it lives in CanopyJni.cpp
// (canopy::globalBlobRegistry); on a platform without that file, provide a globalBlobRegistry
// definition. We declare it here so this .cpp does not need to include the JNI header.
namespace canopy {
BlobRegistry& globalBlobRegistry();
}

#include <onnxruntime_cxx_api.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

namespace canopy {

// ---------------------------------------------------------------------------
// Minimal JSON field extraction. The args are a tiny, host-produced object (Native.Module
// encodes them), e.g. {"image":12,"options":{"upscale":true,"strength":0.8}}. We only need a
// few scalar fields, so a dependency-free extractor (string scan) is enough — exactly the
// "JSON strings + ints" discipline. NOT a general JSON parser; it assumes the well-formed
// output of Canopy's Json.Encode (no escaped keys, compact).
// ---------------------------------------------------------------------------
namespace {

// Find the value text following "key": within json (searching the whole string — args are
// flat enough that key collisions don't occur for our fields). Returns the start offset just
// past the colon (skipping spaces), or std::string::npos.
size_t findValuePos(const std::string& json, const std::string& key) {
  const std::string needle = "\"" + key + "\"";
  size_t k = json.find(needle);
  if (k == std::string::npos) { return std::string::npos; }
  size_t c = json.find(':', k + needle.size());
  if (c == std::string::npos) { return std::string::npos; }
  size_t v = c + 1;
  while (v < json.size() && (json[v] == ' ' || json[v] == '\t')) { ++v; }
  return v;
}

// Parse an integer field; returns `fallback` if absent/unparseable.
int jsonInt(const std::string& json, const std::string& key, int fallback) {
  size_t v = findValuePos(json, key);
  if (v == std::string::npos) { return fallback; }
  bool neg = false;
  if (v < json.size() && (json[v] == '-' || json[v] == '+')) { neg = json[v] == '-'; ++v; }
  long long n = 0;
  bool any = false;
  while (v < json.size() && json[v] >= '0' && json[v] <= '9') {
    n = n * 10 + (json[v] - '0');
    ++v;
    any = true;
  }
  if (!any) { return fallback; }
  return static_cast<int>(neg ? -n : n);
}

// Parse a float field; returns `fallback` if absent/unparseable.
float jsonFloat(const std::string& json, const std::string& key, float fallback) {
  size_t v = findValuePos(json, key);
  if (v == std::string::npos) { return fallback; }
  // strtod handles the JSON number grammar (sign, decimal, exponent).
  const char* start = json.c_str() + v;
  char* end = nullptr;
  double d = std::strtod(start, &end);
  if (end == start) { return fallback; }
  return static_cast<float>(d);
}

// Parse a boolean field (true/false literal); returns `fallback` if absent.
bool jsonBool(const std::string& json, const std::string& key, bool fallback) {
  size_t v = findValuePos(json, key);
  if (v == std::string::npos) { return fallback; }
  if (json.compare(v, 4, "true") == 0) { return true; }
  if (json.compare(v, 5, "false") == 0) { return false; }
  return fallback;
}

constexpr int kModelDim = 224;  // ESPCN super-resolution-10 fixed input H=W=224
constexpr int kScale = 3;       // ESPCN 3x; output 672x672

// Bilinear sample of a single-channel float plane (src w*h, values arbitrary range) at the
// continuous coordinate (fx, fy). Clamps to edges.
inline float sampleBilinear(const std::vector<float>& src, int w, int h, float fx, float fy) {
  if (w <= 0 || h <= 0) { return 0.0f; }
  fx = std::min(std::max(fx, 0.0f), static_cast<float>(w - 1));
  fy = std::min(std::max(fy, 0.0f), static_cast<float>(h - 1));
  int x0 = static_cast<int>(fx);
  int y0 = static_cast<int>(fy);
  int x1 = std::min(x0 + 1, w - 1);
  int y1 = std::min(y0 + 1, h - 1);
  float dx = fx - x0;
  float dy = fy - y0;
  float a = src[static_cast<size_t>(y0) * w + x0];
  float b = src[static_cast<size_t>(y0) * w + x1];
  float c = src[static_cast<size_t>(y1) * w + x0];
  float d = src[static_cast<size_t>(y1) * w + x1];
  float top = a + (b - a) * dx;
  float bot = c + (d - c) * dx;
  return top + (bot - top) * dy;
}

// Resize a single-channel float plane (srcW*srcH) to dstW*dstH (bilinear).
std::vector<float> resizePlane(const std::vector<float>& src, int srcW, int srcH,
                               int dstW, int dstH) {
  std::vector<float> dst(static_cast<size_t>(dstW) * dstH);
  const float sx = srcW > 1 ? static_cast<float>(srcW - 1) / std::max(1, dstW - 1) : 0.0f;
  const float sy = srcH > 1 ? static_cast<float>(srcH - 1) / std::max(1, dstH - 1) : 0.0f;
  for (int y = 0; y < dstH; ++y) {
    for (int x = 0; x < dstW; ++x) {
      dst[static_cast<size_t>(y) * dstW + x] =
          sampleBilinear(src, srcW, srcH, x * sx, y * sy);
    }
  }
  return dst;
}

inline uint8_t clamp8(float v) {
  if (v <= 0.0f) { return 0; }
  if (v >= 255.0f) { return 255; }
  return static_cast<uint8_t>(v + 0.5f);
}

}  // namespace

// ---------------------------------------------------------------------------
// The ORT session state (pImpl). Built once, lazily, off the JS thread.
// ---------------------------------------------------------------------------
struct RestoreEngineModule::OrtState {
  Ort::Env env{ORT_LOGGING_LEVEL_WARNING, "RestoreEngine"};
  Ort::SessionOptions opts;
  Ort::Session session{nullptr};
  std::string inputName;
  std::string outputName;
  // The model's I/O contract, read from its shape at build time so process() picks the right path
  // dynamically instead of hardcoding the ESPCN stand-in's [1,1,224,224]:
  int inChannels = 1;       // 1 = Y-plane ESPCN stand-in; 3 = RGB image->image (enhance/face/SR)
  int inDim = kModelDim;    // fixed square input spatial (H==W); falls back to kModelDim if dynamic
  int outChannels = 1;      // 1 = same; 2 = colorize L->ab (not wired in the engine yet)
  bool rgb = false;

  OrtState(const uint8_t* data, size_t len) {
    opts.SetIntraOpNumThreads(2);
    opts.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
    // Build from the in-memory model bytes (the asset, read at boot). Pure CPU EP — no NNAPI
    // for the stand-in; deviceTier reports "cpu".
    session = Ort::Session(env, data, len, opts);

    Ort::AllocatorWithDefaultOptions alloc;
    Ort::AllocatedStringPtr inName = session.GetInputNameAllocated(0, alloc);
    Ort::AllocatedStringPtr outName = session.GetOutputNameAllocated(0, alloc);
    inputName = inName.get();
    outputName = outName.get();

    // Read the input/output tensor shapes [N,C,H,W]; dims <= 0 are dynamic (keep the fallback).
    auto ishape = session.GetInputTypeInfo(0).GetTensorTypeAndShapeInfo().GetShape();
    if (ishape.size() == 4) {
      if (ishape[1] > 0) { inChannels = static_cast<int>(ishape[1]); }
      if (ishape[2] > 0) { inDim = static_cast<int>(ishape[2]); }
    }
    auto oshape = session.GetOutputTypeInfo(0).GetTensorTypeAndShapeInfo().GetShape();
    if (oshape.size() == 4 && oshape[1] > 0) { outChannels = static_cast<int>(oshape[1]); }
    rgb = (inChannels == 3);
  }
};

// ---------------------------------------------------------------------------
// Cancel bookkeeping (identical posture to EchoModule)
// ---------------------------------------------------------------------------

std::shared_ptr<std::atomic<bool>> RestoreEngineModule::trackCall(const std::string& callId) {
  auto flag = std::make_shared<std::atomic<bool>>(false);
  std::lock_guard<std::mutex> g(mu_);
  cancelFlags_[callId] = flag;
  return flag;
}

void RestoreEngineModule::untrackCall(const std::string& callId) {
  std::lock_guard<std::mutex> g(mu_);
  cancelFlags_.erase(callId);
}

void RestoreEngineModule::cancel(const std::string& callId) {
  std::lock_guard<std::mutex> g(mu_);
  auto it = cancelFlags_.find(callId);
  if (it != cancelFlags_.end()) { it->second->store(true); }  // worker observes between steps
}

// ---------------------------------------------------------------------------
// Model bytes handoff
// ---------------------------------------------------------------------------

void RestoreEngineModule::setModelBytes(const uint8_t* data, size_t len) {
  std::lock_guard<std::mutex> g(sessionMu_);
  modelBytes_.assign(data, data + len);
  ort_.reset();  // force a rebuild on next process() if bytes were swapped
}

bool RestoreEngineModule::loadModelFromFile(const std::string& path) {
  std::FILE* f = std::fopen(path.c_str(), "rb");
  if (f == nullptr) { return false; }
  std::fseek(f, 0, SEEK_END);
  long sz = std::ftell(f);
  std::fseek(f, 0, SEEK_SET);
  if (sz <= 0) { std::fclose(f); return false; }
  std::vector<uint8_t> buf(static_cast<size_t>(sz));
  size_t rd = std::fread(buf.data(), 1, buf.size(), f);
  std::fclose(f);
  if (rd != buf.size()) { return false; }
  setModelBytes(buf.data(), buf.size());
  return true;
}

// ---------------------------------------------------------------------------
// invoke / dispatch
// ---------------------------------------------------------------------------

bool RestoreEngineModule::invoke(CallContext& ctx) {
  const std::string method = ctx.method;

  if (method == "deviceTier") {
    // Stub: the ESPCN stand-in always runs on the CPU execution provider.
    ctx.complete("", R"({"tier":"cpu"})");
    return true;
  }

  if (method == "release") {
    int handle = jsonInt(ctx.argsJson, "image", 0);
    if (handle != 0) { globalBlobRegistry().release(static_cast<BlobHandle>(handle)); }
    ctx.complete("", "null");
    return true;
  }

  if (method == "process") {
    auto cancelled = trackCall(ctx.callId);
    std::string callId = ctx.callId;
    std::string argsJson = ctx.argsJson;
    auto complete = ctx.complete;
    // OFF the JS thread: the ORT session + tensor work runs for hundreds of ms. The worker
    // NEVER touches the runtime — only `complete` (→ postToJs → __canopy_resolve) does.
    std::thread([this, cancelled, callId, argsJson, complete]() {
      runProcess(argsJson, cancelled, complete);
      untrackCall(callId);
    }).detach();
    return true;
  }

  return false;  // unknown method -> dispatcher reports -1 / ModuleNotFound
}

// ---------------------------------------------------------------------------
// runProcess: the real ORT pass, on the worker thread
// ---------------------------------------------------------------------------

void RestoreEngineModule::runProcess(const std::string& argsJson,
                                     std::shared_ptr<std::atomic<bool>> cancelled,
                                     std::function<void(std::string, std::string)> complete) {
  auto fail = [&](const char* msg) {
    std::string err = std::string(R"({"code":"rejected","message":")") + msg + "\"}";
    complete(err, "");
  };

  if (cancelled->load()) { complete(R"({"code":"cancelled"})", ""); return; }

  // 1) Read the input RGBA blob by handle.
  int inHandle = jsonInt(argsJson, "image", 0);
  if (inHandle == 0) { fail("missing image handle"); return; }
  auto src = globalBlobRegistry().get(static_cast<BlobHandle>(inHandle));
  if (!src || src->kind != "rgba8" || src->width <= 0 || src->height <= 0) {
    fail("input handle is not a live rgba8 blob");
    return;
  }
  const int W = src->width;
  const int H = src->height;
  // Copy pixels out so we don't hold the registry borrow across the long ORT run.
  std::vector<uint8_t> rgba = src->bytes;
  src.reset();
  if (rgba.size() < static_cast<size_t>(W) * H * 4) { fail("input blob too small"); return; }

  // Options.
  const bool upscale = jsonBool(argsJson, "upscale", true);
  float strength = jsonFloat(argsJson, "strength", 1.0f);
  strength = std::min(std::max(strength, 0.0f), 1.0f);
  // restoreFaces / colorize are accepted but no-ops for the ESPCN stand-in (see header).

  // Build the ORT session up-front when we will run the model (upscale=true). We need it now to
  // read the model's I/O contract and choose a path; with upscale=false we skip the model entirely
  // (pure bicubic baseline below), so no session is needed.
  std::shared_ptr<OrtState> state;
  if (upscale) {
    std::lock_guard<std::mutex> g(sessionMu_);
    if (!ort_) {
      if (modelBytes_.empty()) { fail("model not loaded (setModelBytes was never called)"); return; }
      try {
        ort_ = std::make_shared<OrtState>(modelBytes_.data(), modelBytes_.size());
      } catch (const Ort::Exception& e) {
        fail("failed to build ORT session");
        return;
      } catch (...) {
        fail("failed to build ORT session");
        return;
      }
    }
    state = ort_;
  }

  // RGB image->image models (enhance / face / RGB super-res) take the whole RGBA frame through a
  // single [1,3,D,D] -> [1,3,oh,ow] pass; the Y-plane ESPCN stand-in keeps its YCbCr path below.
  if (state && state->rgb) {
    runProcessRgb(rgba, W, H, strength, state, cancelled, complete);
    return;
  }
  if (state && state->outChannels != 1) {
    fail("unsupported model output contract (colorize 1->2 not wired in the engine yet)");
    return;
  }

  // 2) RGBA -> YCbCr planes (BT.601 full-range, the JPEG/ITU-R convention).
  const size_t npix = static_cast<size_t>(W) * H;
  std::vector<float> Y(npix), Cb(npix), Cr(npix);
  for (size_t i = 0; i < npix; ++i) {
    float r = rgba[i * 4 + 0];
    float g = rgba[i * 4 + 1];
    float b = rgba[i * 4 + 2];
    Y[i]  =  0.299f * r + 0.587f * g + 0.114f * b;
    Cb[i] = -0.168736f * r - 0.331264f * g + 0.5f * b + 128.0f;
    Cr[i] =  0.5f * r - 0.418688f * g - 0.081312f * b + 128.0f;
  }

  if (cancelled->load()) { complete(R"({"code":"cancelled"})", ""); return; }

  // The restored output dimensions. With upscale on we produce a 3x result (matching the
  // ESPCN model); with it off we keep the source size (bicubic-only baseline, model skipped).
  const int outW = upscale ? W * kScale : W;
  const int outH = upscale ? H * kScale : H;

  // 3) Build the super-res Y plane.
  std::vector<float> superY;  // outW*outH, 0..255
  if (upscale) {
    // `state` is the session built above (used to read the contract). Resize Y to the model's
    // input dim (read from its shape; the ESPCN stand-in is 224) and normalize to [0,1].
    const int mdl = state->inDim;
    std::vector<float> yModel = resizePlane(Y, W, H, mdl, mdl);
    for (float& v : yModel) { v /= 255.0f; }

    if (cancelled->load()) { complete(R"({"code":"cancelled"})", ""); return; }

    // Run the session: input [1,1,mdl,mdl] -> output [1,1,mdl*scale,mdl*scale] (ESPCN: 224->672).
    std::vector<float> outY;  // model output, ~[0,1]
    int srW = mdl * kScale, srH = mdl * kScale;
    try {
      Ort::MemoryInfo memInfo =
          Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
      const int64_t inShape[4] = {1, 1, mdl, mdl};
      Ort::Value inTensor = Ort::Value::CreateTensor<float>(
          memInfo, yModel.data(), yModel.size(), inShape, 4);

      const char* inNames[1] = {state->inputName.c_str()};
      const char* outNames[1] = {state->outputName.c_str()};
      auto outputs = state->session.Run(Ort::RunOptions{nullptr}, inNames, &inTensor, 1,
                                        outNames, 1);
      if (outputs.empty() || !outputs[0].IsTensor()) { fail("model produced no tensor"); return; }

      auto shape = outputs[0].GetTensorTypeAndShapeInfo().GetShape();
      // Expected [1,1,672,672]; derive the actual spatial dims robustly.
      if (shape.size() == 4) {
        srH = static_cast<int>(shape[2]);
        srW = static_cast<int>(shape[3]);
      }
      const float* outData = outputs[0].GetTensorData<float>();
      size_t count = static_cast<size_t>(srW) * srH;
      outY.assign(outData, outData + count);
    } catch (const Ort::Exception& e) {
      fail("ORT Run failed");
      return;
    } catch (...) {
      fail("ORT Run failed");
      return;
    }

    if (cancelled->load()) { complete(R"({"code":"cancelled"})", ""); return; }

    // The model ran at 224->672; map that super-res Y to the actual output size (outW*outH,
    // which is W*3 x H*3) and rescale from [0,1] to [0,255].
    std::vector<float> sr01 = resizePlane(outY, srW, srH, outW, outH);
    superY.resize(static_cast<size_t>(outW) * outH);
    for (size_t i = 0; i < superY.size(); ++i) { superY[i] = sr01[i] * 255.0f; }
  }

  // 4) Bicubic(-ish, bilinear here) baseline Y at the output size — what a plain upscale gives.
  std::vector<float> baseY = resizePlane(Y, W, H, outW, outH);

  // 5) Blend the super-res Y over the baseline by `strength` (strength=0 => plain upscale,
  //    1 => full model). With upscale off, superY is empty and we keep the baseline.
  std::vector<float> finalY(static_cast<size_t>(outW) * outH);
  if (!superY.empty()) {
    for (size_t i = 0; i < finalY.size(); ++i) {
      finalY[i] = baseY[i] * (1.0f - strength) + superY[i] * strength;
    }
  } else {
    finalY = baseY;
  }

  // 6) Upscale the chroma planes (no model — bicubic/bilinear) and recombine YCbCr -> RGBA.
  std::vector<float> outCb = resizePlane(Cb, W, H, outW, outH);
  std::vector<float> outCr = resizePlane(Cr, W, H, outW, outH);

  if (cancelled->load()) { complete(R"({"code":"cancelled"})", ""); return; }

  Blob out;
  out.kind = "rgba8";
  out.width = outW;
  out.height = outH;
  out.bytes.resize(static_cast<size_t>(outW) * outH * 4);
  for (size_t i = 0; i < static_cast<size_t>(outW) * outH; ++i) {
    float y = finalY[i];
    float cb = outCb[i] - 128.0f;
    float cr = outCr[i] - 128.0f;
    float r = y + 1.402f * cr;
    float g = y - 0.344136f * cb - 0.714136f * cr;
    float b = y + 1.772f * cb;
    out.bytes[i * 4 + 0] = clamp8(r);
    out.bytes[i * 4 + 1] = clamp8(g);
    out.bytes[i * 4 + 2] = clamp8(b);
    out.bytes[i * 4 + 3] = 255;  // opaque
  }

  // 7) Put the output blob (refcount 1) and resolve with the producer shape.
  BlobHandle outHandle = globalBlobRegistry().put(std::move(out));
  std::string result = std::string("{\"image\":") + std::to_string(outHandle) +
                       ",\"width\":" + std::to_string(outW) +
                       ",\"height\":" + std::to_string(outH) + "}";
  complete("", result);
}

// ---------------------------------------------------------------------------
// runProcessRgb: the RGB image->image pass (enhance / face / RGB super-res). The frame is covered by
// FIXED DxD windows (RestoreTiling.h), each run [1,3,D,D] -> [1,3,oh,ow] (/255 in, *255 out); each
// window's seam-cropped CENTRAL span is stitched into a full-res canvas, then the canvas is strength-
// blended over the bicubic baseline. A 1x model gives W×H out; an integer-scale SR model gives W·s×H·s.
// One window covers a ≤D image (edge-clamped, never downscaled); many tile a large photo at full res.
// ---------------------------------------------------------------------------

void RestoreEngineModule::runProcessRgb(const std::vector<uint8_t>& rgba, int W, int H, float strength,
                                        std::shared_ptr<OrtState> state,
                                        std::shared_ptr<std::atomic<bool>> cancelled,
                                        std::function<void(std::string, std::string)> complete) {
  auto fail = [&](const char* msg) {
    complete(std::string(R"({"code":"rejected","message":")") + msg + "\"}", "");
  };
  const int D = state->inDim;                       // fixed square model input (e.g. 512)
  const int over = std::min(32, D / 4 > 0 ? D / 4 : 1);   // seam context cropped per interior tile
  const size_t npix = static_cast<size_t>(W) * H;

  // Split RGBA -> 3 float planes [0,255] (drop alpha) once; windows clamp-sample these.
  std::vector<float> R(npix), G(npix), B(npix);
  for (size_t i = 0; i < npix; ++i) {
    R[i] = rgba[i * 4 + 0];
    G[i] = rgba[i * 4 + 1];
    B[i] = rgba[i * 4 + 2];
  }

  int npx = D, npy = D;
  std::vector<Tile1D> txs = tileCover(W, D, over, npx);
  std::vector<Tile1D> tys = tileCover(H, D, over, npy);

  const size_t plane = static_cast<size_t>(D) * D;
  std::vector<float> input(3 * plane);
  Ort::MemoryInfo memInfo = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);

  // Canvas (in PADDED-output coords) is allocated once the model's integer scale is known.
  int sx = 0, sy = 0, cw = 0, ch = 0;
  std::vector<float> canR, canG, canB;

  for (const Tile1D& tile_y : tys) {
    for (const Tile1D& tile_x : txs) {
      if (cancelled->load()) { complete(R"({"code":"cancelled"})", ""); return; }

      // Build the DxD window by edge-clamped sampling of the source, normalize to [0,1], pack NCHW.
      for (int yy = 0; yy < D; ++yy) {
        int syc = tile_y.win + yy; if (syc < 0) { syc = 0; } else if (syc >= H) { syc = H - 1; }
        for (int xx = 0; xx < D; ++xx) {
          int sxc = tile_x.win + xx; if (sxc < 0) { sxc = 0; } else if (sxc >= W) { sxc = W - 1; }
          const size_t si = static_cast<size_t>(syc) * W + sxc;
          const size_t di = static_cast<size_t>(yy) * D + xx;
          input[di]             = R[si] / 255.0f;
          input[plane + di]     = G[si] / 255.0f;
          input[2 * plane + di] = B[si] / 255.0f;
        }
      }

      int oh = D, ow = D;
      std::vector<float> outRGB;
      try {
        const int64_t inShape[4] = {1, 3, D, D};
        Ort::Value inTensor = Ort::Value::CreateTensor<float>(
            memInfo, input.data(), input.size(), inShape, 4);
        const char* inNames[1] = {state->inputName.c_str()};
        const char* outNames[1] = {state->outputName.c_str()};
        auto outputs = state->session.Run(Ort::RunOptions{nullptr}, inNames, &inTensor, 1, outNames, 1);
        if (outputs.empty() || !outputs[0].IsTensor()) { fail("model produced no tensor"); return; }
        auto info = outputs[0].GetTensorTypeAndShapeInfo();
        auto shape = info.GetShape();
        if (shape.size() != 4 || shape[1] != 3) { fail("RGB model output is not [1,3,H,W]"); return; }
        oh = static_cast<int>(shape[2]);
        ow = static_cast<int>(shape[3]);
        const size_t need = static_cast<size_t>(3) * static_cast<size_t>(oh) * static_cast<size_t>(ow);
        if (info.GetElementCount() < need) { fail("RGB model output smaller than its declared shape"); return; }
        const float* outData = outputs[0].GetTensorData<float>();
        outRGB.assign(outData, outData + need);
      } catch (const Ort::Exception& e) {
        fail("ORT Run failed"); return;
      } catch (...) {
        fail("ORT Run failed"); return;
      }

      if (sx == 0) {                                   // first tile: fix the integer scale + size the canvas
        if (oh % D != 0 || ow % D != 0) { fail("RGB model output is not an integer multiple of D (tiler needs integer scale)"); return; }
        sy = oh / D; sx = ow / D;
        if (sx <= 0 || sy <= 0) { fail("RGB model scale <= 0"); return; }
        cw = npx * sx; ch = npy * sy;
        canR.assign(static_cast<size_t>(cw) * ch, 0.0f);
        canG.assign(static_cast<size_t>(cw) * ch, 0.0f);
        canB.assign(static_cast<size_t>(cw) * ch, 0.0f);
      } else if (oh != D * sy || ow != D * sx) {
        fail("inconsistent tile output size across tiles"); return;
      }

      // Stitch this tile's seam-cropped central span [cs,ce) (padded-input coords) into the canvas,
      // expanding by the integer scale. Centrals partition [0,np) exactly (RestoreTiling.h) → no seams.
      const size_t oplane = static_cast<size_t>(oh) * ow;
      for (int y = tile_y.cs; y < tile_y.ce; ++y) {
        for (int oyy = 0; oyy < sy; ++oyy) {
          const int canvasY = y * sy + oyy;
          const int tileY = (y - tile_y.win) * sy + oyy;
          for (int x = tile_x.cs; x < tile_x.ce; ++x) {
            const int tileX0 = (x - tile_x.win) * sx;
            const int canvasX0 = x * sx;
            for (int oxx = 0; oxx < sx; ++oxx) {
              const size_t ci = static_cast<size_t>(canvasY) * cw + (canvasX0 + oxx);
              const size_t ti = static_cast<size_t>(tileY) * ow + (tileX0 + oxx);
              canR[ci] = outRGB[ti] * 255.0f;
              canG[ci] = outRGB[oplane + ti] * 255.0f;
              canB[ci] = outRGB[2 * oplane + ti] * 255.0f;
            }
          }
        }
      }
    }
  }

  if (sx == 0) { fail("no tiles produced (empty image?)"); return; }
  if (cancelled->load()) { complete(R"({"code":"cancelled"})", ""); return; }

  // Crop the padded canvas to the natural output size and strength-blend over the bicubic baseline.
  const int outW = W * sx, outH = H * sy;
  std::vector<float> baseR = resizePlane(R, W, H, outW, outH);
  std::vector<float> baseG = resizePlane(G, W, H, outW, outH);
  std::vector<float> baseB = resizePlane(B, W, H, outW, outH);

  Blob out;
  out.kind = "rgba8";
  out.width = outW;
  out.height = outH;
  out.bytes.resize(static_cast<size_t>(outW) * outH * 4);
  for (int y = 0; y < outH; ++y) {
    for (int x = 0; x < outW; ++x) {
      const size_t i = static_cast<size_t>(y) * outW + x;
      const size_t ci = static_cast<size_t>(y) * cw + x;   // canvas is >= outW wide (npx*sx >= W*sx)
      float r = baseR[i] * (1.0f - strength) + canR[ci] * strength;
      float g = baseG[i] * (1.0f - strength) + canG[ci] * strength;
      float b = baseB[i] * (1.0f - strength) + canB[ci] * strength;
      out.bytes[i * 4 + 0] = clamp8(r);
      out.bytes[i * 4 + 1] = clamp8(g);
      out.bytes[i * 4 + 2] = clamp8(b);
      out.bytes[i * 4 + 3] = 255;  // opaque
    }
  }

  BlobHandle outHandle = globalBlobRegistry().put(std::move(out));
  std::string result = std::string("{\"image\":") + std::to_string(outHandle) +
                       ",\"width\":" + std::to_string(outW) +
                       ",\"height\":" + std::to_string(outH) + "}";
  complete("", result);
}

}  // namespace canopy
