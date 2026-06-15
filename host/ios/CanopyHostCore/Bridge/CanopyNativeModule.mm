// CanopyNativeModule.mm — the ObjC↔C++ NativeModule glue implementation (contract §4.2).
//
// One private C++ class — ObjCNativeModule — is the entire bridge: it subclasses
// canopy::NativeModule and forwards invoke(CallContext&) to an id<CanopyModule> by direct ObjC
// message send. Everything the Android JniModule needed JNI for (FindClass, GetStaticMethodID,
// the erase-on-resolve pending table, resolveModule, AttachCurrentThread) collapses to a single
// [module invokeMethod:…] call, because the host already holds the runtime + registry and the
// registry's postToJs is the only thread hop. See CanopyNativeModule.h for the full contract.
//
// Compiled as Objective-C++ with ARC.

#import "CanopyNativeModule.h"

#import <objc/runtime.h>

#include <memory>
#include <string>

using canopy::CallContext;
using canopy::ModuleRegistry;
using canopy::NativeModule;

namespace {

// std::string → NSString. The ABI strings are always valid UTF-8 JSON; fall back to a non-nil
// empty string on the (impossible) decode failure so the block contract holds.
inline NSString *toNS(const std::string &s) {
  NSString *out = [[NSString alloc] initWithBytes:s.data()
                                           length:(NSUInteger)s.size()
                                         encoding:NSUTF8StringEncoding];
  return out ?: @"";
}

// NSString → std::string. nil → empty (matches the ABI's "" => success/void convention, so a
// capability that calls complete(nil, nil) resolves an empty success, and complete("err", nil)
// rejects with the error and a null result).
inline std::string toStd(NSString *_Nullable s) {
  if (s == nil) { return std::string(); }
  const char *c = [s UTF8String];
  return c ? std::string(c) : std::string();
}

// Build a {"code":"rejected","message":msg} JSON string, escaping `msg` via NSJSONSerialization.
std::string rejectionJson(NSString *msg) {
  NSDictionary *obj = @{ @"code" : @"rejected", @"message" : (msg ?: @"module invoke threw") };
  NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
  if (data) { return std::string((const char *)data.bytes, (size_t)data.length); }
  return std::string(R"({"code":"rejected","message":"module invoke threw"})");
}

// ===========================================================================
// ObjCNativeModule — the C++ NativeModule wrapping one id<CanopyModule>.
//
// Mirrors canopy::JniModule (one-shot) AND StreamingJniModule (the completion fired repeatedly)
// in a single class: on iOS the capability owns its own async/streaming policy, so there is no
// erase-on-first-resolve table to work around — the block simply re-fires ctx.complete for each
// streamed event, and -cancelCallId: stops it.
// ===========================================================================
class ObjCNativeModule final : public NativeModule {
 public:
  explicit ObjCNativeModule(id<CanopyModule> module)
      : module_(module), name_(toStd([module moduleName])) {}

  std::string name() const override { return name_; }

  bool invoke(CallContext &ctx) override {
    // Copy ctx.complete (a std::function; the registry already made it hop to the JS thread).
    // The block captures it and may call it from any queue, any number of times.
    auto complete = ctx.complete;

    CanopyComplete block = ^(NSString *_Nullable errJson, NSString *_Nullable resultJson) {
      if (complete) {
        complete(toStd(errJson), toStd(resultJson));  // → postToJs → __canopy_resolve
      }
    };

    @autoreleasepool {
      @try {
        // Direct ObjC dispatch — the iOS analog of callJavaModule, minus reflection.
        BOOL known = [module_ invokeMethod:toNS(ctx.method)
                                      args:toNS(ctx.argsJson)
                                    callId:toNS(ctx.callId)
                                  complete:block];
        return known ? true : false;  // false → dispatcher reports -1 / ModuleNotFound
      } @catch (NSException *ex) {
        // A capability that threw (bad arg, programmer error) must not SIGABRT the runtime —
        // contain it and resolve a rejection, exactly like CanopyJni's drainJavaException
        // (CanopyJni.cpp:27-34). The method WAS dispatched (it threw, not "unknown"), so we
        // report known=true and surface the error through the same complete path.
        if (complete) { complete(rejectionJson(ex.reason), std::string()); }
        return true;
      }
    }
  }

  void cancel(const std::string &callId) override {
    if (![module_ respondsToSelector:@selector(cancelCallId:)]) { return; }
    @autoreleasepool {
      @try {
        [module_ cancelCallId:toNS(callId)];
      } @catch (NSException *) {
        // best-effort, idempotent — a capability that can't cancel cleanly is not fatal.
      }
    }
  }

 private:
  id<CanopyModule> module_;  // strong (ARC): keeps the capability alive for the registry's life
  std::string name_;
};

}  // namespace

// ===========================================================================
// CanopyNativeModuleBridge
// ===========================================================================
@implementation CanopyNativeModuleBridge

+ (void)registerModule:(id<CanopyModule>)module inRegistry:(ModuleRegistry *)registry {
  if (module == nil || registry == nullptr) { return; }
  registry->registerModule(std::make_shared<ObjCNativeModule>(module));
}

+ (BOOL)registerModuleNamed:(NSString *)name
                 inRegistry:(ModuleRegistry *)registry
       swiftModulePrefixes:(NSArray<NSString *> *)swiftModulePrefixes
          streamingMethods:(NSArray<NSString *> *)streamingMethods {
  if (name.length == 0 || registry == nullptr) { return NO; }

  // "Photos" → CanopyPhotosModule (the ObjC analog of "com/canopyhost/modules/PhotosModule").
  NSString *plain = [NSString stringWithFormat:@"Canopy%@Module", name];

  Class cls = NSClassFromString(plain);
  if (cls == Nil) {
    // Swift classes are runtime-named "<ProductModule>.Canopy<Name>Module".
    for (NSString *prefix in swiftModulePrefixes) {
      if (prefix.length == 0) { continue; }
      Class c = NSClassFromString([NSString stringWithFormat:@"%@.%@", prefix, plain]);
      if (c != Nil) { cls = c; break; }
    }
  }
  if (cls == Nil) { return NO; }  // no such capability class — caller logs / falls back

  if (![cls conformsToProtocol:@protocol(CanopyModule)]) { return NO; }
  if (![cls instancesRespondToSelector:@selector(init)]) { return NO; }

  id<CanopyModule> module = [[cls alloc] init];
  if (module == nil) { return NO; }

  if (streamingMethods.count > 0 &&
      [module respondsToSelector:@selector(setStreamingMethods:)]) {
    [module setStreamingMethods:streamingMethods];
  }

  [self registerModule:module inRegistry:registry];
  return YES;
}

@end
