// signalfloor-test.cpp — device-free proof of the native signal floor (CanopySignalFloor).
// For each hard signal: fork a child that installs the floor and raises the signal; the parent asserts
// (1) the child STILL DIED FROM THAT SIGNAL (the floor CHAINED — never swallowed the crash), and
// (2) a buildId-keyed record with the right schema/kind/signal was written. This exercises the exact
// async-signal-safe write + chain path the device would hit (minus the on-device sigaltstack realism).
//   c++ -std=c++17 -I host/shared/cpp host/shared/cpp/CanopySignalFloor.cpp host/shared/cpp/tools/signalfloor-test.cpp -o /tmp/sft && /tmp/sft
#include "CanopySignalFloor.h"

#include <cstdio>
#include <cstring>
#include <csignal>
#include <cstdlib>
#include <string>
#include <sys/wait.h>
#include <unistd.h>

using namespace canopy;

static int failures = 0;
static void fail(const std::string& m) { std::printf("  FAIL — %s\n", m.c_str()); ++failures; }

static std::string slurp(const std::string& p) {
  FILE* f = std::fopen(p.c_str(), "rb");
  if (!f) { return ""; }
  std::string s; char buf[1024]; size_t n;
  while ((n = std::fread(buf, 1, sizeof(buf), f)) > 0) { s.append(buf, n); }
  std::fclose(f);
  return s;
}

static void run_case(const char* dir, int sig, const char* name) {
  const std::string sid = std::string("sess-") + name;
  pid_t pid = fork();
  if (pid == 0) {
    // CHILD: install the floor, then raise the signal. The handler records + chains -> we die from `sig`.
    installSignalFloor(dir, "testbuild", sid.c_str(), "test", "ci");
    raise(sig);
    _exit(42);                       // unreachable if the floor chained correctly
  }
  int status = 0;
  waitpid(pid, &status, 0);
  // (1) chained: the child died FROM the signal, not swallowed (would have _exit(42)) and not hung.
  if (!WIFSIGNALED(status)) {
    fail(std::string(name) + ": child did not die from a signal (floor swallowed the crash!)");
  } else if (WTERMSIG(status) != sig) {
    fail(std::string(name) + ": child died from a DIFFERENT signal than raised");
  }
  // (2) recorded: the buildId-keyed record exists with the right fields.
  const std::string rec = slurp(std::string(dir) + "/signal-" + sid + ".json");
  if (rec.empty()) { fail(std::string(name) + ": no record written"); return; }
  if (rec.find("\"schema\":2") == std::string::npos) { fail(std::string(name) + ": record missing schema 2"); }
  if (rec.find("\"kind\":\"signal\"") == std::string::npos) { fail(std::string(name) + ": record missing kind=signal"); }
  if (rec.find(std::string("\"signal\":\"") + name + "\"") == std::string::npos) { fail(std::string(name) + ": record missing the signal name"); }
  if (rec.find("\"buildId\":\"testbuild\"") == std::string::npos) { fail(std::string(name) + ": record missing buildId"); }
  if (rec.find("\"fatal\":true") == std::string::npos) { fail(std::string(name) + ": record not marked fatal"); }
}

int main() {
  char dir[] = "/tmp/canopy-sigfloor-XXXXXX";
  if (!mkdtemp(dir)) { std::printf("could not mkdtemp\n"); return 1; }
  run_case(dir, SIGSEGV, "SIGSEGV");
  run_case(dir, SIGABRT, "SIGABRT");
  run_case(dir, SIGFPE, "SIGFPE");
  run_case(dir, SIGILL, "SIGILL");
  run_case(dir, SIGBUS, "SIGBUS");
  if (failures == 0) {
    std::printf("signalfloor-test OK — all 5 hard signals recorded a buildId-keyed breadcrumb AND chained "
                "(process still died from the signal; never swallowed).\n");
    return 0;
  }
  std::printf("signalfloor-test FAILED — %d.\n", failures);
  return 1;
}
