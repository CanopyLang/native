// CanopyNotifyModule.mm — the iOS host module behind canopy/notify (module "Notify").
//
// iOS analog of android/.../modules/NotifyModule.java. Adopts the §4.1 CanopyModule protocol;
// the §4.2 bridge routes __canopy_call(module="Notify", …) here. We post a local notification
// through UNUserNotificationCenter (the iOS analog of NotificationManager). Authorization is the
// iOS analog of Android 13's POST_NOTIFICATIONS gate: we request .alert|.sound authorization and
// report posted:false when the OS would withhold the notification, so the Canopy caller gets a
// truthful Bool rather than a silent drop (matching NotifyModule.java:89-93).
//
// A nil trigger means "deliver immediately" — the local-notification equivalent of Android's
// NotificationManager.notify. There is no channel concept on iOS (Android 8+ channels have no
// counterpart), so the channel step is simply absent.
//
// Wire contract (must match notify.js / Notify.can and NotifyModule.java):
//   show {title, body} -> {posted:<bool>}

#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>

#import "CanopyModule.h"
#import "CanopyModuleSupport.h"

@interface CanopyNotifyModule : NSObject <CanopyModule>
@end

@implementation CanopyNotifyModule

- (NSString *)moduleName { return @"Notify"; }

- (BOOL)invokeMethod:(NSString *)method
                args:(NSString *)argsJson
              callId:(NSString *)callId
            complete:(CanopyComplete)complete {
  if (![method isEqualToString:@"show"]) { return NO; }

  NSDictionary *args = CanopyParseArgs(argsJson);
  NSString *title = [args[@"title"] isKindOfClass:[NSString class]] ? args[@"title"] : @"";
  NSString *body  = [args[@"body"]  isKindOfClass:[NSString class]] ? args[@"body"]  : @"";

  UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];

  // Request (or reuse a prior grant of) alert+sound authorization. The handler fires on an
  // arbitrary queue; the CanopyComplete block hops to JS internally, so no manual main-hop.
  UNAuthorizationOptions opts = UNAuthorizationOptionAlert | UNAuthorizationOptionSound;
  [center requestAuthorizationWithOptions:opts
                        completionHandler:^(BOOL granted, NSError *error) {
    if (!granted) {
      // OS withheld posting — report the truth, not an error (mirrors NotifyModule.java).
      [self resolvePosted:NO complete:complete];
      return;
    }
    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = title;
    content.body  = body;
    content.sound = [UNNotificationSound defaultSound];

    NSString *requestId = [[NSUUID UUID] UUIDString];  // distinct id => never overwrites prior
    UNNotificationRequest *request =
        [UNNotificationRequest requestWithIdentifier:requestId
                                             content:content
                                             trigger:nil];  // nil => deliver immediately
    [center addNotificationRequest:request withCompletionHandler:^(NSError *addError) {
      [self resolvePosted:(addError == nil) complete:complete];
    }];
  }];
  return YES;
}

- (void)resolvePosted:(BOOL)posted complete:(CanopyComplete)complete {
  CanopyResolve(complete, @{ @"posted": @(posted) });
}

@end
