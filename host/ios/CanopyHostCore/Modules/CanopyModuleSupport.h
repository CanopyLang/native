// CanopyModuleSupport.h — small shared helpers for the iOS capability modules.
//
// Every capability module (CanopyImageModule, CanopyPhotosModule, …) speaks the same JSON wire
// shape and the same {complete(errJson, resultJson)} resolve/reject convention as the Android
// modules. Rather than re-derive arg-parsing, JSON-result-building, error-payload-building and
// the ImageIO decode/resize plumbing in every file, they share these free functions. This file
// is NOT a capability and registers nothing; it is the iOS analog of the resolve/reject helpers
// duplicated at the bottom of each Android *Module.java.
//
// The CanopyComplete block (declared in CanopyModule.h, §6.4) is the resolve sink. errJson nil =
// success; a nil resultJson with non-nil errJson = error. These helpers wrap it so a module body
// reads like the Java one: CanopyResolve(complete, @{...}) / CanopyReject(complete, code, msg).

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "CanopyModule.h"   // CanopyComplete

#ifdef __cplusplus
extern "C" {
#endif

// Parse an argsJson string into an NSDictionary. Treats nil / "" / "null" (the no-arg marshal,
// matching BillingModule.java:78) as an empty object. Never returns nil — callers index safely.
NSDictionary *CanopyParseArgs(NSString *_Nullable argsJson);

// Resolve success with a JSON object built from `result` (an NSDictionary serialized to JSON).
void CanopyResolve(CanopyComplete _Nonnull complete, NSDictionary *_Nonnull result);

// Resolve success with the literal JSON `null` (the {} -> null methods: set/remove/release).
void CanopyResolveNull(CanopyComplete _Nonnull complete);

// Reject with {"code":code,"message":message}. Maps to Native.Module.Rejected on the Canopy side
// ("cancelled" / "rejected" / "item_unavailable" / "already_owned" / "module_not_found").
void CanopyReject(CanopyComplete _Nonnull complete, NSString *_Nonnull code, NSString *_Nullable message);

// Read the bytes behind a Canopy image uri. Handles file://… , the bare /path form, asset:NAME
// (a bundled app resource, mirroring ImageModule.java's "asset" scheme), and content-ish http(s)
// uris (synchronous fetch — callers already run on a background queue). Returns nil on failure.
NSData *_Nullable CanopyReadURI(NSString *_Nonnull uriStr);

// Decode `data` to a UIImage downsampled so width*height never exceeds `maxMegapixels` — the
// ImageIO equivalent of Android's two-pass inSampleSize decode (never lands a 12MP source full
// in memory). Returns nil if the data is not a decodable image.
UIImage *_Nullable CanopyDecodeDownsampled(NSData *_Nonnull data, double maxMegapixels);

// Aspect-exact resize to (w x h) device pixels via UIGraphicsImageRenderer. Returns a 1x-scale
// UIImage whose pixel size is exactly (w, h).
UIImage *_Nullable CanopyResizeImage(UIImage *_Nonnull src, int w, int h);

// Re-budget an already-decoded UIImage so width*height <= maxMegapixels (a picked HEIC can be
// 12MP). Returns the input untouched if already within budget. Used by the picker path.
UIImage *_Nonnull CanopyDownsampleUIImage(UIImage *_Nonnull img, double maxMegapixels);

// The top-most presented view controller of the foreground active scene — the right host for a
// modal picker / share sheet / alert. Mirrors the Android MainActivity.current() foreground
// Activity. Returns nil if no foreground scene exists. Call on the main queue.
UIViewController *_Nullable CanopyTopViewController(void);

#ifdef __cplusplus
}  // extern "C"
#endif
