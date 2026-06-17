#!/usr/bin/env bash
# check-crash-floor.sh — REL-2: keep the host crash FLOOR installed + chaining on both platforms.
#
# The crash floor catches an UNRECOVERABLE uncaught error (a JVM Throwable on an unguarded thread; an
# NSException with no @catch on its stack) that the red-box / @try-@catch recoverable path cannot reach,
# writes a buildId-keyed crash record, and ALWAYS chains the previously-installed handler (so the OS
# still produces its tombstone/kill and any PLCrashReporter/Sentry handler still runs). This device-free
# gate asserts, by grep, that on BOTH hosts the floor is (a) installed on the process boot path, (b)
# captures + chains the prior handler (the load-bearing safety property — never swallow a crash), and
# (c) emits a record carrying the REL-4 keys (buildId + platform + kind). A regression that removes the
# install, stops chaining, or drops a key fails CI — no device required.
#
# SCOPE NOTE: the JVM/NSException floor is the always-on default. The native SIGSEGV/SIGABRT signal
# floor (CanopySignalFloor) is now IMPLEMENTED + device-free-verified (tools/signalfloor-test.cpp:
# records + chains for all 5 hard signals) but ships OFF BY DEFAULT behind the CANOPY_SIGNAL_FLOOR
# opt-in — a buggy async-signal handler is a net reliability regression and hard signals already yield
# an OS tombstone, so it stays opt-in until device-validated. See docs/guarantee.md (host signals).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AND_FLOOR="$ROOT/host/android/app/src/main/java/com/canopyhost/CanopyCrashFloor.java"
AND_ACT="$ROOT/host/android/app/src/main/java/com/canopyhost/MainActivity.java"
IOS_FLOOR="$ROOT/host/ios/CanopyHostCore/Boot/CanopyCrashFloor.mm"
IOS_APP="$ROOT/host/ios/CanopyHostApp/AppDelegate.swift"
IOS_BRIDGE="$ROOT/host/ios/CanopyHostCore/CanopyHostCore-Bridging-Header.h"
fail=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✗ %s\033[0m\n' "$*" >&2; fail=1; }
has() { grep -qF "$2" "$1" 2>/dev/null; }

for f in "$AND_FLOOR" "$AND_ACT" "$IOS_FLOOR" "$IOS_APP" "$IOS_BRIDGE"; do
  [ -f "$f" ] || bad "missing crash-floor source: ${f#$ROOT/}"
done
[ "$fail" -eq 0 ] || { echo; echo "crash-floor check FAILED (sources moved)." >&2; exit "$fail"; }

# ---- Android (JVM uncaught handler) ----
echo "==> [1/3] Android JVM crash floor (CanopyCrashFloor.java + MainActivity)"
has "$AND_ACT"   "CanopyCrashFloor.install(this"        && ok "MainActivity.onCreate installs the crash floor"        || bad "MainActivity does not call CanopyCrashFloor.install(this, …)"
has "$AND_ACT"   "CanopyCrashFloor.drainPending(this"   && ok "MainActivity drains prior-run crash records"           || bad "MainActivity does not call CanopyCrashFloor.drainPending(this)"
has "$AND_FLOOR" "setDefaultUncaughtExceptionHandler"   && ok "floor sets a JVM uncaught handler"                     || bad "CanopyCrashFloor does not set a Thread uncaught handler"
has "$AND_FLOOR" "getDefaultUncaughtExceptionHandler"   && ok "floor captures the PRIOR default handler"              || bad "CanopyCrashFloor does not capture the prior default handler (cannot chain)"
has "$AND_FLOOR" "prior.uncaughtException"              && ok "floor CHAINS the prior handler (never swallows)"       || bad "CanopyCrashFloor does not chain prior.uncaughtException (a swallowed crash would hang)"
has "$AND_FLOOR" 'buildId'                              && ok "record carries the buildId (REL-4 crash-free key)"     || bad "Android crash record missing buildId"
has "$AND_FLOOR" 'jvm-uncaught'                         && ok "record kind = jvm-uncaught"                            || bad "Android crash record missing kind=jvm-uncaught"
{ grep -qF 'platform' "$AND_FLOOR" && grep -qF 'android' "$AND_FLOOR"; } && ok "record is keyed platform=android" || bad "Android crash record missing platform=android"

# ---- iOS (NSException handler) ----
echo "==> [2/3] iOS NSException crash floor (CanopyCrashFloor.mm + AppDelegate + bridging header)"
has "$IOS_APP"    "CanopyCrashFloorInstall()"           && ok "AppDelegate installs the crash floor at launch"        || bad "AppDelegate does not call CanopyCrashFloorInstall()"
has "$IOS_APP"    "CanopyCrashFloorDrainPending()"      && ok "AppDelegate drains prior-run crash records"            || bad "AppDelegate does not call CanopyCrashFloorDrainPending()"
has "$IOS_BRIDGE" "Boot/CanopyCrashFloor.h"             && ok "bridging header exposes the floor to Swift"            || bad "bridging header does not import Boot/CanopyCrashFloor.h"
has "$IOS_FLOOR"  "NSGetUncaughtExceptionHandler"       && ok "floor captures the PRIOR uncaught handler"             || bad "CanopyCrashFloor.mm does not capture the prior handler (cannot chain)"
has "$IOS_FLOOR"  "NSSetUncaughtExceptionHandler"       && ok "floor sets the process uncaught handler"               || bad "CanopyCrashFloor.mm does not set NSSetUncaughtExceptionHandler"
has "$IOS_FLOOR"  "gCanopyPriorHandler(e)"              && ok "floor CHAINS the prior handler (never swallows)"       || bad "CanopyCrashFloor.mm does not chain the prior handler"
has "$IOS_FLOOR"  'nsexception'                         && ok "record kind = nsexception"                             || bad "iOS crash record missing kind=nsexception"
grep -qF 'platform' "$IOS_FLOOR" && grep -qF '"ios"' "$IOS_FLOOR" && ok "record is keyed platform=ios" || bad "iOS crash record missing platform=ios"
has "$IOS_FLOOR"  'buildId'                             && ok "record carries the buildId (REL-4 crash-free key)"     || bad "iOS crash record missing buildId"

# ---- cross-platform parity ----
echo "==> [3/3] both floors agree on the record schema (REL-4 / TEL-1 consume it per buildId)"
for k in buildId platform kind fatal; do
  if grep -qF "$k" "$AND_FLOOR" && grep -qF "$k" "$IOS_FLOOR"; then ok "both records carry '$k'"; else bad "record key '$k' is not present on both platforms"; fi
done

# ---- SIG: native hard-crash floor (implemented, off by default, device-free-verified) ----
echo "==> [SIG] native signal floor (CanopySignalFloor) — implemented + opt-in + tested"
SIG_CPP="$ROOT/host/shared/cpp/CanopySignalFloor.cpp"
SIG_TEST="$ROOT/host/shared/cpp/tools/signalfloor-test.cpp"
CMAKE="$ROOT/host/android/app/src/main/cpp/CMakeLists.txt"
IOS_PROJ="$ROOT/host/ios/project.yml"
JNI="$ROOT/host/android/app/src/main/jni/CanopyHostJni.cpp"
[ -f "$SIG_CPP" ] && ok "CanopySignalFloor.cpp present" || bad "CanopySignalFloor.cpp missing"
[ -f "$SIG_TEST" ] && ok "signalfloor-test.cpp present (device-free fault-test; run in ci-test.sh)" || bad "signalfloor-test.cpp missing"
has "$SIG_CPP" "sigaltstack"           && ok "handler runs on an alternate stack (stack-overflow-safe)"  || bad "no sigaltstack (stack-overflow SIGSEGV would not record)"
has "$SIG_CPP" "raise(sig)"            && ok "handler re-raises -> CHAINS (never swallows the crash)"     || bad "signal floor does not re-raise/chain"
has "$CMAKE"   "CanopySignalFloor.cpp" && ok "Android build compiles the signal floor"                   || bad "CanopySignalFloor.cpp not in the Android CMake sources"
has "$IOS_PROJ" "CanopySignalFloor.cpp" && ok "iOS build compiles the signal floor"                      || bad "CanopySignalFloor.cpp not in the iOS project.yml sources"
has "$JNI"     "installSignalFloor"    && ok "Android JNI exposes installSignalFloor"                     || bad "Android JNI missing installSignalFloor"
has "$AND_FLOOR" "CANOPY_SIGNAL_FLOOR" && ok "Android installs the signal floor OFF BY DEFAULT (opt-in)"  || bad "Android does not gate the signal floor on CANOPY_SIGNAL_FLOOR"
has "$IOS_FLOOR" "CANOPY_SIGNAL_FLOOR" && ok "iOS installs the signal floor OFF BY DEFAULT (opt-in)"      || bad "iOS does not gate the signal floor on CANOPY_SIGNAL_FLOOR"
{ has "$SIG_CPP" '\"kind\":\"signal\"' || grep -qF 'kind":"signal' "$SIG_CPP"; } && ok "signal record kind=signal (REL-4 schema)" || bad "signal record missing kind=signal"

echo
if [ "$fail" -eq 0 ]; then echo "crash-floor OK — both hosts record a buildId-keyed crash and chain the prior handler (JVM/NSException always-on; SIG opt-in + verified)."; else echo "crash-floor check FAILED." >&2; fi
exit "$fail"
