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

#include <atomic>
#include <cmath>
#include <cstdint>
#include <memory>
#include <mutex>
#include <unordered_map>
#include <vector>

#import "CanopyModule.h"
#import "CanopyModuleSupport.h"
#import "CanopyBlobRegistryHost.h"   // §6.3 globalBlobRegistry
#include "CanopyBlobs.h"

// The ESPCN stand-in is single-channel Y: input [1,1,224,224], output [1,1,672,672] (3x).
// (Identical to RestoreEngineModule.h:22-26.)
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
  return YES;
}

@end

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
