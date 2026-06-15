// CanopyPhotosModule.mm — the iOS host module behind canopy/photos (module "Photos").
//
// iOS analog of android/.../modules/PhotosModule.java. Adopts the §4.1 CanopyModule protocol;
// the §4.2 bridge routes __canopy_call(module="Photos", …) here. The big difference from
// CanopyImageModule: "pick" can't run purely on a background queue — it presents a
// PHPickerViewController, a UI flow owned by the foreground scene's view controller. We present
// on the MAIN queue, load the picked NSItemProvider -> UIImage off the picker callback, decode/
// downsample on a background queue to the same megapixel budget as canopy/image, PUT the UIImage
// into the ONE shared C++ registry via the §6.3 bridge, and resolve {image,width,height}. A
// dismissed picker rejects with {code:"cancelled"} (mapped to Native.Module.Rejected, treated as
// a no-op by the app) — matching PhotosModule.java:99-103.
//
// PHPicker requires NO photo-library permission prompt (it runs out-of-process), so Photos.pick
// needs no NSPhotoLibraryUsageDescription entry — a genuine iOS win over the Android picker.
//
// Wire contract (must match photos.js / Photos.can and PhotosModule.java):
//   pick     {}        -> {image,width,height}   |  err {code:"cancelled"} on dismiss
//   release  {image}   -> null

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <PhotosUI/PhotosUI.h>

#include <memory>

#import "CanopyModule.h"
#import "CanopyModuleSupport.h"
#import "CanopyBlobRegistryHost.h"   // §6.3 blobPutUIImage / globalBlobRegistry
#include "CanopyBlobs.h"

static const double kPhotosMaxMegapixels = 4.0;  // matches PhotosModule.java:51 / canopy/image

// A one-shot picker delegate that owns the completion for a single pick. PHPickerViewController
// retains its delegate weakly, so we keep ourselves alive in an instance set until the result
// lands, then release. This is the iOS analog of MainActivity's launcher + callId bookkeeping.
@interface CanopyPickerSession : NSObject <PHPickerViewControllerDelegate>
@property(nonatomic, copy) CanopyComplete complete;
@property(nonatomic, copy) void (^onFinished)(CanopyPickerSession *);
@end

@implementation CanopyPickerSession

- (void)picker:(PHPickerViewController *)picker
    didFinishPicking:(NSArray<PHPickerResult *> *)results {
  [picker dismissViewControllerAnimated:YES completion:nil];

  if (results.count == 0) {
    // User dismissed without choosing -> "cancelled" (a clean no-op on the Canopy side).
    CanopyReject(self.complete, @"cancelled", @"picker dismissed");
    if (self.onFinished) { self.onFinished(self); }
    return;
  }

  NSItemProvider *provider = results.firstObject.itemProvider;
  if (![provider canLoadObjectOfClass:[UIImage class]]) {
    CanopyReject(self.complete, @"rejected", @"picked item is not an image");
    if (self.onFinished) { self.onFinished(self); }
    return;
  }

  CanopyComplete complete = self.complete;
  __weak CanopyPickerSession *weakSelf = self;
  [provider loadObjectOfClass:[UIImage class]
            completionHandler:^(__kindof id<NSItemProviderReading> object, NSError *error) {
    // The provider callback runs on an arbitrary queue — do the downsample + blob put there.
    if (error != nil || ![object isKindOfClass:[UIImage class]]) {
      CanopyReject(complete, @"rejected",
                   error.localizedDescription ?: @"could not load picked image");
    } else {
      UIImage *picked = (UIImage *)object;
      UIImage *budgeted = CanopyDownsampleUIImage(picked, kPhotosMaxMegapixels);
      int w = (int)llround(budgeted.size.width * budgeted.scale);
      int h = (int)llround(budgeted.size.height * budgeted.scale);
      canopy::BlobHandle handle = canopy::blobPutUIImage(budgeted);
      if (handle == 0) {
        CanopyReject(complete, @"rejected", @"blob put failed");
      } else {
        CanopyResolve(complete, @{ @"image": @(handle), @"width": @(w), @"height": @(h) });
      }
    }
    CanopyPickerSession *strongSelf = weakSelf;
    if (strongSelf && strongSelf.onFinished) { strongSelf.onFinished(strongSelf); }
  }];
}

@end

@interface CanopyPhotosModule : NSObject <CanopyModule>
@end

@implementation CanopyPhotosModule {
  NSMutableSet<CanopyPickerSession *> *_sessions;  // keeps live pick sessions alive
}

- (instancetype)init {
  if ((self = [super init])) { _sessions = [NSMutableSet set]; }
  return self;
}

- (NSString *)moduleName { return @"Photos"; }

- (BOOL)invokeMethod:(NSString *)method
                args:(NSString *)argsJson
              callId:(NSString *)callId
            complete:(CanopyComplete)complete {
  if ([method isEqualToString:@"pick"]) {
    dispatch_async(dispatch_get_main_queue(), ^{ [self presentPicker:complete]; });
    return YES;
  }
  if ([method isEqualToString:@"release"]) {
    NSDictionary *args = CanopyParseArgs(argsJson);
    canopy::BlobHandle h = (canopy::BlobHandle)[args[@"image"] intValue];
    canopy::globalBlobRegistry().release(h);
    CanopyResolveNull(complete);
    return YES;
  }
  return NO;  // unknown method -> ModuleNotFound
}

- (void)presentPicker:(CanopyComplete)complete {
  UIViewController *host = CanopyTopViewController();
  if (host == nil) {
    CanopyReject(complete, @"rejected", @"Photos: no foreground view controller to host the picker");
    return;
  }
  PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
  config.selectionLimit = 1;
  config.filter = [PHPickerFilter imagesFilter];

  PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
  CanopyPickerSession *session = [[CanopyPickerSession alloc] init];
  session.complete = complete;
  __weak CanopyPhotosModule *weakSelf = self;
  session.onFinished = ^(CanopyPickerSession *s) {
    CanopyPhotosModule *strongSelf = weakSelf;
    if (strongSelf) { [strongSelf->_sessions removeObject:s]; }
  };
  [_sessions addObject:session];
  picker.delegate = session;
  [host presentViewController:picker animated:YES completion:nil];
}

@end
