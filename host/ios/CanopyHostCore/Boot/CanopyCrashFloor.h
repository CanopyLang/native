// CanopyCrashFloor.h — REL-2: the iOS crash FLOOR (process-level NSException handler).
//
// Swift-SAFE C surface (no jsi/Yoga/raw C++), so it is imported into the bridging header and called
// from AppDelegate at launch. See CanopyCrashFloor.mm for what/why.
#ifndef CanopyCrashFloor_h
#define CanopyCrashFloor_h

#ifdef __cplusplus
extern "C" {
#endif

/// Install the process-level uncaught-NSException handler (idempotent). Call FIRST in
/// application:didFinishLaunchingWithOptions:, before any scene/Hermes work. It writes a
/// buildId-keyed crash record then CHAINS any previously-installed handler (never swallows /
/// never clobbers a PLCrashReporter/Sentry-style handler installed before us).
void CanopyCrashFloorInstall(void);

/// Read + log any crash records left by a PRIOR launch, then delete them (consumed). Returns the
/// count. A future TEL-1 sink forwards each record before deletion. Safe to call at launch.
int CanopyCrashFloorDrainPending(void);

#ifdef __cplusplus
}
#endif

#endif /* CanopyCrashFloor_h */
