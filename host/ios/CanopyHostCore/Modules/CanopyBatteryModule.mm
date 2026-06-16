// CanopyBatteryModule.mm — the iOS host module behind Native.Battery (module "Battery").
//
// iOS analog of android/.../modules/BatteryModule.java. Adopts the §4.1 CanopyModule protocol;
// the §4.2 CanopyNativeModuleBridge wraps it into a canopy::NativeModule and registers it, so
// __canopy_call(module="Battery", "status", …) routes to -invokeMethod: here.
//
// Wire contract (must match Battery.can and BatteryModule.java):
//   status {} -> {"level":<float 0.0..1.0>,"charging":<bool>}
//
// Android reads the sticky ACTION_BATTERY_CHANGED broadcast synchronously. The iOS analog is
// UIDevice's batteryLevel / batteryState, which require batteryMonitoringEnabled=YES first. Those
// are MAIN-THREAD UIKit reads, so — like the Android module needs no thread hop because its read is
// fast — we hop to the main queue (UIDevice is a main-thread API) and resolve from there; the
// CanopyComplete block hops to JS internally, so no extra main-hop is needed after resolving.
//
// batteryLevel is already 0.0..1.0 (matching Android's level/scale normalization), or -1.0 when
// monitoring is unavailable (e.g. the Simulator), which we report as level 0.0 + charging false —
// the truthful analog of Android's "no battery status available" path resolving a zeroed status
// rather than rejecting, so a UI never special-cases the Simulator.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "CanopyModule.h"
#import "CanopyModuleSupport.h"

@interface CanopyBatteryModule : NSObject <CanopyModule>
@end

@implementation CanopyBatteryModule

- (NSString *)moduleName { return @"Battery"; }

- (BOOL)invokeMethod:(NSString *)method
                args:(NSString *)argsJson
              callId:(NSString *)callId
            complete:(CanopyComplete)complete {
  if (![method isEqualToString:@"status"]) { return NO; }  // unknown → ModuleNotFound

  // UIDevice battery APIs are main-thread; hop there (the CanopyComplete block re-marshals to JS
  // internally, so resolving from the main queue is correct with no further hop).
  dispatch_async(dispatch_get_main_queue(), ^{
    @try {
      UIDevice *device = UIDevice.currentDevice;

      // Monitoring must be ON for batteryLevel/batteryState to read anything but the "unknown"
      // sentinel. Idempotent to enable; we leave it on (cheap, and a UI polling status wants it).
      if (!device.isBatteryMonitoringEnabled) {
        device.batteryMonitoringEnabled = YES;
      }

      float raw = device.batteryLevel;              // 0.0..1.0, or -1.0 when unavailable
      double level = (raw < 0.0f) ? 0.0 : (double)raw;
      if (level > 1.0) { level = 1.0; }

      UIDeviceBatteryState state = device.batteryState;
      BOOL charging = (state == UIDeviceBatteryStateCharging ||
                       state == UIDeviceBatteryStateFull);

      CanopyResolve(complete, @{
        @"level":    @(level),
        @"charging": @(charging),
      });
    } @catch (NSException *e) {
      CanopyReject(complete, @"rejected", e.reason ?: @"Battery.status: unexpected error");
    }
  });
  return YES;
}

@end
