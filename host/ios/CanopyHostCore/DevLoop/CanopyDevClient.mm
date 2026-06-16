// CanopyDevClient.mm — DEV-12: the iOS dev-loop WS client (impl).
//
// A faithful port of host/android/.../src/debug/CanopyDevClient.java: the SAME pure decision layer
// (classify / parseFrame / isCleartextAllowed / deriveWsUrl / backoffMs — byte-for-byte the same
// ranges and parsing), wrapped around an NSURLSessionWebSocketTask + auto-reconnect I/O shell (the
// iOS analogue of okhttp's WebSocket). The reload effect reaches the live CanopyHostViewController
// via keyWindow.rootViewController (the SAME way the AppShell capability reaches it), so this debug
// tool needs no extra seam in the production boot path.
//
// The whole client is compiled ONLY under DEBUG — a release build never sees the socket, the
// cleartext path, or the NSURLSession (it is gone from the shipped binary, like the Android client
// living in src/debug). The #if DEBUG wraps the implementation; the +start no-op stub below keeps
// the symbol present (returning nil) for a release link that still references it.

#import "CanopyDevClient.h"

#import <UIKit/UIKit.h>
#import <os/log.h>

#import "../Boot/CanopyHostViewController.h"

static os_log_t CanopyDevLog(void) {
  static os_log_t log;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ log = os_log_create("com.canopyhost.canopy", "CanopyDev"); });
  return log;
}

// Default endpoint: unlike the Android emulator (which aliases the host loopback as 10.0.2.2), the
// iOS Simulator shares the Mac's loopback, so 127.0.0.1 reaches the dev server directly. A LAN device
// bakes its own host IP into CANOPY_DEV_HOST.
static NSString *const kDefaultHost = @"127.0.0.1";
static const int kDefaultPort = 8099;

// Reconnect backoff: a small floor, doubling to a ceiling (mirror of the Java client).
static const long kBackoffMinMs = 500L;
static const long kBackoffMaxMs = 10000L;

// =================================================================================================
// CanopyDevFrame
// =================================================================================================

@interface CanopyDevFrame ()
- (instancetype)initWithAction:(CanopyDevAction)action
                       buildId:(nullable NSString *)buildId
                        bundle:(nullable NSString *)bundle
                        report:(nullable NSString *)report;
@end

@implementation CanopyDevFrame
- (instancetype)initWithAction:(CanopyDevAction)action
                       buildId:(NSString *)buildId
                        bundle:(NSString *)bundle
                        report:(NSString *)report {
  if ((self = [super init])) {
    _action = action;
    _buildId = buildId;
    _bundle = bundle;
    _report = report;
  }
  return self;
}
@end

// =================================================================================================
// CanopyDevClient
// =================================================================================================

@interface CanopyDevClient () <NSURLSessionWebSocketDelegate>
@end

@implementation CanopyDevClient {
  NSString *_url;
  NSURLSession *_session;
  NSURLSessionWebSocketTask *_socket;
  BOOL _stopped;
  NSInteger _attempt;
  NSString *_lastBuildId;
}

// ---- PURE decision layer (mirror of the Java statics) -------------------------------------------

+ (CanopyDevAction)classify:(NSString *)type {
  if (type == nil) return CanopyDevActionIgnore;
  if ([type isEqualToString:@"hello"])    return CanopyDevActionHello;
  if ([type isEqualToString:@"building"]) return CanopyDevActionBuilding;
  if ([type isEqualToString:@"reload"])   return CanopyDevActionReload;
  if ([type isEqualToString:@"nochange"]) return CanopyDevActionNoChange;
  if ([type isEqualToString:@"error"])    return CanopyDevActionError;
  return CanopyDevActionIgnore;
}

+ (CanopyDevFrame *)parseFrame:(NSString *)text {
  CanopyDevFrame *(^ignore)(void) = ^{
    return [[CanopyDevFrame alloc] initWithAction:CanopyDevActionIgnore buildId:nil bundle:nil report:nil];
  };
  if (text == nil) return ignore();
  NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
  if (data == nil) return ignore();
  NSError *err = nil;
  id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
  if (err != nil || ![obj isKindOfClass:[NSDictionary class]]) return ignore();
  NSDictionary *o = (NSDictionary *)obj;

  NSString *type = [o[@"type"] isKindOfClass:[NSString class]] ? o[@"type"] : nil;
  CanopyDevAction a = [self classify:type];

  // A JSON null buildId decodes to NSNull → a nil buildId, not the string "null" (mirror Java).
  NSString *buildId = [o[@"buildId"] isKindOfClass:[NSString class]] ? o[@"buildId"] : nil;

  if (a == CanopyDevActionReload) {
    NSString *bundle = [o[@"bundle"] isKindOfClass:[NSString class]] ? o[@"bundle"] : nil;
    // A reload with no bundle bytes is meaningless — treat it as ignore rather than re-eval "".
    if (bundle.length == 0) {
      return [[CanopyDevFrame alloc] initWithAction:CanopyDevActionIgnore buildId:buildId bundle:nil report:nil];
    }
    return [[CanopyDevFrame alloc] initWithAction:CanopyDevActionReload buildId:buildId bundle:bundle report:nil];
  }
  if (a == CanopyDevActionError) {
    NSString *report = [o[@"report"] isKindOfClass:[NSString class]] ? o[@"report"] : @"";
    return [[CanopyDevFrame alloc] initWithAction:CanopyDevActionError buildId:nil bundle:nil report:report];
  }
  return [[CanopyDevFrame alloc] initWithAction:a buildId:buildId bundle:nil report:nil];
}

+ (BOOL)isCleartextAllowed:(NSString *)host {
  if (host == nil) return NO;
  NSString *h = [[host stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] lowercaseString];
  if (h.length == 0) return NO;
  // Strip an IPv6 bracket form ([::1]) if present.
  if ([h hasPrefix:@"["] && [h hasSuffix:@"]"]) h = [h substringWithRange:NSMakeRange(1, h.length - 2)];
  if ([h isEqualToString:@"localhost"]) return YES;
  if ([h isEqualToString:@"::1"]) return YES;                 // IPv6 loopback
  if ([h isEqualToString:@"10.0.2.2"] || [h isEqualToString:@"10.0.3.2"]) return YES; // emulator alias (cross-tool)
  int q[4];
  if (![self parseIpv4:h into:q]) return NO;                  // a non-IPv4, non-allowlisted name → refuse
  if (q[0] == 127) return YES;                                // 127.0.0.0/8 loopback
  if (q[0] == 10) return YES;                                 // 10.0.0.0/8 private
  if (q[0] == 192 && q[1] == 168) return YES;                 // 192.168.0.0/16 private
  if (q[0] == 172 && q[1] >= 16 && q[1] <= 31) return YES;    // 172.16.0.0/12 private
  if (q[0] == 169 && q[1] == 254) return YES;                 // 169.254.0.0/16 link-local
  return NO;
}

// Parse a dotted-quad IPv4 string into its four octets; returns NO if it is not a valid IPv4.
+ (BOOL)parseIpv4:(NSString *)h into:(int *)q {
  NSArray<NSString *> *parts = [h componentsSeparatedByString:@"."];
  if (parts.count != 4) return NO;
  for (int i = 0; i < 4; i++) {
    NSString *p = parts[i];
    if (p.length == 0 || p.length > 3) return NO;
    int v = 0;
    for (NSUInteger j = 0; j < p.length; j++) {
      unichar c = [p characterAtIndex:j];
      if (c < '0' || c > '9') return NO;
      v = v * 10 + (c - '0');
    }
    if (v > 255) return NO;
    q[i] = v;
  }
  return YES;
}

+ (long)backoffMs:(NSInteger)attempt {
  if (attempt <= 0) return kBackoffMinMs;
  long ms = kBackoffMinMs;
  for (NSInteger i = 0; i < attempt && ms < kBackoffMaxMs; i++) ms <<= 1;
  return MIN(ms, kBackoffMaxMs);
}

+ (NSString *)deriveWsUrl:(NSString *)devHost {
  NSString *trimmed = [devHost stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  NSString *spec = (devHost == nil || trimmed.length == 0)
      ? [NSString stringWithFormat:@"%@:%d", kDefaultHost, kDefaultPort]
      : trimmed;

  // Normalise an http(s)/ws(s) scheme down to host[:port].
  NSString *noScheme = spec;
  NSRange schemeRange = [noScheme rangeOfString:@"://"];
  if (schemeRange.location != NSNotFound) {
    noScheme = [noScheme substringFromIndex:schemeRange.location + schemeRange.length];
  }
  // Drop any trailing path.
  NSRange slash = [noScheme rangeOfString:@"/"];
  if (slash.location != NSNotFound) noScheme = [noScheme substringToIndex:slash.location];

  NSString *host;
  int port = kDefaultPort;
  if ([noScheme hasPrefix:@"["]) {                            // bracketed IPv6: [::1]:8099
    NSRange close = [noScheme rangeOfString:@"]"];
    if (close.location == NSNotFound) return nil;
    host = [noScheme substringWithRange:NSMakeRange(1, close.location - 1)];
    NSRange afterClose = NSMakeRange(close.location, noScheme.length - close.location);
    NSRange colon = [noScheme rangeOfString:@":" options:0 range:afterClose];
    if (colon.location != NSNotFound) {
      NSString *portStr = [noScheme substringFromIndex:colon.location + 1];
      if (![self parsePort:portStr into:&port]) return nil;
    }
  } else {
    NSRange lastColon = [noScheme rangeOfString:@":" options:NSBackwardsSearch];
    NSRange firstColon = [noScheme rangeOfString:@":"];
    if (lastColon.location != NSNotFound && firstColon.location == lastColon.location) {
      // exactly one colon → host:port
      host = [noScheme substringToIndex:lastColon.location];
      NSString *portStr = [noScheme substringFromIndex:lastColon.location + 1];
      if (![self parsePort:portStr into:&port]) return nil;
    } else {
      host = noScheme;  // bare host (or an unbracketed IPv6 → refused below)
    }
  }
  if (port <= 0 || port > 65535) return nil;
  if (![self isCleartextAllowed:host]) return nil;
  BOOL v6 = [host rangeOfString:@":"].location != NSNotFound;  // raw IPv6 literal needs brackets
  return [NSString stringWithFormat:@"ws://%@:%d/", v6 ? [NSString stringWithFormat:@"[%@]", host] : host, port];
}

// Parse a base-10 port string strictly (digits only, fits an int). NO on any non-digit.
+ (BOOL)parsePort:(NSString *)s into:(int *)out {
  if (s.length == 0) return NO;
  int v = 0;
  for (NSUInteger i = 0; i < s.length; i++) {
    unichar c = [s characterAtIndex:i];
    if (c < '0' || c > '9') return NO;
    v = v * 10 + (c - '0');
    if (v > 65535) return NO;
  }
  *out = v;
  return YES;
}

// ---- the I/O shell: NSURLSessionWebSocketTask + auto-reconnect ----------------------------------

+ (instancetype)startWithDevHost:(NSString *)devHost {
#if DEBUG
  NSString *url = [self deriveWsUrl:devHost];
  if (url == nil) {
    os_log_info(CanopyDevLog(),
                "dev client not started — CANOPY_DEV_HOST '%{public}s' is missing or not on the "
                "cleartext allowlist (localhost/LAN only)",
                devHost.UTF8String ?: "(nil)");
    return nil;
  }
  CanopyDevClient *c = [[CanopyDevClient alloc] initWithUrl:url];
  [c connect];
  os_log_info(CanopyDevLog(), "dev client connecting to %{public}s", url.UTF8String);
  return c;
#else
  // Release: the dev loop is never started (the whole socket path is compiled out).
  (void)devHost;
  return nil;
#endif
}

- (instancetype)initWithUrl:(NSString *)url {
  if ((self = [super init])) {
    _url = url;
    _stopped = NO;
    _attempt = 0;
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    // No read timeout (a WS is idle between pushes); a short connect timeout so a downed server fails
    // fast into the reconnect backoff.
    cfg.timeoutIntervalForRequest = 4.0;
    _session = [NSURLSession sessionWithConfiguration:cfg
                                             delegate:self
                                        delegateQueue:nil];
  }
  return self;
}

- (void)stop {
  _stopped = YES;
  NSURLSessionWebSocketTask *s = _socket;
  if (s != nil) [s cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
  _socket = nil;
}

- (void)connect {
  if (_stopped) return;
  NSURL *url = [NSURL URLWithString:_url];
  if (url == nil) return;
  _socket = [_session webSocketTaskWithURL:url];
  [_socket resume];
  [self receiveNext];
}

// Pump the next text frame, then re-arm. A receive error tears the socket down → reconnect.
- (void)receiveNext {
  __weak CanopyDevClient *weakSelf = self;
  [_socket receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
    CanopyDevClient *self_ = weakSelf;
    if (self_ == nil || self_->_stopped) return;
    if (error != nil) {
      os_log_info(CanopyDevLog(), "dev socket failure: %{public}s", error.localizedDescription.UTF8String);
      [self_ scheduleReconnect];
      return;
    }
    if (message.type == NSURLSessionWebSocketMessageTypeString && message.string != nil) {
      @try {
        [self_ handle:[CanopyDevClient parseFrame:message.string]];
      } @catch (NSException *ex) {
        os_log_error(CanopyDevLog(), "frame handling error (ignored): %{public}s", ex.reason.UTF8String);
      }
    }
    [self_ receiveNext];  // re-arm for the next frame
  }];
}

// Schedule a reconnect after the current backoff, then advance the backoff.
- (void)scheduleReconnect {
  if (_stopped) return;
  long delay = [CanopyDevClient backoffMs:_attempt];
  _attempt++;
  os_log_info(CanopyDevLog(), "dev server unreachable — retrying in %ldms (attempt %ld)", delay, (long)_attempt);
  __weak CanopyDevClient *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_MSEC)),
                 dispatch_get_main_queue(), ^{
    [weakSelf connect];
  });
}

// Apply one parsed frame. Every host effect (reload / red-box) is marshalled to the main thread,
// where the runtime + views live (mirror of the Java handle()).
- (void)handle:(CanopyDevFrame *)f {
  switch (f.action) {
    case CanopyDevActionHello:
      _lastBuildId = f.buildId;
      os_log_info(CanopyDevLog(), "connected — server buildId=%{public}s", (f.buildId ?: @"?").UTF8String);
      break;
    case CanopyDevActionBuilding:
      os_log_info(CanopyDevLog(), "rebuilding…");
      break;
    case CanopyDevActionReload: {
      if (f.buildId != nil && [f.buildId isEqualToString:(_lastBuildId ?: @"")]) {
        // Guard a duplicate delivery so the identical bundle is never re-eval'd (a wasted flicker).
        os_log_info(CanopyDevLog(), "reload buildId unchanged — skipping");
        break;
      }
      _lastBuildId = f.buildId;
      os_log_info(CanopyDevLog(), "reload → in-process re-eval (buildId=%{public}s)",
                  (f.buildId.length >= 12 ? [f.buildId substringToIndex:12] : (f.buildId ?: @"?")).UTF8String);
      [self applyReload:f.bundle];
      break;
    }
    case CanopyDevActionNoChange:
      os_log_info(CanopyDevLog(), "no change (buildId unchanged) — server short-circuited");
      break;
    case CanopyDevActionError:
      os_log_error(CanopyDevLog(), "build FAILED:\n%{public}s", (f.report ?: @"").UTF8String);
      [self showBuildError:f.report];
      break;
    case CanopyDevActionIgnore:
    default:
      break;
  }
}

// Drive the DEV-12 in-process reload with the pushed JS bundle, on the main queue (where the runtime
// + every __fabric_* mount live). We reach the live CanopyHostViewController via the key window's
// root view controller — the SAME path the AppShell capability uses (CanopyAppShellModule.mm) — so
// this debug tool needs no extra production seam.
- (void)applyReload:(NSString *)bundleJs {
  dispatch_async(dispatch_get_main_queue(), ^{
    CanopyHostViewController *vc = [CanopyDevClient hostViewController];
    if (vc != nil) {
      [vc reloadWithBundle:bundleJs];
    } else {
      os_log_error(CanopyDevLog(), "reload dropped — no CanopyHostViewController is the window root");
    }
  });
}

// Surface a build/compile error as the dev red-box (non-fatal: the prior good tree stays up
// underneath, so dismissing returns to the last working program — DEV-11 recovery posture).
- (void)showBuildError:(NSString *)report {
  dispatch_async(dispatch_get_main_queue(), ^{
    CanopyHostViewController *vc = [CanopyDevClient hostViewController];
    if (vc != nil) [vc showDevBuildError:(report ?: @"(no report)")];
  });
}

// Resolve the live host view controller off the key window (mirror of CanopyAppShellHostVC).
+ (nullable CanopyHostViewController *)hostViewController {
  UIViewController *root = nil;
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
    if ([scene isKindOfClass:[UIWindowScene class]]) {
      UIWindowScene *ws = (UIWindowScene *)scene;
      UIWindow *window = ws.keyWindow ?: ws.windows.firstObject;
      if (window.rootViewController != nil) { root = window.rootViewController; break; }
    }
  }
  return [root isKindOfClass:[CanopyHostViewController class]] ? (CanopyHostViewController *)root : nil;
}

// ---- NSURLSessionWebSocketDelegate: socket lifecycle → reconnect --------------------------------

- (void)URLSession:(NSURLSession *)session
      webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask
 didOpenWithProtocol:(NSString *)protocol {
  _attempt = 0;  // a successful connect resets the backoff
  os_log_info(CanopyDevLog(), "dev socket open");
}

- (void)URLSession:(NSURLSession *)session
      webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask
   didCloseWithCode:(NSURLSessionWebSocketCloseCode)closeCode
             reason:(NSData *)reason {
  os_log_info(CanopyDevLog(), "dev socket closed (%ld)", (long)closeCode);
  if (!_stopped) [self scheduleReconnect];
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
  // A connect failure (server down) lands here with an error and no open — drive the reconnect.
  if (error != nil && !_stopped) {
    os_log_info(CanopyDevLog(), "dev task failed: %{public}s", error.localizedDescription.UTF8String);
    [self scheduleReconnect];
  }
}

@end
