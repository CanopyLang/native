// RestoreColor.h — pure sRGB<->CIELAB conversion for the on-device colorize path (shared cpp + .mm).
//
// The colorize model is L (luma) -> ab (chroma): host computes L from the source, feeds L/100 in [0,1],
// the model returns ab in [0,1] (= (ab_real/110 + 1)/2), and the host recombines the KEPT L with the
// predicted ab into RGB. The Lab<->RGB math is kept HOST-SIDE (the sRGB pow/where curve fragments the
// ANE) — this header is that math, matching apps/lumen/ml/models/colorize.py exactly so training and
// inference agree. No platform deps; unit-tested round-trip by tools/colorconv-test.cpp.
#pragma once
#include <algorithm>
#include <cmath>

namespace canopy {

// D65 white point (matches colorize.py).
inline constexpr float kXn = 0.95047f, kYn = 1.0f, kZn = 1.08883f;

inline float srgbToLinear(float c) {
  return (c <= 0.04045f) ? (c / 12.92f) : std::pow((c + 0.055f) / 1.055f, 2.4f);
}
inline float linearToSrgb(float c) {
  c = std::min(std::max(c, 0.0f), 1.0f);
  return (c <= 0.0031308f) ? (12.92f * c) : (1.055f * std::pow(c, 1.0f / 2.4f) - 0.055f);
}
inline float labF(float t) {                 // forward nonlinearity
  const float d = 6.0f / 29.0f;
  return (t > d * d * d) ? std::cbrt(t) : (t / (3.0f * d * d) + 4.0f / 29.0f);
}
inline float labFinv(float t) {              // inverse nonlinearity
  const float d = 6.0f / 29.0f;
  return (t > d) ? (t * t * t) : (3.0f * d * d * (t - 4.0f / 29.0f));
}

// rgb in [0,1] -> L in [0,100], a/b ~[-110,110].
inline void rgbToLab(float r, float g, float b, float& L, float& a, float& bb) {
  const float rl = srgbToLinear(std::min(std::max(r, 0.0f), 1.0f));
  const float gl = srgbToLinear(std::min(std::max(g, 0.0f), 1.0f));
  const float bl = srgbToLinear(std::min(std::max(b, 0.0f), 1.0f));
  const float x = 0.4124f * rl + 0.3576f * gl + 0.1805f * bl;
  const float y = 0.2126f * rl + 0.7152f * gl + 0.0722f * bl;
  const float z = 0.0193f * rl + 0.1192f * gl + 0.9505f * bl;
  const float fx = labF(x / kXn), fy = labF(y / kYn), fz = labF(z / kZn);
  L = 116.0f * fy - 16.0f;
  a = 500.0f * (fx - fy);
  bb = 200.0f * (fy - fz);
}

// L in [0,100], a/b ~[-110,110] -> rgb in [0,1] (gamut-clamped).
inline void labToRgb(float L, float a, float bb, float& r, float& g, float& b) {
  const float fy = (L + 16.0f) / 116.0f;
  const float fx = fy + a / 500.0f;
  const float fz = fy - bb / 200.0f;
  const float x = labFinv(fx) * kXn, y = labFinv(fy) * kYn, z = labFinv(fz) * kZn;
  const float rl =  3.2406f * x - 1.5372f * y - 0.4986f * z;
  const float gl = -0.9689f * x + 1.8758f * y + 0.0415f * z;
  const float bl =  0.0557f * x - 0.2040f * y + 1.0570f * z;
  r = std::min(std::max(linearToSrgb(rl), 0.0f), 1.0f);
  g = std::min(std::max(linearToSrgb(gl), 0.0f), 1.0f);
  b = std::min(std::max(linearToSrgb(bl), 0.0f), 1.0f);
}

}  // namespace canopy
