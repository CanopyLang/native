// CanopyAlbumModule.mm — the iOS host module behind canopy/album (module "Album").
//
// iOS analog of android/.../modules/AlbumModule.java. Adopts the §4.1 CanopyModule protocol;
// the §4.2 bridge routes __canopy_call(module="Album", …) here. We save a native image handle
// into the device photo gallery: GET the UIImage out of the ONE shared C++ registry (§6.3
// bridge), encode it (JPEG/PNG), and add it to the user's Photo Library via PHPhotoLibrary
// performChanges with PHAssetCreationRequest. We resolve {uri:"ph://<localIdentifier>"} — the
// iOS analog of Android's content:// MediaStore uri.
//
// CONSUMER discipline (mirrors AlbumModule.java): GET the image from the handle, save it, and do
// NOT release the handle (the caller owns its lifetime via Image.release). Pixels never cross as
// JSON — only the int handle does.
//
// Permission: add-only Photo Library access (PHAccessLevelAddOnly) requires
// NSPhotoLibraryAddUsageDescription in Info.plist (Author A) but NOT full-library read. We
// request authorization lazily; a denied/restricted status rejects with {code:"rejected"}.
//
// Wire contract (must match album.js / Album.can and AlbumModule.java):
//   save  {image:<handle>, format:"jpeg"|"png"}  ->  {uri:"ph://<localIdentifier>"}

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Photos/Photos.h>

#include <memory>

#import "CanopyModule.h"
#import "CanopyModuleSupport.h"
#import "CanopyBlobRegistryHost.h"   // §6.3 blobGetUIImage
#include "CanopyBlobs.h"

@interface CanopyAlbumModule : NSObject <CanopyModule>
@end

@implementation CanopyAlbumModule {
  dispatch_queue_t _queue;  // serialize encodes off the JS/main thread
}

- (instancetype)init {
  if ((self = [super init])) {
    _queue = dispatch_queue_create("com.canopyhost.album", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

- (NSString *)moduleName { return @"Album"; }

- (BOOL)invokeMethod:(NSString *)method
                args:(NSString *)argsJson
              callId:(NSString *)callId
            complete:(CanopyComplete)complete {
  if (![method isEqualToString:@"save"]) { return NO; }  // ModuleNotFound for anything else

  dispatch_async(_queue, ^{
    @try {
      NSDictionary *args = CanopyParseArgs(argsJson);
      canopy::BlobHandle h = (canopy::BlobHandle)[args[@"image"] intValue];
      NSString *format = [args[@"format"] isKindOfClass:[NSString class]] ? args[@"format"] : @"jpeg";
      BOOL png = [format caseInsensitiveCompare:@"png"] == NSOrderedSame;

      UIImage *img = canopy::blobGetUIImage(h);  // CONSUMER GET — does NOT release
      if (img == nil) {
        CanopyReject(complete, @"rejected", [NSString stringWithFormat:@"unknown handle %d", h]);
        return;
      }
      NSData *data = png ? UIImagePNGRepresentation(img)
                         : UIImageJPEGRepresentation(img, 0.95);
      if (data == nil) { CanopyReject(complete, @"rejected", @"image encode failed"); return; }

      [self saveData:data complete:complete];
    } @catch (NSException *e) {
      CanopyReject(complete, @"rejected", e.reason ?: @"album save error");
    }
  });
  return YES;
}

// Request add-only authorization, then add the image data as a new asset and report its
// localIdentifier. PHPhotoLibrary's completion fires on an arbitrary queue — fine, the
// CanopyComplete block hops to JS internally.
- (void)saveData:(NSData *)data complete:(CanopyComplete)complete {
  void (^doSave)(void) = ^{
    __block NSString *localIdentifier = nil;
    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
      PHAssetCreationRequest *req = [PHAssetCreationRequest creationRequestForAsset];
      [req addResourceWithType:PHAssetResourceTypePhoto data:data options:nil];
      localIdentifier = req.placeholderForCreatedAsset.localIdentifier;
    } completionHandler:^(BOOL success, NSError *error) {
      if (!success) {
        CanopyReject(complete, @"rejected",
                     error.localizedDescription ?: @"Photo Library save failed");
        return;
      }
      NSString *uri = localIdentifier.length
          ? [@"ph://" stringByAppendingString:localIdentifier]
          : @"ph://";
      CanopyResolve(complete, @{ @"uri": uri });
    }];
  };

  if (@available(iOS 14.0, *)) {
    PHAuthorizationStatus status =
        [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelAddOnly];
    if (status == PHAuthorizationStatusAuthorized || status == PHAuthorizationStatusLimited) {
      doSave();
    } else if (status == PHAuthorizationStatusNotDetermined) {
      [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly
                                                  handler:^(PHAuthorizationStatus granted) {
        if (granted == PHAuthorizationStatusAuthorized || granted == PHAuthorizationStatusLimited) {
          doSave();
        } else {
          CanopyReject(complete, @"rejected", @"Photo Library add-only access denied");
        }
      }];
    } else {
      CanopyReject(complete, @"rejected", @"Photo Library add-only access denied");
    }
  } else {
    PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatus];
    if (status == PHAuthorizationStatusAuthorized) {
      doSave();
    } else if (status == PHAuthorizationStatusNotDetermined) {
      [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus granted) {
        if (granted == PHAuthorizationStatusAuthorized) { doSave(); }
        else { CanopyReject(complete, @"rejected", @"Photo Library access denied"); }
      }];
    } else {
      CanopyReject(complete, @"rejected", @"Photo Library access denied");
    }
  }
}

@end
