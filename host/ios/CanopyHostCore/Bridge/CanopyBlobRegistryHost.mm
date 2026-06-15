// CanopyBlobRegistryHost.mm — THE single process-wide BlobRegistry definition + the UIImage<->Blob
// bridge for iOS (contract §6.3 / Risk #8). The Android equivalent is CanopyJni.cpp:173's
// globalBlobRegistry() + the Bitmap bridge in CanopyBlobs.cpp. This is the iOS definition site;
// every consumer (the renderer's CanopyBitmap, Image/Photos/Album/Share, Core ML RestoreEngine)
// links THIS symbol so all handles agree.
//
// [MAC-VALIDATE]: the CoreGraphics premultiplied-vs-straight-alpha nuance below needs a
// simulator round-trip to confirm pixel fidelity for transparent images. Opaque images
// (the photo-restore pipeline) are unaffected.

#import "CanopyBlobRegistryHost.h"

#import <CoreGraphics/CoreGraphics.h>

namespace canopy {

BlobRegistry& globalBlobRegistry() {
  static BlobRegistry registry;   // function-local static: thread-safe init, single definition
  return registry;
}

BlobHandle blobPutUIImage(UIImage* img) {
  if (img == nil) { return 0; }
  CGImageRef cg = img.CGImage;
  if (cg == nullptr) { return 0; }
  const size_t w = CGImageGetWidth(cg);
  const size_t h = CGImageGetHeight(cg);
  if (w == 0 || h == 0) { return 0; }

  const size_t stride = w * 4;  // tight RGBA8
  Blob blob;
  blob.kind = "rgba8";
  blob.width = static_cast<int>(w);
  blob.height = static_cast<int>(h);
  blob.bytes.resize(stride * h);

  CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
  // CGBitmapContext draws premultiplied; for the opaque photo pipeline this equals straight RGBA.
  CGContextRef ctx = CGBitmapContextCreate(
      blob.bytes.data(), w, h, /*bitsPerComponent*/ 8, stride, space,
      kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
  CGColorSpaceRelease(space);
  if (ctx == nullptr) { return 0; }
  CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
  CGContextRelease(ctx);

  return globalBlobRegistry().put(std::move(blob));
}

UIImage* blobGetUIImage(BlobHandle handle) {
  std::shared_ptr<Blob> blob = globalBlobRegistry().get(handle);
  if (!blob || blob->kind != "rgba8" || blob->bytes.empty()) { return nil; }
  const size_t w = static_cast<size_t>(blob->width);
  const size_t h = static_cast<size_t>(blob->height);
  if (w == 0 || h == 0 || blob->bytes.size() < w * 4 * h) { return nil; }

  const size_t stride = w * 4;
  CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
  CFDataRef data = CFDataCreate(nullptr, blob->bytes.data(), static_cast<CFIndex>(stride * h));
  CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
  CGImageRef cg = CGImageCreate(
      w, h, /*bitsPerComponent*/ 8, /*bitsPerPixel*/ 32, stride, space,
      kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big,
      provider, nullptr, /*shouldInterpolate*/ false, kCGRenderingIntentDefault);
  UIImage* img = (cg != nullptr) ? [UIImage imageWithCGImage:cg] : nil;
  if (cg != nullptr) { CGImageRelease(cg); }
  CGDataProviderRelease(provider);
  CFRelease(data);
  CGColorSpaceRelease(space);
  return img;
}

}  // namespace canopy
