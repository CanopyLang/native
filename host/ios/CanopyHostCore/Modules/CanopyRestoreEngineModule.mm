// CanopyRestoreEngineModule.mm — the iOS host module behind canopy/inference
// (module "RestoreEngine"). The Core ML re-back of the portable ORT RestoreEngineModule.
//
// WHY A SEPARATE iOS MODULE (the "Core ML over ORT" mandate, plan §6):
// The portable shared/cpp/RestoreEngineModule.{h,cpp} is a real canopy::NativeModule that runs
// the ESPCN super-resolution ONNX via ONNX Runtime on a worker thread (RGBA->YCbCr->model->
// recombine, blend by strength). That C++ body is portable and the iOS host CAN reuse it verbatim
// if it links onnxruntime.xcframework — see "Path B" below. But iOS ships a Neural Engine, so the
// plan mandates Core ML: convert super-resolution-10.onnx -> restore.mlpackage (coremltools,
// offline on a Mac) and run it via MLModel here. The WIRE CONTRACT and the color pipeline are
// identical to the ORT path; only the model Run differs.
//
// This adopts the §4.1 CanopyModule protocol (uniform with the other iOS capabilities). The §4.2
// bridge routes __canopy_call(module="RestoreEngine", …) here. process() reads the input "rgba8"
// blob from the ONE shared canopy::globalBlobRegistry() (§6.3), does the YCbCr split / Y-resize /
// model run / recombine / strength-blend, PUTs a fresh "rgba8" blob back, and resolves a handle.
// All heavy work runs on a background queue; the CanopyComplete block hops to JS internally.
//
// CANCEL: a per-callId atomic the worker polls between steps (mirrors RestoreEngineModule.cpp's
// cancel flag). MLModel itself is not interruptible mid-prediction, so cancel takes effect at the
// next pipeline boundary.
//
// COLOR-OPS REUSE (plan §6 "RestoreColorOps refactor"): the RGBA<->YCbCr conversion, the bilinear
// plane resize, and the strength blend are the SAME math as the ORT path. The plan extracts these
// into a portable RestoreColorOps.{h,cpp} that BOTH modules call; until that refactor lands this
// file carries a local copy of the small helpers, clearly marked, so the Core ML path is complete
// on its own. When RestoreColorOps lands, delete the local copies and #include it.
//
// MODEL HANDOFF: CanopyModuleHost (Author B, registerAll) locates restore.mlpackage in the bundle
// and calls -setModelURL: BEFORE the first process(). Without a model, process() resolves a
// {"code":"rejected"} error rather than crashing — the rest of the app keeps working.
//
// Wire contract (must match RestoreEngine.can / RestoreEngineModule.h):
//   process     {image:<handle>, options:{upscale,restoreFaces,colorize,strength}}
//                                                  -> {image:<handle>, width, height}
//   release     {image:<handle>}                  -> null
//   deviceTier  {}                                -> {tier:"ane"|"gpu"|"cpu"}

#import <Foundation/Foundation.h>
#import <CoreML/CoreML.h>

#include <algorithm>   // std::min — used by resizePlane (NOT guaranteed transitively via <vector>
                       // under libc++; an explicit-decl/no-member compile error on a strict Mac build)
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>     // memcpy — used to pack/unpack the MLMultiArray (declared in <cstring>, not
                       // pulled in transitively by Foundation/CoreML on a clean libc++ build)
#include <memory>
#include <mutex>
#include <unordered_map>
#include <vector>

#import "CanopyModule.h"
#import "CanopyModuleSupport.h"
#import "CanopyBlobRegistryHost.h"   // §6.3 globalBlobRegistry
#include "CanopyBlobs.h"

// Defaults for the single-channel Y ESPCN stand-in: input [1,1,224,224], output [1,1,672,672] (3x).
// The real contract is read at load time from the model shape (see -ensureModel): a 1-channel input
// keeps the YCbCr path below; a 3-channel [1,3,D,D] input dispatches to -runProcessRgb (the shipped
// enhance/face/SR models). (Mirrors RestoreEngineModule.h:21-33 / the cpp OrtState.)
static const int kModelIn  = 224;
static const int kModelOut = 672;

#pragma mark - Local color helpers (a copy of the ORT path's math; delete when RestoreColorOps lands)

namespace {

// Clamp a float to [0,255] and round to a byte.
static inline uint8_t clampByte(float v) {
  if (v < 0.0f) { return 0; }
  if (v > 255.0f) { return 255; }
  return (uint8_t)lroundf(v);
}

// Bilinear-resample a single float plane (srcW x srcH) into (dstW x dstH). Used to fit Y to the
// model's 224x224 and to upscale Cb/Cr to the 672x672 output. Same as the ORT path's resizePlane.
static std::vector<float> resizePlane(const std::vector<float>& src, int srcW, int srcH,
                                      int dstW, int dstH) {
  std::vector<float> dst((size_t)dstW * dstH);
  if (srcW <= 0 || srcH <= 0 || dstW <= 0 || dstH <= 0) { return dst; }
  const float sx = (srcW > 1) ? (float)(srcW - 1) / (float)(dstW - 1 > 0 ? dstW - 1 : 1) : 0.0f;
  const float sy = (srcH > 1) ? (float)(srcH - 1) / (float)(dstH - 1 > 0 ? dstH - 1 : 1) : 0.0f;
  for (int y = 0; y < dstH; ++y) {
    float fy = y * sy;
    int y0 = (int)fy; int y1 = std::min(y0 + 1, srcH - 1);
    float wy = fy - y0;
    for (int x = 0; x < dstW; ++x) {
      float fx = x * sx;
      int x0 = (int)fx; int x1 = std::min(x0 + 1, srcW - 1);
      float wx = fx - x0;
      float a = src[(size_t)y0 * srcW + x0], b = src[(size_t)y0 * srcW + x1];
      float c = src[(size_t)y1 * srcW + x0], d = src[(size_t)y1 * srcW + x1];
      float top = a + (b - a) * wx;
      float bot = c + (d - c) * wx;
      dst[(size_t)y * dstW + x] = top + (bot - top) * wy;
    }
  }
  return dst;
}

}  // namespace

#pragma mark - The module

@interface CanopyRestoreEngineModule : NSObject <CanopyModule>
- (void)setModelURL:(NSURL *)url;  // model-bytes handoff (registerAll, §3.3)
@end

@implementation CanopyRestoreEngineModule {
  dispatch_queue_t _queue;
  NSURL *_modelURL;
  MLModel *_model;          // lazily compiled+loaded on first process()
  std::mutex _modelMu;
  std::shared_ptr<std::unordered_map<std::string, std::shared_ptr<std::atomic<bool>>>> _cancelFlags;
  std::mutex _cancelMu;
  // Model I/O contract, read from the loaded model's shape (mirrors the cpp OrtState fields):
  int _inChannels;          // 1 = Y-plane ESPCN stand-in; 3 = RGB image->image
  int _inDim;               // fixed square input spatial (H==W); kModelIn fallback
  int _outChannels;         // 1 = same; 2 = colorize L->ab (not wired yet)
  BOOL _rgb;
}

- (instancetype)init {
  if ((self = [super init])) {
    _queue = dispatch_queue_create("com.canopyhost.restore", DISPATCH_QUEUE_SERIAL);
    _cancelFlags = std::make_shared<std::unordered_map<std::string, std::shared_ptr<std::atomic<bool>>>>();
  }
  return self;
}

- (NSString *)moduleName { return @"RestoreEngine"; }

- (void)setModelURL:(NSURL *)url { _modelURL = url; }

- (BOOL)invokeMethod:(NSString *)method
                args:(NSString *)argsJson
              callId:(NSString *)callId
            complete:(CanopyComplete)complete {
  if ([method isEqualToString:@"deviceTier"]) {
    CanopyResolve(complete, @{ @"tier": [self deviceTier] });
    return YES;
  }
  if ([method isEqualToString:@"release"]) {
    NSDictionary *args = CanopyParseArgs(argsJson);
    canopy::BlobHandle h = (canopy::BlobHandle)[args[@"image"] intValue];
    canopy::globalBlobRegistry().release(h);
    CanopyResolveNull(complete);
    return YES;
  }
  if ([method isEqualToString:@"process"]) {
    std::shared_ptr<std::atomic<bool>> cancelled = [self trackCall:callId];
    NSString *argsCopy = [argsJson copy];
    dispatch_async(_queue, ^{
      @try {
        [self runProcess:argsCopy cancelled:cancelled complete:complete];
      } @catch (NSException *e) {
        CanopyReject(complete, @"rejected", e.reason ?: @"restore error");
      }
      [self untrackCall:callId];
    });
    return YES;
  }
  return NO;  // unknown method -> ModuleNotFound
}

- (void)cancelCallId:(NSString *)callId {
  std::lock_guard<std::mutex> g(_cancelMu);
  auto it = _cancelFlags->find(std::string(callId.UTF8String));
  if (it != _cancelFlags->end()) { it->second->store(true); }
}

- (std::shared_ptr<std::atomic<bool>>)trackCall:(NSString *)callId {
  auto flag = std::make_shared<std::atomic<bool>>(false);
  std::lock_guard<std::mutex> g(_cancelMu);
  (*_cancelFlags)[std::string(callId.UTF8String)] = flag;
  return flag;
}

- (void)untrackCall:(NSString *)callId {
  std::lock_guard<std::mutex> g(_cancelMu);
  _cancelFlags->erase(std::string(callId.UTF8String));
}

- (NSString *)deviceTier {
  // Report the strongest available compute unit. ANE on supported devices; else GPU; else CPU.
  if (@available(iOS 13.0, *)) {
    // MLComputeUnits has no direct "is ANE present" query; on A12+ the ANE is available and
    // .all routes to it. Report "ane" when the all-units path is selectable (the common case on
    // modern devices), "cpu" only as a floor. A pure-Swift module can probe MLModel.available
    // compute devices on iOS 17+ for a precise answer.
    return @"ane";
  }
  return @"cpu";
}

// ---- the pipeline (RGBA -> YCbCr -> model Y -> recombine -> strength blend) ----------------

- (void)runProcess:(NSString *)argsJson
         cancelled:(std::shared_ptr<std::atomic<bool>>)cancelled
          complete:(CanopyComplete)complete {
  NSDictionary *args = CanopyParseArgs(argsJson);
  canopy::BlobHandle inHandle = (canopy::BlobHandle)[args[@"image"] intValue];
  NSDictionary *options = [args[@"options"] isKindOfClass:[NSDictionary class]] ? args[@"options"] : @{};
  double strength = options[@"strength"] ? [options[@"strength"] doubleValue] : 1.0;
  strength = MAX(0.0, MIN(1.0, strength));

  std::shared_ptr<canopy::Blob> in = canopy::globalBlobRegistry().get(inHandle);
  if (!in || in->kind != "rgba8" || in->width <= 0 || in->height <= 0) {
    CanopyReject(complete, @"rejected", [NSString stringWithFormat:@"unknown rgba8 handle %d", inHandle]);
    return;
  }
  if (cancelled->load()) { CanopyReject(complete, @"cancelled", @"process cancelled"); return; }

  const int W = in->width, H = in->height;
  const size_t n = (size_t)W * H;

  // Load the model up-front (idempotent/cached) to read its I/O contract and choose a path. A real
  // RGB model replaces the ESPCN stand-in with no code change. A load FAILURE (not "no-model") falls
  // through to the Y-plane path, which keeps its bicubic degrade-gracefully behavior.
  NSString *ensErr = nil;
  if ([self ensureModel:&ensErr]) {
    if (_rgb) { [self runProcessRgb:in strength:strength cancelled:cancelled complete:complete]; return; }
    if (_outChannels != 1) {
      CanopyReject(complete, @"rejected", @"colorize 1->2 model not wired in the engine yet");
      return;
    }
  } else if (ensErr != nil && [ensErr isEqualToString:@"no-model"]) {
    CanopyReject(complete, @"rejected", @"RestoreEngine: no model bytes set");
    return;
  }

  // --- RGBA -> YCbCr (BT.601 full-range). Y in [0,1] for the model; Cb/Cr kept in [0,255]. ---
  std::vector<float> Y(n), Cb(n), Cr(n);
  const uint8_t* px = in->bytes.data();
  for (size_t i = 0; i < n; ++i) {
    float r = px[i * 4 + 0], g = px[i * 4 + 1], b = px[i * 4 + 2];
    float y  = 0.299f * r + 0.587f * g + 0.114f * b;
    float cb = 128.0f - 0.168736f * r - 0.331264f * g + 0.5f * b;
    float cr = 128.0f + 0.5f * r - 0.418688f * g - 0.081312f * b;
    Y[i] = y / 255.0f; Cb[i] = cb; Cr[i] = cr;
  }
  if (cancelled->load()) { CanopyReject(complete, @"cancelled", @"process cancelled"); return; }

  // --- resize Y to the model input (224x224) ---
  std::vector<float> Yin = resizePlane(Y, W, H, kModelIn, kModelIn);

  // --- run the model (Core ML) -> 672x672 super-res Y, or a bicubic-style fallback ---
  std::vector<float> Yout;
  NSString *runErr = nil;
  if (![self runModelY:Yin out:Yout error:&runErr]) {
    // No model / load failure: degrade to a plain upscale of the resized Y so the call still
    // produces a (lower-fidelity) result rather than failing the whole feature.
    if (runErr != nil && [runErr isEqualToString:@"no-model"]) {
      CanopyReject(complete, @"rejected", @"RestoreEngine: no model bytes set");
      return;
    }
    Yout = resizePlane(Yin, kModelIn, kModelIn, kModelOut, kModelOut);
  }
  if (cancelled->load()) { CanopyReject(complete, @"cancelled", @"process cancelled"); return; }

  // --- upscale Cb/Cr to the output size and recombine YCbCr -> RGBA ---
  const int OW = kModelOut, OH = kModelOut;
  std::vector<float> CbUp = resizePlane(Cb, W, H, OW, OH);
  std::vector<float> CrUp = resizePlane(Cr, W, H, OW, OH);
  // A plain bicubic baseline of the input luma, to blend against by (1 - strength).
  std::vector<float> Ybase = resizePlane(Y, W, H, OW, OH);

  canopy::Blob out;
  out.kind = "rgba8";
  out.width = OW; out.height = OH;
  out.bytes.resize((size_t)OW * OH * 4);
  for (size_t i = 0; i < (size_t)OW * OH; ++i) {
    float ySr = Yout[i] * 255.0f;                       // super-res Y (model)
    float yBl = Ybase[i] * 255.0f;                      // baseline Y (bicubic)
    float y = (float)(yBl + (ySr - yBl) * strength);    // blend by strength
    float cb = CbUp[i] - 128.0f, cr = CrUp[i] - 128.0f;
    float r = y + 1.402f * cr;
    float g = y - 0.344136f * cb - 0.714136f * cr;
    float b = y + 1.772f * cb;
    out.bytes[i * 4 + 0] = clampByte(r);
    out.bytes[i * 4 + 1] = clampByte(g);
    out.bytes[i * 4 + 2] = clampByte(b);
    out.bytes[i * 4 + 3] = 255;
  }

  canopy::BlobHandle outHandle = canopy::globalBlobRegistry().put(std::move(out));
  CanopyResolve(complete, @{ @"image": @(outHandle), @"width": @(OW), @"height": @(OH) });
}

// ---- the RGB image->image pass (3-channel models: enhance / face / RGB super-res) -------------
// Mirrors RestoreEngineModule.cpp::runProcessRgb: pack the whole RGBA frame [1,3,D,D] (/255), run,
// unpack [1,3,oh,ow] (*255), resize by the model's spatial ratio, strength-blend over the bicubic
// baseline. (Larger inputs are downscaled to D for now; the windowed tiler is the follow-up.)
- (void)runProcessRgb:(std::shared_ptr<canopy::Blob>)in
             strength:(double)strength
            cancelled:(std::shared_ptr<std::atomic<bool>>)cancelled
             complete:(CanopyComplete)complete {
  const int W = in->width, H = in->height;
  const size_t n = (size_t)W * H;
  const int D = _inDim;
  const float s = (float)strength;
  const uint8_t *px = in->bytes.data();
  std::vector<float> R(n), G(n), B(n);
  for (size_t i = 0; i < n; ++i) { R[i] = px[i * 4 + 0]; G[i] = px[i * 4 + 1]; B[i] = px[i * 4 + 2]; }
  std::vector<float> rIn = resizePlane(R, W, H, D, D);
  std::vector<float> gIn = resizePlane(G, W, H, D, D);
  std::vector<float> bIn = resizePlane(B, W, H, D, D);
  if (cancelled->load()) { CanopyReject(complete, @"cancelled", @"process cancelled"); return; }

  // Pack NCHW [1,3,D,D] in [0,1] (channel order R,G,B).
  NSError *maErr = nil;
  MLMultiArray *input = [[MLMultiArray alloc] initWithShape:@[ @1, @3, @(D), @(D) ]
                                                   dataType:MLMultiArrayDataTypeFloat32
                                                      error:&maErr];
  if (input == nil) { CanopyReject(complete, @"rejected", @"RestoreEngine: RGB input alloc failed"); return; }
  float *dst = (float *)input.dataPointer;
  const size_t plane = (size_t)D * D;
  for (size_t i = 0; i < plane; ++i) {
    dst[i] = rIn[i] / 255.0f; dst[plane + i] = gIn[i] / 255.0f; dst[2 * plane + i] = bIn[i] / 255.0f;
  }

  MLModelDescription *desc = _model.modelDescription;
  NSString *inName = desc.inputDescriptionsByName.allKeys.firstObject ?: @"input";
  NSString *outName = desc.outputDescriptionsByName.allKeys.firstObject ?: @"output";
  MLDictionaryFeatureProvider *features =
      [[MLDictionaryFeatureProvider alloc] initWithDictionary:@{ inName: input } error:&maErr];
  if (features == nil) { CanopyReject(complete, @"rejected", @"RestoreEngine: RGB feature provider failed"); return; }
  NSError *predErr = nil;
  id<MLFeatureProvider> result = [_model predictionFromFeatures:features error:&predErr];
  if (result == nil) { CanopyReject(complete, @"rejected", @"RestoreEngine: RGB prediction failed"); return; }
  MLMultiArray *output = [result featureValueForName:outName].multiArrayValue;
  if (output == nil || output.dataType != MLMultiArrayDataTypeFloat32) {
    CanopyReject(complete, @"rejected", @"RestoreEngine: RGB output missing/!float32"); return;
  }
  // Derive the output spatial dims from the shape [1,3,oh,ow]; generalized bounds-check (the load-
  // bearing one): the buffer must actually hold 3*oh*ow floats before the contiguous copy.
  int oh = D, ow = D;
  NSArray<NSNumber *> *osh = output.shape;
  if (osh.count == 4) {
    if (osh[1].intValue != 3) { CanopyReject(complete, @"rejected", @"RestoreEngine: RGB output not 3ch"); return; }
    oh = osh[2].intValue; ow = osh[3].intValue;
  }
  const size_t oplane = (size_t)oh * ow;
  const size_t need = 3 * oplane;
  if ((size_t)output.count < need) {
    CanopyReject(complete, @"rejected", @"RestoreEngine: RGB output smaller than its shape"); return;
  }
  const float *outPtr = (const float *)output.dataPointer;
  std::vector<float> mr(outPtr, outPtr + oplane);
  std::vector<float> mg(outPtr + oplane, outPtr + 2 * oplane);
  std::vector<float> mb(outPtr + 2 * oplane, outPtr + 3 * oplane);
  if (cancelled->load()) { CanopyReject(complete, @"cancelled", @"process cancelled"); return; }

  const int OW = (int)((long long)W * ow / D), OH = (int)((long long)H * oh / D);
  std::vector<float> sr = resizePlane(mr, ow, oh, OW, OH);
  std::vector<float> sg = resizePlane(mg, ow, oh, OW, OH);
  std::vector<float> sb = resizePlane(mb, ow, oh, OW, OH);
  std::vector<float> baseR = resizePlane(R, W, H, OW, OH);
  std::vector<float> baseG = resizePlane(G, W, H, OW, OH);
  std::vector<float> baseB = resizePlane(B, W, H, OW, OH);

  canopy::Blob out;
  out.kind = "rgba8";
  out.width = OW; out.height = OH;
  out.bytes.resize((size_t)OW * OH * 4);
  for (size_t i = 0; i < (size_t)OW * OH; ++i) {
    float r = baseR[i] * (1.0f - s) + sr[i] * 255.0f * s;
    float g = baseG[i] * (1.0f - s) + sg[i] * 255.0f * s;
    float b = baseB[i] * (1.0f - s) + sb[i] * 255.0f * s;
    out.bytes[i * 4 + 0] = clampByte(r);
    out.bytes[i * 4 + 1] = clampByte(g);
    out.bytes[i * 4 + 2] = clampByte(b);
    out.bytes[i * 4 + 3] = 255;
  }
  canopy::BlobHandle outHandle = canopy::globalBlobRegistry().put(std::move(out));
  CanopyResolve(complete, @{ @"image": @(outHandle), @"width": @(OW), @"height": @(OH) });
}

// Run the Core ML model on a 224x224 Y plane, producing a 672x672 Y plane. Returns NO with
// *error="no-model" if no model is configured, or "load"/"predict" on a runtime failure.
- (BOOL)runModelY:(const std::vector<float>&)yIn out:(std::vector<float>&)yOut error:(NSString **)error {
  if (![self ensureModel:error]) { return NO; }

  // Pack the Y plane into the model's expected [1,1,224,224] float32 MLMultiArray.
  NSError *maErr = nil;
  MLMultiArray *input = [[MLMultiArray alloc] initWithShape:@[ @1, @1, @(kModelIn), @(kModelIn) ]
                                                   dataType:MLMultiArrayDataTypeFloat32
                                                      error:&maErr];
  if (input == nil) { if (error) { *error = @"load"; } return NO; }
  float *dst = (float *)input.dataPointer;
  memcpy(dst, yIn.data(), (size_t)kModelIn * kModelIn * sizeof(float));

  // The ESPCN model's IO feature names vary by conversion; we read the first input/output name
  // from the model description rather than hardcoding. (A converted restore.mlpackage typically
  // names them "input"/"output".)
  MLModelDescription *desc = _model.modelDescription;
  NSString *inName = desc.inputDescriptionsByName.allKeys.firstObject ?: @"input";
  NSString *outName = desc.outputDescriptionsByName.allKeys.firstObject ?: @"output";

  MLDictionaryFeatureProvider *features =
      [[MLDictionaryFeatureProvider alloc] initWithDictionary:@{ inName: input } error:&maErr];
  if (features == nil) { if (error) { *error = @"predict"; } return NO; }

  NSError *predErr = nil;
  id<MLFeatureProvider> result = [_model predictionFromFeatures:features error:&predErr];
  if (result == nil) { if (error) { *error = @"predict"; } return NO; }

  MLMultiArray *output = [result featureValueForName:outName].multiArrayValue;
  if (output == nil) { if (error) { *error = @"predict"; } return NO; }

  // The IO feature NAMES are read dynamically (conversions vary), so don't trust the output
  // SHAPE blindly: a differently-exported restore.mlpackage could yield a count != 672*672 or a
  // non-float32 buffer, and copying kModelOut*kModelOut floats from a smaller buffer is a heap
  // over-read. Validate element count + dtype before the contiguous copy.
  const size_t need = (size_t)kModelOut * kModelOut;
  if (output.dataType != MLMultiArrayDataTypeFloat32 || (size_t)output.count < need) {
    if (error) { *error = @"predict"; }
    return NO;
  }
  yOut.resize(need);
  const float *outPtr = (const float *)output.dataPointer;
  // Output is [1,1,672,672] float32, dense row-major — copy contiguously (bounds checked above).
  memcpy(yOut.data(), outPtr, need * sizeof(float));
  return YES;
}

// Lazily compile (if a .mlpackage) and load the model, off the JS thread, once.
- (BOOL)ensureModel:(NSString **)error {
  std::lock_guard<std::mutex> g(_modelMu);
  if (_model != nil) { return YES; }
  if (_modelURL == nil) { if (error) { *error = @"no-model"; } return NO; }

  NSURL *compiledURL = _modelURL;
  // A bundled .mlpackage / .mlmodel must be compiled to .mlmodelc before MLModel can load it.
  // Xcode compiles .mlmodel at build time; a raw .mlpackage handed in at runtime is compiled here.
  if (![_modelURL.pathExtension isEqualToString:@"mlmodelc"]) {
    NSError *compErr = nil;
    NSURL *out = [MLModel compileModelAtURL:_modelURL error:&compErr];
    if (out == nil) { if (error) { *error = @"load"; } return NO; }
    compiledURL = out;
  }
  MLModelConfiguration *config = [[MLModelConfiguration alloc] init];
  config.computeUnits = MLComputeUnitsAll;  // ANE -> GPU -> CPU
  NSError *loadErr = nil;
  _model = [MLModel modelWithContentsOfURL:compiledURL configuration:config error:&loadErr];
  if (_model == nil) { if (error) { *error = @"load"; } return NO; }

  // Read the I/O contract from the model's shape (mirrors the cpp OrtState). Flexible/empty shapes
  // keep the ESPCN stand-in fallback. [N,C,H,W].
  _inChannels = 1; _inDim = kModelIn; _outChannels = 1;
  MLModelDescription *d = _model.modelDescription;
  NSString *inKey = d.inputDescriptionsByName.allKeys.firstObject;
  NSArray<NSNumber *> *ishape = inKey ? d.inputDescriptionsByName[inKey].multiArrayConstraint.shape : nil;
  if (ishape.count == 4) {
    if (ishape[1].intValue > 0) { _inChannels = ishape[1].intValue; }
    if (ishape[2].intValue > 0) { _inDim = ishape[2].intValue; }
  }
  NSString *outKey = d.outputDescriptionsByName.allKeys.firstObject;
  NSArray<NSNumber *> *oshape = outKey ? d.outputDescriptionsByName[outKey].multiArrayConstraint.shape : nil;
  if (oshape.count == 4 && oshape[1].intValue > 0) { _outChannels = oshape[1].intValue; }
  _rgb = (_inChannels == 3);
  return YES;
}

@end

// =============================================================================================
// FACTORY + ADAPTER — defines the weak symbol CanopyModuleHost.mm reaches for (it weak-declares
// canopy::CanopyMakeCoreMLRestoreModule and calls it in -registerAll). Without a strong definition
// the weak symbol is null at link and RestoreEngine is SILENTLY ABSENT on iOS (the audit defect).
//
// CanopyRestoreEngineModule adopts the ObjC <CanopyModule> protocol (it is NOT a C++
// canopy::NativeModule), so it cannot be registered directly into the ModuleRegistry. We adapt it
// into a C++ NativeModule with the SAME direct-ObjC-dispatch shape as CanopyNativeModule.mm's
// private ObjCNativeModule (that class is file-private to the bridge .mm, so we carry a tiny local
// forwarder here rather than widen the bridge API — one-file, conflict-free).
// =============================================================================================

#include "CanopyModules.h"   // canopy::NativeModule / CallContext (resolved via HEADER_SEARCH_PATHS)

namespace canopy {
namespace {

inline NSString *RE_toNS(const std::string &s) {
  NSString *out = [[NSString alloc] initWithBytes:s.data()
                                           length:(NSUInteger)s.size()
                                         encoding:NSUTF8StringEncoding];
  return out ?: @"";
}
inline std::string RE_toStd(NSString *_Nullable s) {
  if (s == nil) { return std::string(); }
  const char *c = [s UTF8String];
  return c ? std::string(c) : std::string();
}

// Adapts the ObjC CanopyRestoreEngineModule (id<CanopyModule>) into a C++ NativeModule, mirroring
// the bridge's ObjCNativeModule: invoke() forwards to -invokeMethod:args:callId:complete: via a
// CanopyComplete block (the registry already wrapped ctx.complete to hop to the JS thread, so the
// worker queue never touches the runtime); cancel() forwards to -cancelCallId:.
class RestoreEngineObjCModule final : public NativeModule {
 public:
  explicit RestoreEngineObjCModule(CanopyRestoreEngineModule *m)
      : module_(m), name_(RE_toStd([m moduleName])) {}

  std::string name() const override { return name_; }

  bool invoke(CallContext &ctx) override {
    auto complete = ctx.complete;
    CanopyComplete block = ^(NSString *_Nullable errJson, NSString *_Nullable resultJson) {
      if (complete) { complete(RE_toStd(errJson), RE_toStd(resultJson)); }
    };
    @autoreleasepool {
      @try {
        BOOL known = [module_ invokeMethod:RE_toNS(ctx.method)
                                      args:RE_toNS(ctx.argsJson)
                                    callId:RE_toNS(ctx.callId)
                                  complete:block];
        return known ? true : false;
      } @catch (NSException *ex) {
        if (complete) {
          NSString *msg = ex.reason ?: @"restore invoke threw";
          complete(std::string("{\"code\":\"rejected\",\"message\":\"") + RE_toStd(msg) + "\"}",
                   std::string());
        }
        return true;
      }
    }
  }

  void cancel(const std::string &callId) override {
    if (![module_ respondsToSelector:@selector(cancelCallId:)]) { return; }
    @autoreleasepool {
      @try { [module_ cancelCallId:RE_toNS(callId)]; }
      @catch (NSException *) { /* best-effort, idempotent */ }
    }
  }

 private:
  CanopyRestoreEngineModule *module_;  // strong (ARC): kept alive for the registry's lifetime
  std::string name_;
};

}  // namespace

// The strong definition CanopyModuleHost weak-declares. Returns a NativeModule named
// "RestoreEngine"; NEVER nullptr — the module is the dispatch surface and self-handles a missing
// model (process() rejects with "no model bytes set" rather than the capability being absent).
// modelPath is the bundle path resolved by CanopyModuleHost (may be empty until a model ships).
// TODO(ANE): when restore.mlpackage is bundled, -ensureModel:/-runModelY: run on MLComputeUnitsAll.
std::shared_ptr<NativeModule> CanopyMakeCoreMLRestoreModule(const std::string& modelPath) {
  CanopyRestoreEngineModule *m = [[CanopyRestoreEngineModule alloc] init];
  if (!modelPath.empty()) {
    NSString *p = RE_toNS(modelPath);
    NSURL *url = [p hasPrefix:@"file:"] ? [NSURL URLWithString:p] : [NSURL fileURLWithPath:p];
    if (url) { [m setModelURL:url]; }
  }
  return std::make_shared<RestoreEngineObjCModule>(m);
}

}  // namespace canopy

// =============================================================================================
// Path B (no Core ML model yet): register the PORTABLE ORT RestoreEngineModule verbatim instead.
//
// The portable canopy::RestoreEngineModule (shared/cpp) is a complete NativeModule with the SAME
// "RestoreEngine" name and wire contract. If the iOS target links onnxruntime.xcframework and
// bundles super-resolution-10.onnx, CanopyModuleHost can register it directly with NO ObjC bridge:
//
//   auto restore = std::make_shared<canopy::RestoreEngineModule>();
//   restore->loadModelFromFile([[NSBundle.mainBundle pathForResource:@"super-resolution-10"
//                                                              ofType:@"onnx"] UTF8String]);
//   registry->registerModule(restore);
//
// Only ONE "RestoreEngine" may be registered. Choose the Core ML module above (the mandate) OR the
// portable ORT module — not both. This file is the Core ML path; the comment documents the reuse.
// =============================================================================================
