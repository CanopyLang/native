// CanopySignalFloor.cpp — see CanopySignalFloor.h. Portable POSIX (Android NDK + iOS/Darwin).
#include "CanopySignalFloor.h"

#include <atomic>
#include <cstdio>
#include <cstring>
#include <csignal>
#include <cstdlib>
#include <fcntl.h>
#include <unistd.h>

namespace canopy {
namespace {

// The hard native signals we record. (No SIGTRAP — debuggers/JITs use it.)
struct SigSlot { int sig; const char* name; };
constexpr SigSlot kSignals[] = {
    {SIGSEGV, "SIGSEGV"}, {SIGABRT, "SIGABRT"}, {SIGBUS, "SIGBUS"},
    {SIGILL, "SIGILL"}, {SIGFPE, "SIGFPE"},
};
constexpr int kN = static_cast<int>(sizeof(kSignals) / sizeof(kSignals[0]));

std::atomic<bool> gInstalled{false};
std::atomic<int> gCaught{0};
int gFd = -1;                          // pre-opened record fd (one per session)
struct sigaction gPrev[kN];            // prior dispositions, for chaining
char gRecord[kN][512];                 // FULLY pre-formatted JSON record per signal (built at install)
int gRecordLen[kN];
char gAltStack[65536];                 // fixed 64 KiB altstack (SIGSTKSZ isn't always a compile constant)

int slotForSignal(int sig) {
  for (int i = 0; i < kN; ++i) {
    if (kSignals[i].sig == sig) { return i; }
  }
  return -1;
}

// THE HANDLER. Async-signal-safe only: write() a pre-built buffer, fsync(), restore prior, re-raise.
void onSignal(int sig, siginfo_t* /*info*/, void* /*uctx*/) {
  const int i = slotForSignal(sig);
  if (i >= 0 && gFd >= 0) {
    // best-effort write of the pre-formatted record (write/fsync are async-signal-safe).
    ssize_t off = 0;
    while (off < gRecordLen[i]) {
      ssize_t n = write(gFd, gRecord[i] + off, static_cast<size_t>(gRecordLen[i] - off));
      if (n <= 0) { break; }
      off += n;
    }
    fsync(gFd);
    gCaught.fetch_add(1, std::memory_order_relaxed);
  }
  // CHAIN: restore the prior disposition and re-raise so the OS / a prior handler still runs. We never
  // swallow the crash. (raise() re-delivers synchronously to the now-restored handler/default.)
  if (i >= 0) {
    sigaction(sig, &gPrev[i], nullptr);
  }
  raise(sig);
}

}  // namespace

bool installSignalFloor(const char* recordDir, const char* buildId, const char* sessionId,
                        const char* platform, const char* source) {
  bool expected = false;
  if (!gInstalled.compare_exchange_strong(expected, true)) { return true; }  // idempotent
  if (recordDir == nullptr) { return false; }
  const char* bid = (buildId && *buildId) ? buildId : "unknown";
  const char* sid = (sessionId && *sessionId) ? sessionId : "unknown";
  const char* plat = (platform && *platform) ? platform : "native";
  const char* src = (source && *source) ? source : "unknown";

  // Pre-open the per-session record fd (so the handler does no path formatting). snprintf HERE is fine
  // (install runs in a normal context); it must NOT appear in the handler.
  char path[1024];
  std::snprintf(path, sizeof(path), "%s/signal-%s.json", recordDir, sid);
  gFd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (gFd < 0) { gInstalled.store(false); return false; }

  // Pre-format the FULL record line per signal (schema 2, kind "signal" — matches CanopyCrashFloor).
  for (int i = 0; i < kN; ++i) {
    gRecordLen[i] = std::snprintf(
        gRecord[i], sizeof(gRecord[i]),
        "{\"schema\":2,\"eventType\":\"crash\",\"kind\":\"signal\",\"platform\":\"%s\","
        "\"buildId\":\"%s\",\"sessionId\":\"%s\",\"source\":\"%s\",\"signal\":\"%s\",\"fatal\":true}\n",
        plat, bid, sid, src, kSignals[i].name);
    if (gRecordLen[i] < 0) { gRecordLen[i] = 0; }
    if (gRecordLen[i] > static_cast<int>(sizeof(gRecord[i]))) { gRecordLen[i] = sizeof(gRecord[i]); }
  }

  // Alternate stack so a stack-overflow SIGSEGV can still run the handler.
  stack_t ss;
  ss.ss_sp = gAltStack;
  ss.ss_size = sizeof(gAltStack);
  ss.ss_flags = 0;
  sigaltstack(&ss, nullptr);

  struct sigaction sa;
  std::memset(&sa, 0, sizeof(sa));
  sa.sa_sigaction = onSignal;
  sigemptyset(&sa.sa_mask);
  sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
  for (int i = 0; i < kN; ++i) {
    sigaction(kSignals[i].sig, &sa, &gPrev[i]);   // save prior for chaining
  }
  return true;
}

int signalFloorCaughtCount() { return gCaught.load(std::memory_order_relaxed); }

}  // namespace canopy
