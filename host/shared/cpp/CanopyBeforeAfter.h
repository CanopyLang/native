// CanopyBeforeAfter.h — the portable, platform-neutral MATH of the C2 before/after wipe compositor.
//
// The before/after wipe is a hand-written native view on BOTH platforms — BeforeAfterView.java
// (Android, android.graphics.Canvas) and CanopyBeforeAfterView (iOS, two UIImageViews + a CALayer
// mask in CanopyHostFabric.mm). They implement the SAME interaction by hand, so they WILL drift
// (master-plan Risk R5 — the same risk the IOS-9 layout-vector suite exists to catch). The pieces
// that can silently diverge are not the platform draw calls; they are the small PURE numeric rules
// that decide what gets drawn and what crosses back into Canopy:
//
//   • clampFraction   — the 0..1 clamp on the controlled wipe (must match Native.BeforeAfter.clamp01).
//   • splitColumn     — round(wipe * width): the clip/mask boundary column. Android clips the AFTER
//                       layer to [0..splitColumn]; iOS sizes the CALayer mask to splitColumn wide.
//                       An off-by-one here is a 1px seam mismatch between the two hosts.
//   • dragFraction    — clamp01(x / width): a raw finger x mapped to the wipe (the "drag the seam"
//                       feel). Both hosts must map an identical touch to an identical fraction.
//   • snapTarget      — (wipe >= 0.5) ? 0 : 1: which end a double-tap snaps to.
//   • snapEased       — 1 - (1-t)^2: the decelerate easing of the snap tween (Android ValueAnimator
//                       DecelerateInterpolator; iOS CADisplayLink), sampled at progress t in [0..1].
//   • snapValue       — the eased value at an elapsed time over the snap duration (260ms on both).
//   • coverRect       — the center-crop "cover" geometry: the dst rect to draw a bitmap so it covers
//                       a box preserving aspect (Android drawCover; iOS UIViewContentModeScaleAspectFill).
//                       If the two hosts crop differently the two layers do not register pixel-for-pixel.
//   • commitPayloadJson — the EXACT {"fraction":<v>} JSON the wipeCommit event carries. The two hosts
//                       previously formatted the float differently (Java Float.toString vs printf %g),
//                       so the SAME drag emitted DIFFERENT wire bytes — the precise silent drift this
//                       header removes by giving both hosts one formatter.
//
// This header is the SINGLE SOURCE OF TRUTH for those rules: both hosts call it, so they cannot drift,
// and the shared test-vector corpus (host/shared/test-vectors/beforeafter-vectors.json) asserts it on
// Linux (validate-beforeafter.js), on a Simulator (CanopyBeforeAfterVectorTests.mm) and on an emulator
// (CanopyBeforeAfterVectorTest, via JNI). It is header-only and depends on NOTHING platform-specific
// (just <cmath>/<string>), exactly like CanopyImage.h, so the iOS host reuses it verbatim and
// check-portable-cpp.sh compiles it on Linux.
//
// Units are deliberately platform-NEUTRAL: lengths are in the host's own draw units (PHYSICAL PIXELS
// on Android — the view's getWidth(); POINTS on iOS — the bounds width). The math is unit-agnostic
// (a clamp, a ratio, a center-crop), so the SAME inputs in EITHER unit produce the SAME normalized
// fraction and the SAME relative rect — there is no density term here at all (the wipe is a fraction
// of the view, never a dp). That is why one corpus, in unitless fractions + a single nominal width,
// validates both hosts.

#pragma once

#include <cmath>
#include <cstdio>
#include <string>

namespace canopy {
namespace beforeafter {

// A drawn rectangle (the dst of a bitmap blit), in the host's draw units. left/top may be negative
// when the cover crop overflows the box (the standard center-crop overflow).
struct CoverRect {
  float left;
  float top;
  float width;
  float height;
};

// The decelerate snap-tween duration, in seconds. Android: ValueAnimator.setDuration(260) ms;
// iOS: the CADisplayLink tween divides elapsed by 0.26 s. ONE constant so both stay identical.
inline double snapDurationSeconds() { return 0.26; }

// Clamp a controlled/derived wipe fraction to [0,1]. The exact twin of Native.BeforeAfter.clamp01
// and each host's local clamp. Branch order matches the .can (low test first) so a NaN, which fails
// both comparisons, falls through to the input — callers pass a sanitized value.
inline double clampFraction(double f) {
  if (f < 0.0) return 0.0;
  if (f > 1.0) return 1.0;
  return f;
}

// The clip/mask boundary column for a wipe at `wipe` over a view `width` units wide: round(wipe*width).
// Android: canvas.clipRect(0,0,splitX,h) (Math.round); iOS: the CALayer mask is roundf(_wipe*w) wide.
// roundf/Math.round both round half away from zero for non-negatives, so this matches both. `wipe` is
// clamped first so the column is always within [0..width].
inline int splitColumn(double wipe, double width) {
  double clamped = clampFraction(wipe);
  return (int)std::lround(clamped * width);
}

// Map a raw finger x (in the host's draw units, relative to the view's left edge) to a wipe fraction:
// clamp01(x / width). The "drag the seam to the finger" mapping both hosts apply per touch sample.
// width <= 0 is degenerate (a not-yet-laid-out view); both hosts early-out of the drag, so we report
// 0 (the clamp of x/eps would saturate anyway) — callers gate on width > 0 before drawing.
inline double dragFraction(double x, double width) {
  if (width <= 0.0) return 0.0;
  return clampFraction(x / width);
}

// The end a double-tap snaps toward from the current `wipe`: if the seam is at/over the middle, snap
// open to the left (0); otherwise snap closed to the right (1). Twin of the `(wipe >= 0.5) ? 0 : 1`
// in both hosts.
inline double snapTarget(double wipe) {
  return (wipe >= 0.5) ? 0.0 : 1.0;
}

// The decelerate easing applied to the snap tween: ease-out-quad 1 - (1-t)^2 over progress t in [0,1].
// Android's DecelerateInterpolator(factor 1.0) is exactly 1-(1-t)^2; iOS's CADisplayLink tween uses
// the same closed form. t is clamped so an over-/under-run frame still produces a value in [0,1].
inline double snapEased(double t) {
  if (t < 0.0) t = 0.0;
  if (t > 1.0) t = 1.0;
  double inv = 1.0 - t;
  return 1.0 - inv * inv;
}

// The wipe value of an in-flight snap from `from` to `to` after `elapsedSeconds` of a tween of
// `durationSeconds` (defaults to snapDurationSeconds()). t = elapsed/duration is eased by snapEased
// and lerped from->to. At elapsed >= duration this returns exactly `to` (t saturates to 1, eased to 1).
inline double snapValue(double from, double to, double elapsedSeconds,
                        double durationSeconds = snapDurationSeconds()) {
  double t = (durationSeconds > 0.0) ? (elapsedSeconds / durationSeconds) : 1.0;
  double eased = snapEased(t);
  return from + (to - from) * eased;
}

// The center-crop "cover" dst rect to draw a `bmpW x bmpH` bitmap over a `viewW x viewH` box,
// preserving aspect by scaling to the MAX ratio and centering (overflow is cropped by the view's
// clip). Twin of BeforeAfterView.drawCover and UIViewContentModeScaleAspectFill. Degenerate inputs
// (any non-positive dimension) yield a zero rect at the origin — both hosts skip the draw in that
// case (Android: `if (bw<=0||bh<=0) return;`; iOS: a nil image draws nothing).
inline CoverRect coverRect(double viewW, double viewH, double bmpW, double bmpH) {
  if (viewW <= 0.0 || viewH <= 0.0 || bmpW <= 0.0 || bmpH <= 0.0) {
    return CoverRect{0.0f, 0.0f, 0.0f, 0.0f};
  }
  double scale = std::fmax(viewW / bmpW, viewH / bmpH);
  double dw = bmpW * scale;
  double dh = bmpH * scale;
  double left = (viewW - dw) * 0.5;
  double top = (viewH - dh) * 0.5;
  return CoverRect{(float)left, (float)top, (float)dw, (float)dh};
}

// Render a fraction into the canonical wipeCommit payload bytes: {"fraction":<v>}. ONE formatter so
// the SAME committed wipe emits the SAME bytes on both hosts (closing the Java-toString vs printf-%g
// drift). %g matches the iOS host's existing stringWithFormat:@"%g"; the value is clamped first so a
// stray out-of-range input never escapes into the payload. Trailing-zero-free, shortest round-trip
// form (e.g. 0.5, 1, 0.333333) — both host runners parse it back with their JSON decoder and compare.
inline std::string commitPayloadJson(double fraction) {
  double v = clampFraction(fraction);
  char buf[64];
  std::snprintf(buf, sizeof(buf), "{\"fraction\":%g}", v);
  return std::string(buf);
}

}  // namespace beforeafter
}  // namespace canopy
