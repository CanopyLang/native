// CanopyStorageSecureModule.mm — the iOS host module behind canopy/storage-secure
// (module "StorageSecure").
//
// iOS analog of android/.../modules/StorageSecureModule.java. Adopts the §4.1 CanopyModule
// protocol; the §4.2 bridge routes __canopy_call(module="StorageSecure", …) here. Durable
// key/value strings — no Bitmap, no blob bridge (this capability never touches binary).
//
// Namespaces (mirroring the Android local/secure split):
//   "secure" -> Keychain (kSecClassGenericPassword, kSecAttrAccessibleAfterFirstUnlock) — the
//               billing-entitlement cache lives here so the paywall resolves offline and a prefs
//               reader cannot forge it. Keychain entries are encrypted at rest and device-bound,
//               the iOS equivalent of EncryptedSharedPreferences.
//   "local"  -> NSUserDefaults (suite "canopy_local") — unencrypted, the SharedPreferences analog.
//
// Threading: Keychain/UserDefaults calls are quick and thread-safe; we still run them on a serial
// queue so a get the paywall issues right after a set sees the durable value and the JS/main
// thread is never blocked.
//
// Wire contract (must match storage-secure.js / Storage/Secure.can and StorageSecureModule.java):
//   get    {ns,key}        -> {value:<string>|null}   (absent key => {value:null}, success)
//   set    {ns,key,value}  -> null
//   remove {ns,key}        -> null

#import <Foundation/Foundation.h>
#import <Security/Security.h>

#import "CanopyModule.h"
#import "CanopyModuleSupport.h"

static NSString *const kSecureService = @"com.canopyhost.storage.secure";
static NSString *const kLocalSuite    = @"canopy_local";

@interface CanopyStorageSecureModule : NSObject <CanopyModule>
@end

@implementation CanopyStorageSecureModule {
  dispatch_queue_t _queue;
}

- (instancetype)init {
  if ((self = [super init])) {
    _queue = dispatch_queue_create("com.canopyhost.storage", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

- (NSString *)moduleName { return @"StorageSecure"; }

- (BOOL)invokeMethod:(NSString *)method
                args:(NSString *)argsJson
              callId:(NSString *)callId
            complete:(CanopyComplete)complete {
  if (![method isEqualToString:@"get"] &&
      ![method isEqualToString:@"set"] &&
      ![method isEqualToString:@"remove"]) {
    return NO;
  }
  dispatch_async(_queue, ^{
    @try {
      NSDictionary *args = CanopyParseArgs(argsJson);
      NSString *ns  = [args[@"ns"]  isKindOfClass:[NSString class]] ? args[@"ns"]  : @"local";
      NSString *key = [args[@"key"] isKindOfClass:[NSString class]] ? args[@"key"] : nil;
      if (key.length == 0) { CanopyReject(complete, @"rejected", @"missing key"); return; }
      BOOL secure = [ns isEqualToString:@"secure"];

      if ([method isEqualToString:@"get"]) {
        NSString *value = secure ? [self keychainGet:key] : [self localGet:key];
        // contains() semantics: absent key => null; a stored "" => "".
        CanopyResolve(complete, @{ @"value": value ?: (id)[NSNull null] });
      } else if ([method isEqualToString:@"set"]) {
        NSString *value = [args[@"value"] isKindOfClass:[NSString class]] ? args[@"value"] : @"";
        BOOL ok = secure ? [self keychainSet:key value:value] : [self localSet:key value:value];
        if (!ok) { CanopyReject(complete, @"rejected", [@"store failed for ns=" stringByAppendingString:ns]); return; }
        CanopyResolveNull(complete);
      } else {  // remove (idempotent — removing an absent key still succeeds)
        if (secure) { [self keychainRemove:key]; } else { [self localRemove:key]; }
        CanopyResolveNull(complete);
      }
    } @catch (NSException *e) {
      CanopyReject(complete, @"rejected", e.reason ?: @"storage error");
    }
  });
  return YES;
}

// ---- local (NSUserDefaults suite) ---------------------------------------------------------

- (NSUserDefaults *)localDefaults {
  return [[NSUserDefaults alloc] initWithSuiteName:kLocalSuite];
}

- (NSString *)localGet:(NSString *)key {
  id obj = [[self localDefaults] objectForKey:key];
  return [obj isKindOfClass:[NSString class]] ? (NSString *)obj : nil;
}

- (BOOL)localSet:(NSString *)key value:(NSString *)value {
  NSUserDefaults *d = [self localDefaults];
  [d setObject:value forKey:key];
  return [d synchronize];  // durable before we resolve (the entitlement-cache contract)
}

- (void)localRemove:(NSString *)key {
  NSUserDefaults *d = [self localDefaults];
  [d removeObjectForKey:key];
  [d synchronize];
}

// ---- secure (Keychain generic-password items) ---------------------------------------------

- (NSDictionary *)keychainQueryForKey:(NSString *)key {
  return @{
    (__bridge id)kSecClass:       (__bridge id)kSecClassGenericPassword,
    (__bridge id)kSecAttrService: kSecureService,
    (__bridge id)kSecAttrAccount: key,
  };
}

- (NSString *)keychainGet:(NSString *)key {
  NSMutableDictionary *q = [[self keychainQueryForKey:key] mutableCopy];
  q[(__bridge id)kSecReturnData]  = (__bridge id)kCFBooleanTrue;
  q[(__bridge id)kSecMatchLimit]  = (__bridge id)kSecMatchLimitOne;
  CFTypeRef result = NULL;
  OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)q, &result);
  if (status != errSecSuccess || result == NULL) { return nil; }  // absent => nil => JSON null
  NSData *data = (__bridge_transfer NSData *)result;
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

- (BOOL)keychainSet:(NSString *)key value:(NSString *)value {
  NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
  NSMutableDictionary *q = [[self keychainQueryForKey:key] mutableCopy];

  // Upsert: try update, fall back to add. SecItemUpdate fails if the item is absent.
  NSDictionary *attrsToUpdate = @{ (__bridge id)kSecValueData: data };
  OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)q,
                                  (__bridge CFDictionaryRef)attrsToUpdate);
  if (status == errSecItemNotFound) {
    q[(__bridge id)kSecValueData]       = data;
    q[(__bridge id)kSecAttrAccessible]  = (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
    status = SecItemAdd((__bridge CFDictionaryRef)q, NULL);
  }
  return status == errSecSuccess;
}

- (void)keychainRemove:(NSString *)key {
  SecItemDelete((__bridge CFDictionaryRef)[self keychainQueryForKey:key]);  // idempotent
}

@end
