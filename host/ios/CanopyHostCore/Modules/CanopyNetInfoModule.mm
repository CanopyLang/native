// CanopyNetInfoModule.mm — the iOS host module behind Native.NetInfo (module "NetInfo").
//
// iOS analog of android/.../modules/NetInfoModule.java. Adopts the §4.1 CanopyModule protocol;
// the §4.2 CanopyNativeModuleBridge wraps it into a canopy::NativeModule and registers it, so
// __canopy_call(module="NetInfo", "status", …) routes to -invokeMethod: here.
//
// Wire contract (must match NetInfo.can and NetInfoModule.java):
//   status {} -> {"connected":<bool>,"kind":"<string>"}   kind ∈ wifi|cellular|ethernet|none
//
// Android queries ConnectivityManager + NetworkCapabilities synchronously. The iOS analog is the
// Network framework's NWPathMonitor, whose `currentPath` is delivered ASYNCHRONOUSLY via an update
// handler — so unlike the synchronous Android read, we start a one-shot monitor, read the FIRST
// path it reports, map it to the same {connected, kind} shape, then cancel the monitor and resolve.
// (NWPathMonitor needs no permission, unlike Android's ACCESS_NETWORK_STATE.) The CanopyComplete
// block hops to JS internally, so resolving from the monitor's queue is correct with no main-hop.
//
// transport → kind mapping mirrors NetInfoModule.java exactly:
//   .wifi    -> "wifi"     .cellular -> "cellular"     .wiredEthernet -> "ethernet"     else -> "none"
// connected is path.status == .satisfied (the iOS analog of NET_CAPABILITY_INTERNET).

#import <Foundation/Foundation.h>
#import <Network/Network.h>

#import "CanopyModule.h"
#import "CanopyModuleSupport.h"

@interface CanopyNetInfoModule : NSObject <CanopyModule>
@end

@implementation CanopyNetInfoModule

- (NSString *)moduleName { return @"NetInfo"; }

- (BOOL)invokeMethod:(NSString *)method
                args:(NSString *)argsJson
              callId:(NSString *)callId
            complete:(CanopyComplete)complete {
  if (![method isEqualToString:@"status"]) { return NO; }  // unknown → ModuleNotFound

  @try {
    // A private serial queue for THIS one-shot probe (NWPathMonitor must be started on a queue).
    dispatch_queue_t queue =
        dispatch_queue_create("com.canopyhost.netinfo", DISPATCH_QUEUE_SERIAL);
    nw_path_monitor_t monitor = nw_path_monitor_create();

    // Guard so the FIRST path snapshot resolves exactly once even though the handler may re-fire.
    __block BOOL resolved = NO;

    nw_path_monitor_set_queue(monitor, queue);
    nw_path_monitor_set_update_handler(monitor, ^(nw_path_t _Nonnull path) {
      if (resolved) { return; }
      resolved = YES;

      nw_path_status_t status = nw_path_get_status(path);
      BOOL connected = (status == nw_path_status_satisfied ||
                        status == nw_path_status_satisfiable);

      NSString *kind = @"none";
      if (connected) {
        if (nw_path_uses_interface_type(path, nw_interface_type_wifi)) {
          kind = @"wifi";
        } else if (nw_path_uses_interface_type(path, nw_interface_type_cellular)) {
          kind = @"cellular";
        } else if (nw_path_uses_interface_type(path, nw_interface_type_wired)) {
          kind = @"ethernet";
        }
      }

      // Tear the monitor down before resolving (one-shot snapshot — no live subscription).
      nw_path_monitor_cancel(monitor);
      CanopyResolve(complete, @{
        @"connected": @(connected),
        @"kind":      kind,
      });
    });
    nw_path_monitor_start(monitor);
  } @catch (NSException *e) {
    CanopyReject(complete, @"rejected", e.reason ?: @"NetInfo.status: unexpected error");
  }
  return YES;
}

@end
