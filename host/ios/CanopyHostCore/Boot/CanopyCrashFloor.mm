// CanopyCrashFloor.mm — REL-2: the iOS crash FLOOR (process-level uncaught-NSException handler).
//
// WHAT THIS IS (and is NOT). Per-call / per-render NSExceptions are ALREADY contained at every host
// boundary (CanopyNativeModule.mm @try/@catch around invokeMethod; CanopyHostFabric.mm applyProps /
// CanopyColor; CanopyHostViewController boot → reportFatal, not SIGABRT). This class is the
// complementary LAST RESORT for what escapes those: an NSException raised on a thread with no @catch
// on its stack (a GCD block, a delegate callback, a notification) that today goes straight to the
// default terminator → a silent kill with no record keyed to the build the user ran. It is the iOS
// twin of CanopyCrashFloor.java (the Android JVM half).
//
// WHAT IT DOES. CanopyCrashFloorInstall() captures any previously-installed uncaught handler, sets
// ours, and ours writes a small buildId-keyed JSON record (Caches/canopy-crashes/) then CHAINS the
// prior handler — so a future PLCrashReporter/Sentry handler still runs and the process still
// terminates. We never swallow. The handler runs in a NORMAL context (an NSException, not a signal),
// so ordinary Foundation/file I/O here is safe — there is NO async-signal constraint.
//
// SCOPE. NSException only. A POSIX/Mach SIGNAL handler (SIGSEGV/SIGABRT via sigaction) for hard
// crashes is deliberately NOT shipped: in an async-signal context almost everything is unsafe, a buggy
// handler turns a clean, symbolicated Apple crash report into a hang or double-fault (the worst
// regression for a reliability product), and it conflicts with the very crash-reporter tooling a store
// build would adopt. Hard signals already produce a correct Apple crash report; we forgo our own
// in-process breadcrumb for them. See docs/guarantee.md caveat (host signals) + plans/MASTER-PLAN.md
// REL-2 (which gates the signal half behind a flag, off by default, until device-validated).

#import "CanopyCrashFloor.h"
#import <Foundation/Foundation.h>

static NSUncaughtExceptionHandler *gCanopyPriorHandler = NULL;
static BOOL gCanopyInstalled = NO;

// The content-addressed buildId (== bundle sha256) from the packaged canopy.manifest.json — the REL-4
// crash-free key. Falls back to CFBundleVersion, then "unknown". Read once at install; safe + cheap.
static NSString *CanopyReadBuildId(void) {
  @try {
    NSString *path = [[NSBundle mainBundle] pathForResource:@"canopy.manifest" ofType:@"json"];
    if (path != nil) {
      NSData *data = [NSData dataWithContentsOfFile:path];
      if (data != nil) {
        NSDictionary *m = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        id bid = [m isKindOfClass:[NSDictionary class]] ? m[@"buildId"] : nil;
        if ([bid isKindOfClass:[NSString class]] && [(NSString *)bid length] > 0) return (NSString *)bid;
      }
    }
    NSString *v = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"];
    if ([v length] > 0) return v;
  } @catch (__unused NSException *e) {}
  return @"unknown";
}

static NSString *gCanopyBuildId = nil;
// TEL-1: the anonymous per-process-launch id (random UUID; never device-stable, no PII) that ties a
// crash to its session so REL-4 can compute crash-free = 1 - sessions-with-fatal / total-sessions.
static NSString *gCanopySessionId = nil;

// OS version string (Foundation-only — NSProcessInfo, so this TU need not import UIKit).
static NSString *CanopyOSVersion(void) {
  @try { return [[NSProcessInfo processInfo] operatingSystemVersionString]; }
  @catch (__unused NSException *e) { return @""; }
}

// App version (CFBundleVersion), unified with Android's appVersion string.
static NSString *CanopyAppVersion(void) {
  @try { return [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @""; }
  @catch (__unused NSException *e) { return @""; }
}

// The headline crash-free metric is only computed from "device" events; the Simulator is caveated.
static NSString *CanopySource(void) {
#if TARGET_OS_SIMULATOR
  return @"simulator";
#else
  return @"device";
#endif
}

// TEL-1: the on-disk telemetry RING (Caches/canopy-telemetry, created lazily). Holds the per-launch
// session-start beacons + crash records; no-network default, consumed on the next launch.
static NSString *CanopyCrashDir(void) {
  NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
  NSString *base = dirs.firstObject ?: NSTemporaryDirectory();
  return [base stringByAppendingPathComponent:@"canopy-telemetry"];
}

// Write one crash record. Runs in a normal (non-signal) context, so Foundation is safe here.
static void CanopyWriteRecord(NSException *e) {
  @try {
    NSString *dir = CanopyCrashDir();
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:dir]) {
      [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    }
    double ts = [[NSDate date] timeIntervalSince1970] * 1000.0;
    // Cap the symbol dump — a record is a breadcrumb, not a full report.
    NSArray<NSString *> *frames = [e callStackSymbols];
    if (frames.count > 40) frames = [frames subarrayWithRange:NSMakeRange(0, 40)];
    NSDictionary *record = @{
      @"schema": @2,
      @"eventType": @"crash",
      @"kind": @"nsexception",
      @"platform": @"ios",
      @"buildId": (gCanopyBuildId ?: @"unknown"),
      @"sessionId": (gCanopySessionId ?: @""),
      @"appVersion": (CanopyAppVersion() ?: @""),
      @"osVersion": (CanopyOSVersion() ?: @""),
      @"source": CanopySource(),
      @"timestampMs": @((long long)ts),
      @"errorClass": (e.name ?: @"?"),
      @"message": (e.reason ?: @""),
      @"frames": (frames ?: @[]),
      @"fatal": @YES,
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:record
                                                  options:0
                                                    error:NULL];
    if (json != nil) {
      NSString *file = [dir stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"crash-%@-%lld.json", (gCanopyBuildId ?: @"unknown"), (long long)ts]];
      [json writeToFile:file atomically:YES];
    }
  } @catch (__unused NSException *inner) {
    // The floor must NEVER make a crash worse — swallow any recording failure and chain through.
  }
}

// TEL-1: the per-launch session-start beacon (the crash-free DENOMINATOR). Runs once at install on a
// healthy process, so Foundation file I/O is safe (no async-signal constraint).
static void CanopyWriteSessionStart(void) {
  @try {
    NSString *dir = CanopyCrashDir();
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:dir]) {
      [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    }
    double ts = [[NSDate date] timeIntervalSince1970] * 1000.0;
    NSDictionary *record = @{
      @"schema": @2,
      @"eventType": @"session-start",
      @"platform": @"ios",
      @"buildId": (gCanopyBuildId ?: @"unknown"),
      @"sessionId": (gCanopySessionId ?: @""),
      @"appVersion": (CanopyAppVersion() ?: @""),
      @"osVersion": (CanopyOSVersion() ?: @""),
      @"source": CanopySource(),
      @"timestampMs": @((long long)ts),
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:record options:0 error:NULL];
    if (json != nil) {
      [json writeToFile:[dir stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"session-%@.json", (gCanopySessionId ?: @"x")]]
             atomically:YES];
    }
  } @catch (__unused NSException *inner) { /* a missing beacon must never block boot */ }
}

static void CanopyHandleUncaught(NSException *e) {
  CanopyWriteRecord(e);
  // ALWAYS chain — never swallow. If a prior handler existed (e.g. a crash reporter), let it run; the
  // process then terminates as it would have. With no prior handler, returning lets the default
  // uncaught-exception termination proceed.
  if (gCanopyPriorHandler != NULL) {
    gCanopyPriorHandler(e);
  }
}

void CanopyCrashFloorInstall(void) {
  if (gCanopyInstalled) return;
  gCanopyInstalled = YES;
  gCanopyBuildId = CanopyReadBuildId();
  gCanopySessionId = [[NSUUID UUID] UUIDString];
  CanopyWriteSessionStart();                       // TEL-1: the crash-free denominator beacon.
  gCanopyPriorHandler = NSGetUncaughtExceptionHandler();
  NSSetUncaughtExceptionHandler(&CanopyHandleUncaught);
  NSLog(@"[CanopyCrashFloor] installed (buildId %@, session %@)", gCanopyBuildId, gCanopySessionId);
}

// Telemetry consent — default FALSE (no network without explicit opt-in).
static BOOL CanopyTelemetryOptIn(void) {
  @try { return [[NSUserDefaults standardUserDefaults] boolForKey:@"canopy.telemetry.optIn"]; }
  @catch (__unused NSException *e) { return NO; }
}

// TEL-1 sink. The on-disk ring IS the default sink: records PERSIST locally (no network) so the
// crashfree-report can read the last launch's session-start + crash events. Records are forwarded
// off-device ONLY when the user has opted in AND a telemetryEndpoint is configured — otherwise this
// makes ZERO network calls. Returns the number of events currently in the ring.
int CanopyCrashFloorDrainPending(void) {
  int n = 0;
  @try {
    NSString *dir = CanopyCrashDir();
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *files = [fm contentsOfDirectoryAtPath:dir error:NULL];
    for (NSString *name in files) {
      if ([name hasSuffix:@".json"]) n++;
    }
    if (CanopyTelemetryOptIn()) {
      // (TEL-1 HTTP sink: POST the ring as newline-delimited JSON to telemetryEndpoint here, then
      // clear forwarded events. Opt-in + endpoint required; stubbed until an endpoint is wired.)
      NSLog(@"[CanopyCrashFloor] telemetry opt-in ON — %d event(s) ready to forward", n);
    } else {
      NSLog(@"[CanopyCrashFloor] telemetry opt-in OFF (no network) — %d event(s) retained in the ring", n);
    }
  } @catch (__unused NSException *e) {}
  return n;
}
