// tilecover-test.cpp — device-free unit test for the seamless tiling geometry (RestoreTiling.h).
// Proves the property the stitched RGB restore depends on: for every (n, D, over) the windows' central
// spans PARTITION the padded length [0,np) exactly (no gaps → no holes, no overlaps → no seams), every
// window stays in [0, np-D], and each central span is fully inside its window. Build + run:
//   c++ -std=c++17 -I host/shared/cpp host/shared/cpp/tools/tilecover-test.cpp -o /tmp/tct && /tmp/tct
#include "RestoreTiling.h"

#include <cstdio>
#include <vector>

using canopy::Tile1D;
using canopy::tileCover;

static int failures = 0;
static void check(bool ok, const char* what, int n, int D, int over) {
  if (!ok) { std::printf("  FAIL n=%d D=%d over=%d: %s\n", n, D, over, what); ++failures; }
}

static void verify(int n, int D, int over) {
  int np = -1;
  std::vector<Tile1D> t = tileCover(n, D, over, np);
  check(!t.empty(), "no tiles", n, D, over);
  check(np >= n, "np < n (padded length must cover the image)", n, D, over);
  check(np >= D, "np < D", n, D, over);
  // partition + in-bounds
  check(t.front().cs == 0, "first central does not start at 0", n, D, over);
  check(t.back().ce == np, "last central does not end at np", n, D, over);
  for (size_t i = 0; i < t.size(); ++i) {
    const Tile1D& w = t[i];
    check(w.cs < w.ce, "empty/negative central span", n, D, over);
    check(w.win >= 0 && w.win + D <= np, "window out of [0,np-D]", n, D, over);
    check(w.cs >= w.win && w.ce <= w.win + D, "central span not inside its window", n, D, over);
    if (i + 1 < t.size()) {
      check(t[i].ce == t[i + 1].cs, "gap/overlap between adjacent centrals", n, D, over);
    }
  }
}

int main() {
  const int Ds[] = {64, 128, 224, 512};
  const int overs[] = {0, 1, 16, 32};
  for (int D : Ds) {
    for (int over : overs) {
      for (int n = 1; n <= 4096; ++n) {     // every image length up to 4k px on the axis
        verify(n, D, over);
      }
      // a couple of awkward exact-boundary sizes
      verify(D, D, over);
      verify(D + 1, D, over);
      verify(D * 7, D, over);
    }
  }
  // over too large is clamped, not UB
  verify(1000, 512, 9999);
  if (failures == 0) {
    std::printf("tilecover-test OK — centrals partition [0,np) for all (n<=4096, D, over); windows in-bounds.\n");
    return 0;
  }
  std::printf("tilecover-test FAILED — %d assertion(s).\n", failures);
  return 1;
}
