// CanopyColor.java — a full CSS color parser for the host.
//
// android.graphics.Color.parseColor accepts only #RGB/#ARGB/#RRGGBB/#AARRGGBB + ~140 named
// colors and THROWS on rgb()/rgba()/hsl()/hsla() — exactly what canopy/css's Css.rgb/hsl emit
// — which the host swallowed to TRANSPARENT (silent invisible UI). This parses the full CSS
// color surface and is the canonical color parser the host uses everywhere.
//
// Hex is read in CSS order (#RRGGBB, #RRGGBBAA — alpha LAST), so values stay byte-identical
// between web and native (the Native.Css bridge no longer reorders alpha).

package com.canopyhost.views;

import android.graphics.Color;

import androidx.core.graphics.ColorUtils;

public final class CanopyColor {

  public static int parse(String s) {
    if (s == null) return Color.TRANSPARENT;
    s = s.trim();
    if (s.isEmpty() || s.equals("transparent") || s.equals("none")) return Color.TRANSPARENT;
    try {
      if (s.startsWith("#")) return parseHex(s.substring(1));
      String low = s.toLowerCase();
      if (low.startsWith("rgb")) return parseRgb(s);
      if (low.startsWith("hsl")) return parseHsl(s);
      return Color.parseColor(s); // named colors (Android knows ~140)
    } catch (Exception e) {
      return Color.TRANSPARENT;
    }
  }

  private static int parseHex(String h) {
    int r, g, b, a = 255;
    switch (h.length()) {
      case 3: r = hx(h, 0, 1) * 17; g = hx(h, 1, 2) * 17; b = hx(h, 2, 3) * 17; break;
      case 4: r = hx(h, 0, 1) * 17; g = hx(h, 1, 2) * 17; b = hx(h, 2, 3) * 17; a = hx(h, 3, 4) * 17; break;
      case 6: r = hx(h, 0, 2); g = hx(h, 2, 4); b = hx(h, 4, 6); break;
      case 8: r = hx(h, 0, 2); g = hx(h, 2, 4); b = hx(h, 4, 6); a = hx(h, 6, 8); break; // CSS #RRGGBBAA
      default: return Color.TRANSPARENT;
    }
    return Color.argb(a, r, g, b);
  }

  private static int parseRgb(String s) {
    String[] p = inner(s);
    int r = chan(p[0]), g = chan(p[1]), b = chan(p[2]);
    int a = p.length > 3 ? Math.round(alpha(p[3]) * 255f) : 255;
    return Color.argb(clamp(a), r, g, b);
  }

  private static int parseHsl(String s) {
    String[] p = inner(s);
    float h = Float.parseFloat(p[0].replace("deg", "").trim());
    float sat = pct(p[1]);
    float l = pct(p[2]);
    int a = p.length > 3 ? Math.round(alpha(p[3]) * 255f) : 255;
    int rgb = ColorUtils.HSLToColor(new float[]{ ((h % 360f) + 360f) % 360f, sat, l });
    return Color.argb(clamp(a), Color.red(rgb), Color.green(rgb), Color.blue(rgb));
  }

  // ---- helpers --------------------------------------------------------------

  private static String[] inner(String s) {
    String in = s.substring(s.indexOf('(') + 1, s.lastIndexOf(')'));
    return in.split("[,/\\s]+");
  }

  private static int hx(String s, int a, int b) { return Integer.parseInt(s.substring(a, b), 16); }

  /** An rgb() channel: "255" or "50%". */
  private static int chan(String t) {
    t = t.trim();
    if (t.endsWith("%")) return clamp(Math.round(Float.parseFloat(t.substring(0, t.length() - 1)) * 2.55f));
    return clamp(Math.round(Float.parseFloat(t)));
  }

  /** An alpha: "0.5" or "50%" → 0..1. */
  private static float alpha(String t) {
    t = t.trim();
    if (t.endsWith("%")) return Float.parseFloat(t.substring(0, t.length() - 1)) / 100f;
    return Float.parseFloat(t);
  }

  /** A percentage token "50%" → 0..1 (for HSL s/l). */
  private static float pct(String t) {
    t = t.trim();
    if (t.endsWith("%")) return Float.parseFloat(t.substring(0, t.length() - 1)) / 100f;
    return Float.parseFloat(t);
  }

  private static int clamp(int v) { return v < 0 ? 0 : (v > 255 ? 255 : v); }

  private CanopyColor() {}
}
