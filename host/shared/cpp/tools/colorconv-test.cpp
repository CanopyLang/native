// colorconv-test.cpp — device-free unit test for RestoreColor.h (sRGB<->CIELAB).
// Proves rgb -> lab -> rgb is near-identity across the cube (the colorize path keeps L and recombines
// predicted ab, so the conversion must round-trip), and that L/a/b land in their expected ranges.
//   c++ -std=c++17 -I host/shared/cpp host/shared/cpp/tools/colorconv-test.cpp -o /tmp/cct && /tmp/cct
#include "RestoreColor.h"

#include <cstdio>
#include <cmath>

using namespace canopy;

int main() {
  int fails = 0;
  float maxerr = 0.0f, maxL = 0.0f, minL = 1e9f, maxabs_ab = 0.0f;
  for (int ri = 0; ri <= 16; ++ri)
    for (int gi = 0; gi <= 16; ++gi)
      for (int bi = 0; bi <= 16; ++bi) {
        float r = ri / 16.0f, g = gi / 16.0f, b = bi / 16.0f;
        float L, a, bb; rgbToLab(r, g, b, L, a, bb);
        maxL = std::max(maxL, L); minL = std::min(minL, L);
        maxabs_ab = std::max(maxabs_ab, std::max(std::fabs(a), std::fabs(bb)));
        float r2, g2, b2; labToRgb(L, a, bb, r2, g2, b2);
        float e = std::max(std::fabs(r - r2), std::max(std::fabs(g - g2), std::fabs(b - b2)));
        if (e > maxerr) maxerr = e;
      }
  // round-trip must be tight (within ~1/255); L in [0,100]; ab within ~[-128,128].
  if (maxerr > 1.5f / 255.0f) { std::printf("  FAIL round-trip maxerr=%.5f (> 1.5/255)\n", maxerr); ++fails; }
  if (minL < -0.5f || maxL > 100.5f) { std::printf("  FAIL L out of [0,100]: [%.2f,%.2f]\n", minL, maxL); ++fails; }
  if (maxabs_ab > 140.0f) { std::printf("  FAIL |ab| too large: %.2f\n", maxabs_ab); ++fails; }
  // black + white sanity
  { float L,a,bb; rgbToLab(0,0,0,L,a,bb); if (std::fabs(L)>0.5f){std::printf("  FAIL black L=%.3f\n",L);++fails;} }
  { float L,a,bb; rgbToLab(1,1,1,L,a,bb); if (std::fabs(L-100.0f)>0.5f){std::printf("  FAIL white L=%.3f\n",L);++fails;} }
  if (fails == 0) {
    std::printf("colorconv-test OK — rgb<->lab round-trips (maxerr=%.5f), L in [%.1f,%.1f], |ab|<=%.1f.\n",
                maxerr, minL, maxL, maxabs_ab);
    return 0;
  }
  std::printf("colorconv-test FAILED — %d.\n", fails);
  return 1;
}
