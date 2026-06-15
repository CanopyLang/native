// CanopyHttpModule.mm — the iOS host module behind Native.Http (module "Http").
//
// iOS analog of android/.../modules/HttpModule.java. Adopts the §4.1 CanopyModule protocol; the
// §4.2 bridge routes __canopy_call(module="Http", …) here. We perform the real HTTP request via
// NSURLSession (the iOS analog of HttpURLConnection) and resolve the caller's Task exactly like
// the one-shot capabilities — only the work differs. NSURLSession's completion fires on the
// session's delegate queue (a background queue); the CanopyComplete block hops to JS internally.
//
// Wire contract (must match Native/Http.can and HttpModule.java):
//   request {method, url, headers:{k:v}, body}  ->  {status:Int, body:String, headers:{k:v}}
// Non-2xx is NOT an error — it resolves with the status + the response body (RN/fetch semantics:
// only transport failures reject). Response header keys are lowercased to match the Android side.

#import <Foundation/Foundation.h>

#import "CanopyModule.h"
#import "CanopyModuleSupport.h"

@interface CanopyHttpModule : NSObject <CanopyModule>
@end

@implementation CanopyHttpModule {
  NSURLSession *_session;
}

- (instancetype)init {
  if ((self = [super init])) {
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest  = 30.0;   // matches Android's 30s read timeout
    config.timeoutIntervalForResource = 60.0;
    config.HTTPShouldUsePipelining    = NO;
    _session = [NSURLSession sessionWithConfiguration:config];
  }
  return self;
}

- (NSString *)moduleName { return @"Http"; }

- (BOOL)invokeMethod:(NSString *)method
                args:(NSString *)argsJson
              callId:(NSString *)callId
            complete:(CanopyComplete)complete {
  if (![method isEqualToString:@"request"]) { return NO; }  // ModuleNotFound otherwise

  @try {
    NSDictionary *args = CanopyParseArgs(argsJson);
    NSString *urlStr = [args[@"url"] isKindOfClass:[NSString class]] ? args[@"url"] : nil;
    if (urlStr.length == 0) { CanopyReject(complete, @"rejected", @"missing url"); return YES; }
    NSURL *url = [NSURL URLWithString:urlStr];
    if (url == nil) { CanopyReject(complete, @"rejected", [@"bad url: " stringByAppendingString:urlStr]); return YES; }

    NSString *httpMethod = [args[@"method"] isKindOfClass:[NSString class]]
        ? [args[@"method"] uppercaseString] : @"GET";

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = httpMethod;

    NSDictionary *headers = [args[@"headers"] isKindOfClass:[NSDictionary class]] ? args[@"headers"] : nil;
    for (NSString *k in headers) {
      id v = headers[k];
      if ([v isKindOfClass:[NSString class]]) { [req setValue:(NSString *)v forHTTPHeaderField:k]; }
    }

    NSString *body = [args[@"body"] isKindOfClass:[NSString class]] ? args[@"body"] : @"";
    if (body.length > 0 && ![httpMethod isEqualToString:@"GET"] && ![httpMethod isEqualToString:@"HEAD"]) {
      req.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];
    }

    NSURLSessionDataTask *task = [_session dataTaskWithRequest:req
                                            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
      if (error != nil) {
        // Only transport failures reject (fetch semantics). Non-2xx is a normal resolve below.
        CanopyReject(complete, @"rejected",
                     [NSString stringWithFormat:@"%@: %@",
                      @(error.code), error.localizedDescription ?: @"network error"]);
        return;
      }
      NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]]
          ? (NSHTTPURLResponse *)response : nil;
      NSInteger status = http ? http.statusCode : 0;
      NSString *respBody = data.length
          ? ([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"")
          : @"";

      // Lowercase header keys to match the Android responseHeaders() shape.
      NSMutableDictionary *respHeaders = [NSMutableDictionary dictionary];
      for (NSString *k in http.allHeaderFields) {
        id v = http.allHeaderFields[k];
        if ([k isKindOfClass:[NSString class]] && [v isKindOfClass:[NSString class]]) {
          respHeaders[[k lowercaseString]] = v;
        }
      }
      CanopyResolve(complete, @{
        @"status":  @(status),
        @"body":    respBody,
        @"headers": respHeaders,
      });
    }];
    [task resume];
  } @catch (NSException *e) {
    CanopyReject(complete, @"rejected", e.reason ?: @"http error");
  }
  return YES;
}

@end
