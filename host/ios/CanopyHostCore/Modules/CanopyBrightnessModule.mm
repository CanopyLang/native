// CanopyBrightnessModule.mm — the iOS host module behind Native.Brightness (module "Brightness").
//
// iOS analog of android/.../modules/BrightnessModule.java. Adopts the §4.1 CanopyModule protocol;
// the §4.2 CanopyNativeModuleBridge wraps it into a canopy::NativeModule and registers it, so
// __canopy_call(module="Brightness", "get", …) routes to -invokeMethod: here.
//
// Wire contract (must match Brightness.can and BrightnessModule.java):
//   get {} -> {"level":<float 0.0..1.0>}
//
// Android reads SCREEN_BRIGHTNESS (0..255) and normalizes to 0.0..1.0 with NO permission. The iOS
// analog is UIScreen.main.brightness, ALREADY 0.0..1.0 and permission-free — a strictly cleaner
// mapping (no /255). Like the Android module reads the system value with no permission and no I/O,
// this is a fast read; but UIScreen is a MAIN-THREAD UIKit API, so we hop to the main queue and
// resolve there. (Setting brightness, like Android's WRITE_SETTINGS gate, is out of scope — get only.)

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "CanopyModule.h"
#import "CanopyModuleSupport.h"

@interface CanopyBrightnessModule : NSObject <CanopyModule>
@end

@implementation CanopyBrightnessModule

- (NSString *)moduleName { return @"Brightness"; }

- (BOOL)invokeMethod:(NSString *)method
                args:(NSString *)argsJson
              callId:(NSString *)callId
            complete:(CanopyComplete)complete {
  if (![method isEqualToString:@"get"]) { return NO; }  // unknown → ModuleNotFound

  // UIScreen is a main-thread API; hop there (the block re-marshals to JS internally).
  dispatch_async(dispatch_get_main_queue(), ^{
    @try {
      // Resolve against the screen the foreground app actually presents on, falling back to the
      // main screen. UIScreen.brightness is already 0.0..1.0 (no /255 needed, unlike Android).
      UIScreen *screen = CanopyTopViewController().view.window.screen ?: UIScreen.mainScreen;
      double level = (double)screen.brightness;
      if (level < 0.0) { level = 0.0; }
      if (level > 1.0) { level = 1.0; }
      CanopyResolve(complete, @{ @"level": @(level) });
    } @catch (NSException *e) {
      CanopyReject(complete, @"rejected", e.reason ?: @"Brightness.get: unexpected error");
    }
  });
  return YES;
}

@end
