// CanopyDeviceInfoModule.mm — the iOS host module behind Native.DeviceInfo (module "DeviceInfo").
//
// iOS analog of android/.../modules/DeviceInfoModule.java. Adopts the §4.1 CanopyModule protocol;
// the §4.2 CanopyNativeModuleBridge wraps it into a canopy::NativeModule and registers it, so
// __canopy_call(module="DeviceInfo", "info", …) routes to -invokeMethod: here.
//
// Reads static device facts — model, manufacturer, OS version — exactly like the Android module
// reads android.os.Build.*. These are permission-free, I/O-free reads, so (mirroring the Android
// module's "resolves SYNCHRONOUSLY inside invoke" comment) we resolve straight back on the calling
// thread; the CanopyComplete block hops to JS internally, so no manual main-hop is needed.
//
// CROSS-PLATFORM FIELD MAPPING (the wire shape MUST match DeviceInfoModule.java / DeviceInfo.can):
//   info {} -> {model, manufacturer, systemVersion, sdkInt}
//
//   • model         — the hardware identifier (e.g. "iPhone15,2"). iOS's UIDevice.model is just
//                     "iPhone"/"iPad"; the precise machine id comes from uname(2)'s `machine`,
//                     the iOS analog of android.os.Build.MODEL (which IS the precise model there).
//   • manufacturer  — always "Apple" on iOS (the analog of android.os.Build.MANUFACTURER).
//   • systemVersion — UIDevice.systemVersion ("17.4"), the analog of Build.VERSION.RELEASE.
//   • sdkInt        — Android's API level has NO iOS equivalent. To keep the wire shape (and the
//                     Info.sdkInt Int decoder in DeviceInfo.can) identical across platforms, we
//                     report the MAJOR iOS version as the integer "platform level" (e.g. 17). This
//                     keeps the decoder happy and gives a meaningful, monotonic platform number;
//                     the divergence is documented here and in DeviceInfo.can.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include <sys/utsname.h>

#import "CanopyModule.h"
#import "CanopyModuleSupport.h"

@interface CanopyDeviceInfoModule : NSObject <CanopyModule>
@end

@implementation CanopyDeviceInfoModule

- (NSString *)moduleName { return @"DeviceInfo"; }

- (BOOL)invokeMethod:(NSString *)method
                args:(NSString *)argsJson
              callId:(NSString *)callId
            complete:(CanopyComplete)complete {
  if (![method isEqualToString:@"info"]) { return NO; }  // unknown → ModuleNotFound

  @try {
    // The precise machine identifier (e.g. "iPhone15,2") — the iOS analog of Build.MODEL. uname(2)
    // is a permission-free syscall; UIDevice.model alone is only the device CLASS ("iPhone").
    struct utsname systemInfo;
    NSString *model = @"";
    if (uname(&systemInfo) == 0) {
      model = [NSString stringWithCString:systemInfo.machine encoding:NSUTF8StringEncoding] ?: @"";
    }
    if (model.length == 0) { model = UIDevice.currentDevice.model ?: @""; }

    NSString *systemVersion = UIDevice.currentDevice.systemVersion ?: @"";

    // Major version as the cross-platform "sdkInt" (see file header for the documented mapping).
    NSInteger sdkInt = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion;

    CanopyResolve(complete, @{
      @"model":         model,
      @"manufacturer":  @"Apple",
      @"systemVersion": systemVersion,
      @"sdkInt":        @(sdkInt),
    });
  } @catch (NSException *e) {
    CanopyReject(complete, @"rejected", e.reason ?: @"DeviceInfo.info: unexpected error");
  }
  return YES;
}

@end
