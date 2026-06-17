// CanopySignalFloor.h — REL-2 SIG half: the native HARD-CRASH floor (POSIX signals), portable C++.
//
// Complements the JVM/NSException crash floors (CanopyCrashFloor.{java,mm}): those catch language-level
// uncaught throwables; THIS catches the hard native faults below the JS boundary — SIGSEGV / SIGABRT /
// SIGBUS / SIGILL / SIGFPE — and leaves the same buildId-keyed telemetry breadcrumb the REL-4 crash-free
// metric reads, then CHAINS the prior disposition so the OS still produces its crash report.
//
// ASYNC-SIGNAL-SAFETY (the whole point): the handler does ONLY async-signal-safe work — it write()s a
// record that was FULLY PRE-FORMATTED at install time (no snprintf/malloc/NSLog/JNI in the handler) to a
// fd PRE-OPENED at install, fsync()s it, restores the prior handler, and re-raise()s the signal. It runs
// on an alternate stack (sigaltstack) so a stack-overflow SIGSEGV can still be recorded.
//
// OFF BY DEFAULT. A buggy signal handler is a NET reliability regression for a reliability product, and
// hard signals already yield a correct OS crash report — so production callers install this ONLY behind
// an explicit opt-in, until it is validated on a real device. The device-free correctness (records the
// right signal + chains so the process still dies with it) is proven by tools/signalfloor-test.cpp.
#pragma once

namespace canopy {

// Install async-signal-safe handlers for the hard native signals. `recordDir` must already exist
// (the caller's telemetry dir); one "signal-<sessionId>.json" record is pre-opened there. The other
// strings are baked into the pre-formatted record at install. Idempotent. Returns true if installed.
bool installSignalFloor(const char* recordDir, const char* buildId, const char* sessionId,
                        const char* platform, const char* source);

// Test seam (NOT for production paths): number of signals caught + recorded so far this process.
int signalFloorCaughtCount();

}  // namespace canopy
