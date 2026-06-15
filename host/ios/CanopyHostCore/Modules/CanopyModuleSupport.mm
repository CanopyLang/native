// CanopyModuleSupport.mm — implementation of the shared capability-module helpers.
// See CanopyModuleSupport.h. Pure Foundation/UIKit/ImageIO; touches no jsi::Runtime and no
// shared C++ ABI beyond passing strings to the CanopyComplete block.

#import "CanopyModuleSupport.h"

#import <ImageIO/ImageIO.h>

NSDictionary *CanopyParseArgs(NSString *argsJson) {
  if (argsJson == nil || argsJson.length == 0 || [argsJson isEqualToString:@"null"]) {
    return @{};
  }
  NSData *data = [argsJson dataUsingEncoding:NSUTF8StringEncoding];
  if (data == nil) { return @{}; }
  NSError *err = nil;
  id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
  if ([obj isKindOfClass:[NSDictionary class]]) { return (NSDictionary *)obj; }
  return @{};
}

// Serialize an NSDictionary to a compact JSON string. Returns "{}" on failure so we never hand
// a malformed payload to the resolver.
static NSString *CanopyJSONString(NSDictionary *dict) {
  NSError *err = nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:&err];
  if (data == nil) { return @"{}"; }
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"{}";
}

void CanopyResolve(CanopyComplete complete, NSDictionary *result) {
  complete(nil, CanopyJSONString(result));  // errJson nil => success
}

void CanopyResolveNull(CanopyComplete complete) {
  complete(nil, @"null");
}

void CanopyReject(CanopyComplete complete, NSString *code, NSString *message) {
  NSDictionary *err = @{ @"code": code ?: @"rejected",
                         @"message": message ?: @"" };
  complete(CanopyJSONString(err), nil);  // resultJson nil => error
}

NSData *CanopyReadURI(NSString *uriStr) {
  if (uriStr.length == 0) { return nil; }

  // asset:NAME — a bundled app resource (mirrors ImageModule.java's "asset" scheme for demos/
  // probes shipping a sample image). The name may include an extension or a subpath.
  if ([uriStr hasPrefix:@"asset:"]) {
    NSString *name = [uriStr substringFromIndex:6];
    while ([name hasPrefix:@"/"]) { name = [name substringFromIndex:1]; }
    NSString *ext = [name pathExtension];
    NSString *base = ext.length ? [name stringByDeletingPathExtension] : name;
    NSString *path = [[NSBundle mainBundle] pathForResource:base ofType:(ext.length ? ext : nil)];
    if (path == nil) { return nil; }
    return [NSData dataWithContentsOfFile:path];
  }

  NSURL *url = [NSURL URLWithString:uriStr];
  // Bare path (no scheme) -> treat as a filesystem path.
  if (url == nil || url.scheme == nil) {
    return [NSData dataWithContentsOfFile:uriStr];
  }
  if ([url.scheme isEqualToString:@"file"]) {
    return [NSData dataWithContentsOfURL:url];
  }
  if ([url.scheme hasPrefix:@"http"]) {
    // Caller is already on a background queue; a synchronous fetch is acceptable here (the same
    // posture as Android decoding a content:// stream on its worker).
    return [NSData dataWithContentsOfURL:url];
  }
  // ph://, content-ish, or anything else NSData can open directly.
  return [NSData dataWithContentsOfURL:url];
}

UIImage *CanopyDecodeDownsampled(NSData *data, double maxMegapixels) {
  if (data.length == 0) { return nil; }
  CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
  if (source == NULL) { return nil; }

  // Read the pixel dimensions from the header only (no full decode) — the ImageIO analog of
  // Android's inJustDecodeBounds pass.
  CGFloat pixelW = 0, pixelH = 0;
  CFDictionaryRef props = CGImageSourceCopyPropertiesAtIndex(source, 0, NULL);
  if (props != NULL) {
    CFNumberRef wNum = (CFNumberRef)CFDictionaryGetValue(props, kCGImagePropertyPixelWidth);
    CFNumberRef hNum = (CFNumberRef)CFDictionaryGetValue(props, kCGImagePropertyPixelHeight);
    if (wNum) { CFNumberGetValue(wNum, kCFNumberCGFloatType, &pixelW); }
    if (hNum) { CFNumberGetValue(hNum, kCFNumberCGFloatType, &pixelH); }
    CFRelease(props);
  }

  // The max edge that keeps width*height under the megapixel budget (preserving aspect). When we
  // cannot read dimensions, fall back to a conservative 2048px max edge.
  CGFloat maxEdge;
  if (pixelW > 0 && pixelH > 0) {
    double budget = maxMegapixels * 1000000.0;
    double pixels = (double)pixelW * (double)pixelH;
    double ratio = pixels > budget ? sqrt(budget / pixels) : 1.0;
    maxEdge = ceil(MAX(pixelW, pixelH) * ratio);
  } else {
    maxEdge = 2048;
  }

  NSDictionary *thumbOpts = @{
    (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
    (id)kCGImageSourceCreateThumbnailWithTransform:   @YES,   // bake in EXIF orientation
    (id)kCGImageSourceShouldCacheImmediately:         @YES,
    (id)kCGImageSourceThumbnailMaxPixelSize:          @(maxEdge),
  };
  CGImageRef cg = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)thumbOpts);
  CFRelease(source);
  if (cg == NULL) { return nil; }
  UIImage *img = [UIImage imageWithCGImage:cg scale:1.0 orientation:UIImageOrientationUp];
  CGImageRelease(cg);
  return img;
}

UIImage *CanopyResizeImage(UIImage *src, int w, int h) {
  if (w <= 0 || h <= 0) { return nil; }
  CGSize size = CGSizeMake(w, h);
  UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
  fmt.scale = 1.0;                 // pixel size == point size, so the blob picks up (w, h) exactly
  fmt.opaque = NO;                 // preserve alpha
  UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:fmt];
  return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
    [src drawInRect:CGRectMake(0, 0, w, h)];
  }];
}

UIImage *CanopyDownsampleUIImage(UIImage *img, double maxMegapixels) {
  CGFloat w = img.size.width * img.scale;
  CGFloat h = img.size.height * img.scale;
  double pixels = (double)w * (double)h;
  double budget = maxMegapixels * 1000000.0;
  if (pixels <= budget || w <= 0 || h <= 0) { return img; }
  double ratio = sqrt(budget / pixels);
  int nw = MAX(1, (int)llround(w * ratio));
  int nh = MAX(1, (int)llround(h * ratio));
  UIImage *resized = CanopyResizeImage(img, nw, nh);
  return resized ?: img;
}

UIViewController *CanopyTopViewController(void) {
  UIWindow *keyWindow = nil;
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
    if (scene.activationState == UISceneActivationStateForegroundActive &&
        [scene isKindOfClass:[UIWindowScene class]]) {
      for (UIWindow *win in ((UIWindowScene *)scene).windows) {
        if (win.isKeyWindow) { keyWindow = win; break; }
      }
      if (keyWindow == nil) { keyWindow = ((UIWindowScene *)scene).windows.firstObject; }
      if (keyWindow) { break; }
    }
  }
  UIViewController *vc = keyWindow.rootViewController;
  while (vc.presentedViewController != nil) { vc = vc.presentedViewController; }
  return vc;
}
