// CanopyAlbumModule.mm — the iOS host module behind canopy/album (module "Album").
//
// iOS analog of android/.../modules/AlbumModule.java. Adopts the §4.1 CanopyModule protocol;
// the §4.2 bridge routes __canopy_call(module="Album", …) here. We save a native image handle
// into the device photo gallery: GET the UIImage out of the ONE shared C++ registry (§6.3
// bridge), encode it (JPEG/PNG), and add it to the user's Photo Library via PHPhotoLibrary
// performChanges with PHAssetCreationRequest. We resolve {uri:"ph://<localIdentifier>"} — the
// iOS analog of Android's content:// MediaStore uri.
//
// NAMED ALBUM (L-I2 parity with AlbumModule.java): the wire contract carries an `album` name
// (Album.can:60-69 sends {album,image,format}; AlbumModule.java writes Pictures/<album> via
// MediaStore.RELATIVE_PATH). The iOS analog of a gallery sub-folder is a named user album — a
// PHAssetCollection of type .album. So when `album` is a non-empty name we create the asset AND
// file it into that named album (creating the album the first time) inside ONE performChanges
// block, the standard add-then-add-to-collection pattern. Lumen saves into the "Lumen" album, so
// without this the iOS save would silently differ from Android (camera-roll only). See the
// add-only caveat below for why this is best-effort.
//
// CONSUMER discipline (mirrors AlbumModule.java): GET the image from the handle, save it, and do
// NOT release the handle (the caller owns its lifetime via Image.release). Pixels never cross as
// JSON — only the int handle does.
//
// Permission: add-only Photo Library access (PHAccessLevelAddOnly) requires
// NSPhotoLibraryAddUsageDescription in Info.plist (Author A) but NOT full-library read. We
// request authorization lazily; a denied/restricted status rejects with {code:"rejected"}.
//   ADD-ONLY CAVEAT for named albums: enumerating an EXISTING PHAssetCollection
//   (fetchAssetCollections) needs READ access, which PHAccessLevelAddOnly does NOT grant. So with
//   add-only we cannot reliably find a pre-existing album to append to; we create the album on the
//   placeholder path (the create succeeds add-only) and, when an album of that name can be located
//   (full access granted), reuse it. Either way the asset always lands in the library, so a denied
//   read never costs the save — it just may create a duplicate-named album, exactly the graceful
//   degradation the contract wants. With full access (PHAuthorizationStatusAuthorized) the existing
//   album is reused, matching Android's stable Pictures/<album> folder.
//
// Wire contract (must match album.js / Album.can and AlbumModule.java):
//   save  {album:"Lumen", image:<handle>, format:"jpeg"|"png"}  ->  {uri:"ph://<localIdentifier>"}

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
      // The gallery sub-album name (Lumen sends "Lumen"). Sanitized to the same conservative
      // character set AlbumModule.java uses for its Pictures/<album> folder, so an album name is a
      // portable identifier across both hosts. An empty/absent name => save to the camera roll only.
      NSString *album = [self sanitizedAlbumName:args[@"album"]];

      UIImage *img = canopy::blobGetUIImage(h);  // CONSUMER GET — does NOT release
      if (img == nil) {
        CanopyReject(complete, @"rejected", [NSString stringWithFormat:@"unknown handle %d", h]);
        return;
      }
      NSData *data = png ? UIImagePNGRepresentation(img)
                         : UIImageJPEGRepresentation(img, 0.95);
      if (data == nil) { CanopyReject(complete, @"rejected", @"image encode failed"); return; }

      [self saveData:data album:album complete:complete];
    } @catch (NSException *e) {
      CanopyReject(complete, @"rejected", e.reason ?: @"album save error");
    }
  });
  return YES;
}

// Mirror AlbumModule.java's album sanitization: keep only [A-Za-z0-9 _-], so the album name is a
// portable, injection-free identifier on both hosts. Returns nil for an absent/empty/whitespace
// name (=> camera-roll-only save, no named collection).
- (NSString *)sanitizedAlbumName:(id)raw {
  if (![raw isKindOfClass:[NSString class]]) { return nil; }
  NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
      @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 _-"];
  NSCharacterSet *disallowed = [allowed invertedSet];
  NSString *cleaned = [[(NSString *)raw componentsSeparatedByCharactersInSet:disallowed]
      componentsJoinedByString:@""];
  cleaned = [cleaned stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  return cleaned.length ? cleaned : nil;
}

// Request add-only authorization, then add the image data as a new asset (filing it into the
// named `album` collection when one is given) and report its localIdentifier. PHPhotoLibrary's
// completion fires on an arbitrary queue — fine, the CanopyComplete block hops to JS internally.
- (void)saveData:(NSData *)data album:(NSString *)album complete:(CanopyComplete)complete {
  void (^doSave)(void) = ^{
    // Resolve (or, with full access, create) the album collection BEFORE the change block when we
    // can read it; create it INSIDE the block otherwise. Both paths add the new asset to the album
    // in the same performChanges so the asset and its album membership commit atomically.
    PHAssetCollection *existing = album ? [self findAlbumNamed:album] : nil;

    __block NSString *localIdentifier = nil;
    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
      PHAssetCreationRequest *req = [PHAssetCreationRequest creationRequestForAsset];
      [req addResourceWithType:PHAssetResourceTypePhoto data:data options:nil];
      PHObjectPlaceholder *assetPlaceholder = req.placeholderForCreatedAsset;
      localIdentifier = assetPlaceholder.localIdentifier;

      if (album.length) {
        // File the new asset into the named album. If we found an existing collection (full access),
        // append to it; otherwise create the album in the same transaction (add-only can create) and
        // add the placeholder asset. Either way the asset lands in the library even if this fails.
        PHAssetCollectionChangeRequest *albumReq;
        if (existing != nil) {
          albumReq = [PHAssetCollectionChangeRequest changeRequestForAssetCollection:existing];
        } else {
          albumReq = [PHAssetCollectionChangeRequest
                         creationRequestForAssetCollectionWithTitle:album];
        }
        if (albumReq != nil && assetPlaceholder != nil) {
          [albumReq addAssets:@[ assetPlaceholder ]];
        }
      }
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

// Find an existing user album titled `name`, or nil. fetchAssetCollections enumerates the library,
// which requires READ (full) access — under add-only it returns nothing, so we only consult it when
// full access is granted and let the change block create a fresh album otherwise (the add-only
// caveat in the file header). Returns the FIRST match (album titles are not unique on iOS, exactly
// as Pictures/<album> is one folder on Android — we treat the first as canonical).
- (PHAssetCollection *)findAlbumNamed:(NSString *)name {
  if (name.length == 0) { return nil; }
  if (@available(iOS 14.0, *)) {
    // Only a fully-authorized library can be enumerated; add-only/limited cannot fetch collections.
    if ([PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelReadWrite]
            != PHAuthorizationStatusAuthorized) {
      return nil;
    }
  } else {
    if ([PHPhotoLibrary authorizationStatus] != PHAuthorizationStatusAuthorized) {
      return nil;
    }
  }
  PHFetchOptions *opts = [[PHFetchOptions alloc] init];
  opts.predicate = [NSPredicate predicateWithFormat:@"title = %@", name];
  opts.fetchLimit = 1;
  PHFetchResult<PHAssetCollection *> *result =
      [PHAssetCollection fetchAssetCollectionsWithType:PHAssetCollectionTypeAlbum
                                               subtype:PHAssetCollectionSubtypeAlbumRegular
                                               options:opts];
  return result.firstObject;
}

@end
