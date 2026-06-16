// CanopyBeforeAfterMath.java — the Android mirror of host/shared/cpp/CanopyBeforeAfter.h: the pure,
// platform-neutral MATH of the C2 before/after wipe compositor.
//
// The before/after wipe is a hand-written native view on BOTH platforms — BeforeAfterView.java here,
// CanopyBeforeAfterView (iOS, in CanopyHostFabric.mm) there. They implement the SAME interaction by
// hand, so they WILL drift (master-plan Risk R5 — the same risk the IOS-9 layout-vector suite catches).
// The pieces that can silently diverge are the small PURE numeric rules that decide what gets drawn
// and what crosses back into Canopy: the wipe clamp, the clip-column round, the finger→fraction map,
// the double-tap snap target, the snap-tween easing, the center-crop cover rect, and the EXACT bytes
// of the wipeCommit payload.
//
// The iOS view delegates every one of those to the C++ header canopy::beforeafter::*. This Java class
// is the LINE-FOR-LINE Android twin of that header (same formulas, same branch order, same %g payload
// formatting via Locale.ROOT "%g") and BeforeAfterView.java delegates to it, so the two hosts call ONE
// source of truth and cannot drift. The shared corpus host/shared/test-vectors/beforeafter-vectors.json
// asserts this class on an emulator (CanopyBeforeAfterMathTest, JVM-fast) and the same corpus asserts
// the C++ header on a Simulator (CanopyBeforeAfterVectorTests.mm); scripts/check-beforeafter-parity.sh
// ties this class to the header so the two cannot diverge unnoticed.
//
// Pure (no android.* imports beyond Locale): a JVM unit test exercises it with no emulator.

package com.canopyhost.views;

import java.util.Locale;

/** The platform-neutral wipe-compositor math; the Android twin of host/shared/cpp/CanopyBeforeAfter.h. */
public final class CanopyBeforeAfterMath {

  private CanopyBeforeAfterMath() {}

  /** The decelerate snap-tween duration, in seconds (ValueAnimator 260ms; iOS CADisplayLink 0.26s). */
  public static final double SNAP_DURATION_SECONDS = 0.26;

  /** Clamp a wipe fraction to [0,1] (== Native.BeforeAfter.clamp01 and canopy::beforeafter::clampFraction). */
  public static double clampFraction(double f) {
    if (f < 0.0) return 0.0;
    if (f > 1.0) return 1.0;
    return f;
  }

  /** Float overload for the view's float wipe state. */
  public static float clampFraction(float f) {
    return (float) clampFraction((double) f);
  }

  /**
   * The clip/mask boundary column for a wipe over a view {@code width} units wide: round(clamp(wipe)*width).
   * Android: canvas.clipRect(0,0,splitX,h); iOS: the CALayer mask is splitX wide. Math.round rounds half
   * UP (toward +Infinity), which equals std::lround's round-half-away-from-zero for the non-negative
   * products here (wipe and width are both >= 0 after clamping).
   */
  public static int splitColumn(double wipe, double width) {
    return (int) Math.round(clampFraction(wipe) * width);
  }

  /** Map a raw finger x (relative to the view's left edge) to a wipe fraction: clamp01(x/width). */
  public static double dragFraction(double x, double width) {
    if (width <= 0.0) return 0.0;
    return clampFraction(x / width);
  }

  /** The end a double-tap snaps toward from {@code wipe}: (wipe >= 0.5) ? 0 : 1. */
  public static double snapTarget(double wipe) {
    return (wipe >= 0.5) ? 0.0 : 1.0;
  }

  /** The decelerate easing of the snap tween at progress t in [0,1]: 1-(1-t)^2 (DecelerateInterpolator). */
  public static double snapEased(double t) {
    if (t < 0.0) t = 0.0;
    if (t > 1.0) t = 1.0;
    double inv = 1.0 - t;
    return 1.0 - inv * inv;
  }

  /** The wipe value of an in-flight snap from {@code from} to {@code to} after {@code elapsedSeconds}. */
  public static double snapValue(double from, double to, double elapsedSeconds, double durationSeconds) {
    double t = (durationSeconds > 0.0) ? (elapsedSeconds / durationSeconds) : 1.0;
    double eased = snapEased(t);
    return from + (to - from) * eased;
  }

  /** The center-crop "cover" dst rect to draw a bmp over a box (twin of BeforeAfterView.drawCover). */
  public static float[] coverRect(double viewW, double viewH, double bmpW, double bmpH) {
    if (viewW <= 0.0 || viewH <= 0.0 || bmpW <= 0.0 || bmpH <= 0.0) {
      return new float[] {0f, 0f, 0f, 0f};
    }
    double scale = Math.max(viewW / bmpW, viewH / bmpH);
    double dw = bmpW * scale;
    double dh = bmpH * scale;
    double left = (viewW - dw) * 0.5;
    double top = (viewH - dh) * 0.5;
    return new float[] {(float) left, (float) top, (float) dw, (float) dh};
  }

  /**
   * The canonical wipeCommit payload bytes: {"fraction":&lt;v&gt;}. ONE formatter so the SAME committed
   * wipe emits the SAME bytes on both hosts (closing the old Java-Float.toString vs C-printf-%g drift).
   * Java's Locale.ROOT "%g" matches C's %g default (6 significant digits); like %g it does NOT strip
   * trailing zeros, so we strip them to match the C++ header's snprintf("%g") output exactly.
   */
  public static String commitPayloadJson(double fraction) {
    double v = clampFraction(fraction);
    String g = formatG(v);
    return "{\"fraction\":" + g + "}";
  }

  /** Reproduce C printf %g (6 sig-figs, trailing zeros + dangling point stripped) for the fractions here. */
  static String formatG(double v) {
    if (v == 0.0) return "0";
    // Java "%g" keeps trailing zeros (e.g. "0.500000"); C's %g strips them. Format then strip.
    String s = String.format(Locale.ROOT, "%g", v);
    if (s.indexOf('.') >= 0 && s.indexOf('e') < 0 && s.indexOf('E') < 0) {
      s = s.replaceAll("0+$", "");
      if (s.endsWith(".")) s = s.substring(0, s.length() - 1);
    }
    return s;
  }
}
