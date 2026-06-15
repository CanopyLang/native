// CanopyImageModule.mm — the iOS host module behind canopy/image (module "Image").
//
// iOS analog of android/.../modules/ImageModule.java. Adopts the §4.1 CanopyModule protocol;
// the §4.2 CanopyNativeModuleBridge wraps it into a canopy::NativeModule and registers it,
// so __canopy_call(module="Image", method, argsJson, callId) routes here. We do the real work
// — decode (DOWNSAMPLED to a megapixel budget), dimensions, resize, encodeToFile, composite,
// release — on a background GCD queue, move UIImage pixels in/out of the ONE shared C++
// canopy::globalBlobRegistry() via the §6.3 UIImage<->Blob bridge, and call the CanopyComplete
// block (errJson nil = success). The block already hops to the JS thread via the registry's
// postToJs (CanopyModules.cpp:62-70), so calling it from a background queue is correct — there
// is NO manual main-hop here (contract §0.2 / §4.2).
//
// Handle discipline (mirrors the Android module exactly): a PRODUCER (decode/resize/composite)
// PUTs a UIImage into the registry and returns {"image":h,"width":w,"height":h}. A CONSUMER
// (encodeToFile/dimensions) GETs the image back from the handle and uses it. release drops a
// registry reference. Pixels NEVER cross as JSON — only the int handle.
//
// Wire contract (must match image.js / Image.can and ImageModule.java):
//   decode       {uri}                                   -> {image,width,height}
//   dimensions   {image}                                  -> {width,height}
//   resize       {image,maxWidth,maxHeight}               -> {image,width,height}
//   encodeToFile {image,format:"jpeg"|"png",quality:0..1} -> {uri:"file://…"}
//   composite    {dst,src,x,y}                            -> {image,width,height}
//   release      {image}                                  -> null

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include <memory>

#import "CanopyModule.h"               // §4.1 protocol (Author E)
#import "CanopyBlobRegistryHost.h"     // §6.3 globalBlobRegistry() + UIImage<->Blob (Author E)
#include "CanopyImage.h"               // portable imageCompositeOver (shared C++)
#include "CanopyBlobs.h"

// Downsample budget — a decoded source is never allowed past this many megapixels. Matches the
// Android MAX_MEGAPIXELS (ImageModule.java:53) so a decoded photo lands at the same fidelity.
static const double kMaxMegapixels = 4.0;

@interface CanopyImageModule : NSObject <CanopyModule>
@end

@implementation CanopyImageModule {
  // One serial queue so decodes serialize (bounded memory) but never touch the JS/main thread.
  dispatch_queue_t _queue;
}

- (instancetype)init {
  if ((self = [super init])) {
    _queue = dispatch_queue_create("com.canopyhost.image", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

- (NSString *)moduleName { return @"Image"; }

- (BOOL)invokeMethod:(NSString *)method
                args:(NSString *)argsJson
              callId:(NSString *)callId
            complete:(CanopyComplete)complete {
  // Recognize the method synchronously (so unknown methods report ModuleNotFound) but do the
  // work on the background queue.
  if (![method isEqualToString:@"decode"] &&
      ![method isEqualToString:@"dimensions"] &&
      ![method isEqualToString:@"resize"] &&
      ![method isEqualToString:@"encodeToFile"] &&
      ![method isEqualToString:@"composite"] &&
      ![method isEqualToString:@"release"]) {
    return NO;  // unknown method -> dispatcher reports -1 / ModuleNotFound
  }

  dispatch_async(_queue, ^{
    @try {
      NSDictionary *args = CanopyParseArgs(argsJson);
      if ([method isEqualToString:@"decode"])           { [self doDecode:args complete:complete]; }
      else if ([method isEqualToString:@"dimensions"])  { [self doDimensions:args complete:complete]; }
      else if ([method isEqualToString:@"resize"])      { [self doResize:args complete:complete]; }
      else if ([method isEqualToString:@"encodeToFile"]){ [self doEncodeToFile:args complete:complete]; }
      else if ([method isEqualToString:@"composite"])   { [self doComposite:args complete:complete]; }
      else if ([method isEqualToString:@"release"])     { [self doRelease:args complete:complete]; }
    } @catch (NSException *e) {
      CanopyReject(complete, @"rejected", e.reason ?: @"image error");
    }
  });
  return YES;
}

// ---- decode (downsampled to the megapixel budget via ImageIO thumbnail) -------------------

- (void)doDecode:(NSDictionary *)args complete:(CanopyComplete)complete {
  NSString *uriStr = args[@"uri"];
  if (![uriStr isKindOfClass:[NSString class]] || uriStr.length == 0) {
    CanopyReject(complete, @"rejected", @"missing uri"); return;
  }
  NSData *data = CanopyReadURI(uriStr);
  if (data == nil) { CanopyReject(complete, @"rejected", [@"could not read image: " stringByAppendingString:uriStr]); return; }

  UIImage *img = CanopyDecodeDownsampled(data, kMaxMegapixels);
  if (img == nil) { CanopyReject(complete, @"rejected", [@"decode failed: " stringByAppendingString:uriStr]); return; }
  [self resolveImage:img complete:complete];  // puts, returns {image,width,height}
}

// ---- dimensions ---------------------------------------------------------------------------

- (void)doDimensions:(NSDictionary *)args complete:(CanopyComplete)complete {
  canopy::BlobHandle h = (canopy::BlobHandle)[args[@"image"] intValue];
  UIImage *img = canopy::blobGetUIImage(h);
  if (img == nil) { CanopyReject(complete, @"rejected", [NSString stringWithFormat:@"unknown handle %d", h]); return; }
  int w = (int)llround(img.size.width * img.scale);
  int hgt = (int)llround(img.size.height * img.scale);
  CanopyResolve(complete, @{ @"width": @(w), @"height": @(hgt) });
}

// ---- resize (aspect-preserving, fit within maxWidth x maxHeight) --------------------------

- (void)doResize:(NSDictionary *)args complete:(CanopyComplete)complete {
  canopy::BlobHandle h = (canopy::BlobHandle)[args[@"image"] intValue];
  int maxW = [args[@"maxWidth"] intValue];
  int maxH = [args[@"maxHeight"] intValue];
  UIImage *src = canopy::blobGetUIImage(h);
  if (src == nil) { CanopyReject(complete, @"rejected", [NSString stringWithFormat:@"unknown handle %d", h]); return; }

  CGFloat srcW = src.size.width * src.scale;
  CGFloat srcH = src.size.height * src.scale;
  double scale = MIN((double)maxW / srcW, (double)maxH / srcH);
  if (scale >= 1.0) {
    // Already within bounds: re-put the same pixels under a fresh handle (independent lifetime).
    [self resolveImage:src complete:complete];
    return;
  }
  int w = MAX(1, (int)llround(srcW * scale));
  int hgt = MAX(1, (int)llround(srcH * scale));
  UIImage *scaled = CanopyResizeImage(src, w, hgt);
  if (scaled == nil) { CanopyReject(complete, @"rejected", @"resize failed"); return; }
  [self resolveImage:scaled complete:complete];
}

// ---- encodeToFile (JPEG/PNG to NSTemporaryDirectory, returns file:// uri) ------------------

- (void)doEncodeToFile:(NSDictionary *)args complete:(CanopyComplete)complete {
  canopy::BlobHandle h = (canopy::BlobHandle)[args[@"image"] intValue];
  NSString *format = [args[@"format"] isKindOfClass:[NSString class]] ? args[@"format"] : @"jpeg";
  double quality = args[@"quality"] ? [args[@"quality"] doubleValue] : 0.9;
  quality = MAX(0.0, MIN(1.0, quality));
  UIImage *img = canopy::blobGetUIImage(h);
  if (img == nil) { CanopyReject(complete, @"rejected", [NSString stringWithFormat:@"unknown handle %d", h]); return; }

  BOOL png = [format caseInsensitiveCompare:@"png"] == NSOrderedSame;
  NSData *encoded = png ? UIImagePNGRepresentation(img)
                        : UIImageJPEGRepresentation(img, (CGFloat)quality);
  if (encoded == nil) { CanopyReject(complete, @"rejected", @"encode failed"); return; }

  NSString *ext = png ? @"png" : @"jpg";
  NSString *name = [NSString stringWithFormat:@"canopy-img-%d-%@.%@", h,
                    [[NSUUID UUID] UUIDString], ext];
  NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
  NSError *err = nil;
  if (![encoded writeToFile:path options:NSDataWritingAtomic error:&err]) {
    CanopyReject(complete, @"rejected", err.localizedDescription ?: @"file write failed"); return;
  }
  NSString *fileUri = [[NSURL fileURLWithPath:path] absoluteString];  // file://…
  CanopyResolve(complete, @{ @"uri": fileUri });
}

// ---- composite (src over dst at x,y -> new handle, via the portable C++ blob op) ----------

- (void)doComposite:(NSDictionary *)args complete:(CanopyComplete)complete {
  canopy::BlobHandle dst = (canopy::BlobHandle)[args[@"dst"] intValue];
  canopy::BlobHandle src = (canopy::BlobHandle)[args[@"src"] intValue];
  int x = [args[@"x"] intValue];
  int y = [args[@"y"] intValue];
  // Reuse the portable RGBA-blob compositor (CanopyImage.h:27) rather than re-doing pixel work.
  // It produces a new rgba8 blob (refcount 1) and leaves dst/src untouched (the caller owns them).
  canopy::BlobHandle out = canopy::imageCompositeOver(dst, src, x, y);
  if (out == 0) { CanopyReject(complete, @"rejected", @"unknown handle in composite"); return; }
  std::shared_ptr<canopy::Blob> blob = canopy::globalBlobRegistry().get(out);
  int w = blob ? blob->width : 0;
  int hgt = blob ? blob->height : 0;
  CanopyResolve(complete, @{ @"image": @(out), @"width": @(w), @"height": @(hgt) });
}

// ---- release ------------------------------------------------------------------------------

- (void)doRelease:(NSDictionary *)args complete:(CanopyComplete)complete {
  canopy::BlobHandle h = (canopy::BlobHandle)[args[@"image"] intValue];
  canopy::globalBlobRegistry().release(h);
  CanopyResolveNull(complete);
}

// ---- helpers ------------------------------------------------------------------------------

// PUT a UIImage into the shared registry and resolve {image,width,height}.
- (void)resolveImage:(UIImage *)img complete:(CanopyComplete)complete {
  int w = (int)llround(img.size.width * img.scale);
  int hgt = (int)llround(img.size.height * img.scale);
  canopy::BlobHandle handle = canopy::blobPutUIImage(img);  // RGBA8 straight-alpha, refcount 1
  if (handle == 0) { CanopyReject(complete, @"rejected", @"blob put failed"); return; }
  CanopyResolve(complete, @{ @"image": @(handle), @"width": @(w), @"height": @(hgt) });
}

@end
