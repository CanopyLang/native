// CanopyShareImageModule.mm — the iOS host module behind canopy/share-image (module
// "ShareImage").
//
// iOS analog of android/.../modules/ShareImageModule.java. Adopts the §4.1 CanopyModule protocol;
// the §4.2 bridge routes __canopy_call(module="ShareImage", …) here. We share a native image
// handle to other apps: GET the UIImage out of the ONE shared C++ registry (§6.3 bridge), bake
// it to a temp JPEG, and present a UIActivityViewController (the iOS analog of Android's
// ACTION_SEND chooser + FileProvider). The activity sheet's completion tells us the real outcome,
// so unlike Android (which can only report "presented") iOS resolves the TRUE
// {outcome:"presented"|"dismissed"} the contract allows — completed/saved => "presented", cancel
// => "dismissed".
//
// CONSUMER discipline (mirrors ShareImageModule.java): GET the image, bake it, recycle nothing in
// JS, and do NOT release the handle (the caller owns its lifetime). Pixels never cross as JSON.
//
// Wire contract (must match share-image.js / ShareImage.can and ShareImageModule.java):
//   image  {image:<handle>}  ->  {outcome:"presented"|"dismissed"}

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include <memory>

#import "CanopyModule.h"
#import "CanopyModuleSupport.h"      // CanopyTopViewController
#import "CanopyBlobRegistryHost.h"   // §6.3 blobGetUIImage
#include "CanopyBlobs.h"

@interface CanopyShareImageModule : NSObject <CanopyModule>
@end

@implementation CanopyShareImageModule {
  dispatch_queue_t _queue;
}

- (instancetype)init {
  if ((self = [super init])) {
    _queue = dispatch_queue_create("com.canopyhost.share", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

- (NSString *)moduleName { return @"ShareImage"; }

- (BOOL)invokeMethod:(NSString *)method
                args:(NSString *)argsJson
              callId:(NSString *)callId
            complete:(CanopyComplete)complete {
  if (![method isEqualToString:@"image"]) { return NO; }

  // Bake on the background queue; present on the main queue.
  dispatch_async(_queue, ^{
    @try {
      NSDictionary *args = CanopyParseArgs(argsJson);
      canopy::BlobHandle h = (canopy::BlobHandle)[args[@"image"] intValue];
      UIImage *img = canopy::blobGetUIImage(h);  // CONSUMER GET — does NOT release
      if (img == nil) {
        CanopyReject(complete, @"rejected", [NSString stringWithFormat:@"unknown handle %d", h]);
        return;
      }
      NSData *jpeg = UIImageJPEGRepresentation(img, 0.95);
      if (jpeg == nil) { CanopyReject(complete, @"rejected", @"image encode failed"); return; }

      NSString *name = [NSString stringWithFormat:@"share-%d-%@.jpg", h, [[NSUUID UUID] UUIDString]];
      NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
      NSError *werr = nil;
      if (![jpeg writeToFile:path options:NSDataWritingAtomic error:&werr]) {
        CanopyReject(complete, @"rejected", werr.localizedDescription ?: @"could not bake share file");
        return;
      }
      NSURL *fileURL = [NSURL fileURLWithPath:path];
      dispatch_async(dispatch_get_main_queue(), ^{ [self presentShare:fileURL complete:complete]; });
    } @catch (NSException *e) {
      CanopyReject(complete, @"rejected", e.reason ?: @"share error");
    }
  });
  return YES;
}

- (void)presentShare:(NSURL *)fileURL complete:(CanopyComplete)complete {
  UIViewController *host = CanopyTopViewController();
  if (host == nil) {
    CanopyReject(complete, @"rejected", @"ShareImage: no foreground view controller");
    return;
  }
  UIActivityViewController *sheet =
      [[UIActivityViewController alloc] initWithActivityItems:@[ fileURL ] applicationActivities:nil];

  // The sheet's completion is the authoritative outcome. completed==YES (an app accepted the
  // share) or completed==NO (the user dismissed) — map to the contract's two outcomes.
  sheet.completionWithItemsHandler =
      ^(UIActivityType activityType, BOOL completed, NSArray *returnedItems, NSError *activityError) {
    NSString *outcome = completed ? @"presented" : @"dismissed";
    CanopyResolve(complete, @{ @"outcome": outcome });
  };

  // iPad: an activity sheet is a popover and MUST have an anchor or it throws.
  UIPopoverPresentationController *pop = sheet.popoverPresentationController;
  if (pop != nil) {
    pop.sourceView = host.view;
    pop.sourceRect = CGRectMake(CGRectGetMidX(host.view.bounds),
                                CGRectGetMidY(host.view.bounds), 1, 1);
    pop.permittedArrowDirections = 0;  // UIPopoverArrowDirectionUnknown -> centered, no arrow
  }
  [host presentViewController:sheet animated:YES completion:nil];
}

@end
