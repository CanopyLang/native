// RestoreTiling.h — the pure, seamless tiling geometry shared by the RGB restore path and its test.
//
// The Core ML / ORT model takes a FIXED D-wide window. To restore an image larger than D without seams,
// we lay D-wide windows stepping by STEP = D - 2*over and CROP `over` px of context off each interior
// seam, so each window contributes a "central" span [cs,ce) whose union PARTITIONS the padded length
// [0,np) EXACTLY — no gaps (would leave holes), no double-writes (would seam). Edge windows keep their
// outer margin. n<=D ⇒ a single window (the short image is edge-clamped up to D, never downscaled).
// np>=n; the caller crops the stitched output back to n*scale. This file has NO platform deps so the
// Android (.cpp) and iOS (.mm) paths share one definition and tools/tilecover-test.cpp can prove it.
#pragma once
#include <vector>

namespace canopy {

struct Tile1D { int win; int cs; int ce; };  // window origin [win,win+D); central output span [cs,ce)

// Cover one axis of length `n` with D-wide windows; writes the padded length to `np`.
inline std::vector<Tile1D> tileCover(int n, int D, int over, int& np) {
  std::vector<Tile1D> tiles;
  if (D <= 0) { np = 0; return tiles; }
  if (over < 0) { over = 0; }
  if (over * 2 >= D) { over = (D - 1) / 2; }     // keep STEP = D-2*over >= 1
  const int step = D - 2 * over;
  int k = 1;
  if (n > D) { k = 1 + (n - D + step - 1) / step; }   // ceil((n-D)/step) extra windows
  np = D + (k - 1) * step;
  for (int i = 0; i < k; ++i) {
    const int win = i * step;
    const int cs = (i == 0) ? 0 : win + over;
    const int ce = (i == k - 1) ? np : win + D - over;
    tiles.push_back({win, cs, ce});
  }
  return tiles;
}

}  // namespace canopy
