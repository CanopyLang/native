// CanopyHapticsModule.mm — the iOS host module behind Native.Haptics (module "Haptics").
//
// iOS analog of android/.../modules/HapticsModule.java. Adopts the §4.1 CanopyModule protocol;
// the §4.2 CanopyNativeModuleBridge wraps it into a canopy::NativeModule and registers it, so
// __canopy_call(module="Haptics", method, …) routes to -invokeMethod: here.
//
// Wire contract (must match Haptics.can and HapticsModule.java):
//   impact       {style}  -> null   (style "light"|"medium"|"heavy")
//   notification {style}  -> null   (style "success"|"warning"|"error")
//   selection    {}       -> null
//
// Where Android synthesizes durations/patterns on the raw Vibrator, iOS exposes FIRST-CLASS haptic
// generators that map one-to-one onto the contract — a strictly higher-fidelity feedback than the
// Android timing approximation, with NO permission required (no VIBRATE entitlement needed):
//   impact       -> UIImpactFeedbackGenerator       (.light / .medium / .heavy)
//   notification -> UINotificationFeedbackGenerator  (.success / .warning / .error)
//   selection    -> UISelectionFeedbackGenerator     (selectionChanged)
//
// UIFeedbackGenerator is a MAIN-THREAD UIKit API, so we hop to the main queue, fire the haptic, and
// resolve null; the CanopyComplete block hops to JS internally, so no further main-hop after resolve.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "CanopyModule.h"
#import "CanopyModuleSupport.h"

@interface CanopyHapticsModule : NSObject <CanopyModule>
@end

@implementation CanopyHapticsModule

- (NSString *)moduleName { return @"Haptics"; }

- (BOOL)invokeMethod:(NSString *)method
                args:(NSString *)argsJson
              callId:(NSString *)callId
            complete:(CanopyComplete)complete {
  BOOL known = [method isEqualToString:@"impact"] ||
               [method isEqualToString:@"notification"] ||
               [method isEqualToString:@"selection"];
  if (!known) { return NO; }  // unknown → ModuleNotFound

  NSDictionary *args = CanopyParseArgs(argsJson);

  // UIFeedbackGenerator must be constructed AND triggered on the main thread.
  dispatch_async(dispatch_get_main_queue(), ^{
    @try {
      if ([method isEqualToString:@"impact"]) {
        NSString *style = [args[@"style"] isKindOfClass:[NSString class]] ? args[@"style"] : @"medium";
        UIImpactFeedbackStyle fbStyle = UIImpactFeedbackStyleMedium;
        if ([style isEqualToString:@"light"]) {
          fbStyle = UIImpactFeedbackStyleLight;
        } else if ([style isEqualToString:@"heavy"]) {
          fbStyle = UIImpactFeedbackStyleHeavy;
        }
        UIImpactFeedbackGenerator *gen =
            [[UIImpactFeedbackGenerator alloc] initWithStyle:fbStyle];
        [gen prepare];
        [gen impactOccurred];
      } else if ([method isEqualToString:@"notification"]) {
        NSString *style = [args[@"style"] isKindOfClass:[NSString class]] ? args[@"style"] : @"success";
        UINotificationFeedbackType fbType = UINotificationFeedbackTypeSuccess;
        if ([style isEqualToString:@"warning"]) {
          fbType = UINotificationFeedbackTypeWarning;
        } else if ([style isEqualToString:@"error"]) {
          fbType = UINotificationFeedbackTypeError;
        }
        UINotificationFeedbackGenerator *gen = [[UINotificationFeedbackGenerator alloc] init];
        [gen prepare];
        [gen notificationOccurred:fbType];
      } else {  // selection
        UISelectionFeedbackGenerator *gen = [[UISelectionFeedbackGenerator alloc] init];
        [gen prepare];
        [gen selectionChanged];
      }
      CanopyResolveNull(complete);
    } @catch (NSException *e) {
      CanopyReject(complete, @"rejected", e.reason ?: @"Haptics: unexpected error");
    }
  });
  return YES;
}

@end
