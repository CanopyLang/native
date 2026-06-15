// CanopyPlatformModule.mm — common platform APIs behind Native.Platform (module "Platform").
// The iOS analog of android/.../modules/PlatformModule.java.
//
// Linking (openURL) + Clipboard (set/get). These touch UIApplication / UIPasteboard, which are
// main-thread APIs, so — like the Android module — the work hops to the main queue and resolves
// back through the CanopyComplete sink (which re-enters JS via the registry postToJs). A pure
// one-shot capability, so it adopts <CanopyModule> directly (no streaming base needed).
//
// Wire contract (must match Native/Platform.can and PlatformModule.java):
//   openURL      {url}    -> null
//   setClipboard {text}   -> null
//   getClipboard {}       -> {text:<string>}

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "CanopyModule.h"
#import "CanopyModuleSupport.h"

@interface CanopyPlatformModule : NSObject <CanopyModule>
@end

@implementation CanopyPlatformModule

- (NSString *)moduleName { return @"Platform"; }

- (BOOL)invokeMethod:(NSString *)method
                args:(NSString *)argsJson
              callId:(NSString *)callId
            complete:(CanopyComplete)complete {
  BOOL known = [method isEqualToString:@"openURL"] ||
               [method isEqualToString:@"setClipboard"] ||
               [method isEqualToString:@"getClipboard"];
  if (!known) { return NO; }  // unknown method → dispatcher reports ModuleNotFound

  NSDictionary *args = CanopyParseArgs(argsJson);
  dispatch_async(dispatch_get_main_queue(), ^{
    @try {
      if ([method isEqualToString:@"openURL"]) {
        NSString *urlStr = [args[@"url"] isKindOfClass:[NSString class]] ? args[@"url"] : nil;
        NSURL *url = urlStr.length > 0 ? [NSURL URLWithString:urlStr] : nil;
        if (url == nil) {
          CanopyReject(complete, @"rejected", @"Platform.openURL: invalid or missing url");
          return;
        }
        [UIApplication.sharedApplication openURL:url
                                         options:@{}
                               completionHandler:^(BOOL success) {
                                 if (success) {
                                   CanopyResolveNull(complete);
                                 } else {
                                   CanopyReject(complete, @"rejected",
                                                @"Platform.openURL: the system could not open the url");
                                 }
                               }];
      } else if ([method isEqualToString:@"setClipboard"]) {
        NSString *text = [args[@"text"] isKindOfClass:[NSString class]] ? args[@"text"] : @"";
        UIPasteboard.generalPasteboard.string = text;
        CanopyResolveNull(complete);
      } else {  // getClipboard
        NSString *text = UIPasteboard.generalPasteboard.string ?: @"";
        CanopyResolve(complete, @{ @"text": text });
      }
    } @catch (NSException *e) {
      CanopyReject(complete, @"rejected", e.reason ?: @"Platform: unexpected error");
    }
  });
  return YES;
}

@end
