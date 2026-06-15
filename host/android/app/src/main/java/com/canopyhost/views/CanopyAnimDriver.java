// CanopyAnimDriver.java — the host-side, Choreographer-driven Animation engine for canopy/native.
//
// Generalizes the BeforeAfter self-driving pattern: a SINGLE per-frame loop (one Choreographer
// FrameCallback for the whole host) advances N property animations on any view-by-handle, writing
// only compositor properties (translationX/Y, scaleX/Y, rotation, alpha) — NEVER dirtying Yoga.
// The TEA app only ever sees coarse animationStart/animationEnd edges; per-frame motion never
// round-trips through update. This is RN's useNativeDriver, host-side.
//
// IDEMPOTENCE (the load-bearing correctness property): the walker re-sends the `animations` prop
// on EVERY re-render of the carrying component (Encode.list allocates a fresh array and the
// plain-prop diff is reference-identity). So start() is called with an identical spec constantly.
// We dedupe by a per-(handle,prop) spec SIGNATURE: an identical spec is a no-op (the running or
// already-finished animation is left alone) — a real change re-seeds + restarts. Without this the
// animation would restart every frame the app happens to re-render → stall/stutter.
//
// THREADING: every public method is called on the UI/JS thread (from CanopyHost.applyProps /
// removeChild), and Choreographer.postFrameCallback fires doFrame on the same thread — so the
// `anims` map is single-threaded. Do NOT call into this driver from a background callback.

package com.canopyhost.views;

import android.view.Choreographer;
import android.view.View;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.Iterator;
import java.util.Map;

public final class CanopyAnimDriver implements Choreographer.FrameCallback {

  /** Host injects the event emit + view lookup so the driver has no back-dependency on CanopyHost. */
  public interface Emitter { void emit(int handle, String name, String payloadJson); }
  public interface ViewLookup { View viewFor(int handle); }

  // property ordinals (the compositor allowlist — exactly applyTransform's set + opacity)
  public static final int P_TRANSLATE_X = 0, P_TRANSLATE_Y = 1, P_SCALE = 2,
      P_SCALE_X = 3, P_SCALE_Y = 4, P_ROTATE = 5, P_OPACITY = 6;
  public static final int PROP_COUNT = 7;

  // easing ordinals
  static final int E_LINEAR = 0, E_EASE_IN = 1, E_EASE_OUT = 2, E_EASE_IN_OUT = 3;

  /** One animation on one (handle, prop). Reused across frames — never allocated in doFrame. */
  private static final class Anim {
    int handle, prop;
    View view;
    float from, to, current;
    boolean fromIsNaN, seededFrom;
    long startNanos, delayNanos, durationNanos;
    int easing;
    boolean isSpring;
    float stiffness, damping, mass, vel;
    boolean started, done;
    String sig;
  }

  private final Map<Long, Anim> anims = new HashMap<>();          // handle<<8|prop -> Anim
  private final Map<Integer, boolean[]> owned = new HashMap<>();  // handle -> [PROP_COUNT]
  private final Emitter emitter;
  private final ViewLookup lookup;
  private final float density;
  private boolean scheduled = false;
  private long lastFrameNanos = 0;

  public CanopyAnimDriver(Emitter emitter, ViewLookup lookup, float density) {
    this.emitter = emitter;
    this.lookup = lookup;
    this.density = density;
  }

  // ---- public API (UI/JS thread only) ---------------------------------------

  /**
   * Start (or, if the spec is unchanged, leave running) one property animation. from==NaN seeds
   * from the view's live value on the first stepped frame (interrupt-safe). Idempotent: an
   * identical spec for the same (handle,prop) is a no-op whether the prior run is in-flight or done.
   */
  public void start(int handle, View v, int prop,
                    float from, float to, long durationMs, long delayMs, int easing,
                    boolean isSpring, float stiffness, float damping, float mass) {
    long k = key(handle, prop);
    String sig = sig(from, to, durationMs, delayMs, easing, isSpring, stiffness, damping, mass);
    Anim a = anims.get(k);
    if (a != null && sig.equals(a.sig)) return;   // identical spec → no-op (idempotence)

    if (a == null) { a = new Anim(); anims.put(k, a); }
    a.handle = handle; a.prop = prop; a.view = v; a.sig = sig;
    a.fromIsNaN = Float.isNaN(from); a.from = from; a.to = to;
    a.durationNanos = Math.max(1L, durationMs) * 1_000_000L;
    a.delayNanos = Math.max(0L, delayMs) * 1_000_000L;
    a.easing = easing; a.isSpring = isSpring;
    a.stiffness = stiffness; a.damping = damping; a.mass = mass; a.vel = 0f;
    a.startNanos = 0; a.started = false; a.seededFrom = false; a.done = false;
    setOwned(handle, prop, true);
    schedule();
  }

  /** Cancel every animation on a handle (view removed / recycled / animations cleared). */
  public void cancelAll(int handle) {
    for (Iterator<Map.Entry<Long, Anim>> it = anims.entrySet().iterator(); it.hasNext();) {
      if ((int) (it.next().getKey() >> 8) == handle) it.remove();
    }
    owned.remove(handle);
  }

  /** True if the driver currently owns this style key for this handle (transform = any transform
   * sub-prop). applyStyle/resetStyleKey skip their write when the driver owns the property. */
  public boolean isOwned(int handle, String styleKey) {
    boolean[] o = owned.get(handle);
    if (o == null) return false;
    if ("opacity".equals(styleKey)) return o[P_OPACITY];
    if ("transform".equals(styleKey)) {
      return o[P_TRANSLATE_X] || o[P_TRANSLATE_Y] || o[P_SCALE] || o[P_SCALE_X] || o[P_SCALE_Y] || o[P_ROTATE];
    }
    return false;
  }

  /** Which props in `present` are NOT in the new spec → cancel them (drop owned, remove anim). */
  public void cancelMissing(int handle, boolean[] present) {
    for (int p = 0; p < PROP_COUNT; p++) {
      if (!present[p]) {
        anims.remove(key(handle, p));
        boolean[] o = owned.get(handle);
        if (o != null) o[p] = false;
      }
    }
  }

  // ---- the frame loop -------------------------------------------------------

  @Override public void doFrame(long frameTimeNanos) {
    scheduled = false;
    long dtN = (lastFrameNanos == 0) ? 16_666_667L : (frameTimeNanos - lastFrameNanos);
    lastFrameNanos = frameTimeNanos;
    float dt = Math.min(dtN / 1e9f, 1f / 30f);   // clamp for spring stability on dropped frames

    ArrayList<long[]> finished = null;
    boolean anyLive = false;
    for (Map.Entry<Long, Anim> e : anims.entrySet()) {
      Anim a = e.getValue();
      if (a.done) continue;
      View v = a.view;
      if (v == null) { v = lookup.viewFor(a.handle); a.view = v; }
      if (v == null) continue;                   // view gone; reaped by cancelAll on removeChild

      if (a.startNanos == 0) a.startNanos = frameTimeNanos + a.delayNanos;
      if (frameTimeNanos < a.startNanos) { anyLive = true; continue; } // still in delay

      if (a.fromIsNaN && !a.seededFrom) { a.from = readLive(v, a.prop); a.current = a.from; a.seededFrom = true; }
      else if (!a.seededFrom) { a.current = a.from; a.seededFrom = true; }
      if (!a.started) { a.started = true; emitter.emit(a.handle, "animationStart", payload(a.prop)); }

      boolean done;
      if (a.isSpring) {
        float pos = a.current, vel = a.vel;
        float accel = (-a.stiffness * (pos - a.to) - a.damping * vel) / a.mass;
        vel += accel * dt; pos += vel * dt;
        a.vel = vel; a.current = pos;
        done = Math.abs(pos - a.to) < 1e-3f && Math.abs(vel) < 5e-3f;
        if (done) a.current = a.to;
      } else {
        float t = clamp01((frameTimeNanos - a.startNanos) / (float) a.durationNanos);
        a.current = a.from + (a.to - a.from) * ease(a.easing, t);
        done = t >= 1f;
        if (done) a.current = a.to;
      }
      applyValue(v, a.prop, a.current);

      if (done) {
        a.done = true;
        if (finished == null) finished = new ArrayList<>();
        finished.add(new long[]{ a.handle, a.prop });
      } else {
        anyLive = true;
      }
    }

    if (finished != null) {
      for (long[] f : finished) {
        int h = (int) f[0], p = (int) f[1];
        boolean[] o = owned.get(h);
        if (o != null) o[p] = false;              // unmark so static style reclaims the prop
        emitter.emit(h, "animationEnd", payload(p));
      }
    }
    if (anyLive) schedule();
    else lastFrameNanos = 0;
  }

  // ---- value mapping (density ONLY for translate, matching applyTransform's dp()) -----------

  private void applyValue(View v, int prop, float value) {
    switch (prop) {
      case P_TRANSLATE_X: v.setTranslationX(value * density); break;
      case P_TRANSLATE_Y: v.setTranslationY(value * density); break;
      case P_SCALE:       v.setScaleX(value); v.setScaleY(value); break;
      case P_SCALE_X:     v.setScaleX(value); break;
      case P_SCALE_Y:     v.setScaleY(value); break;
      case P_ROTATE:      v.setRotation(value); break;
      case P_OPACITY:     v.setAlpha(value < 0 ? 0 : value > 1 ? 1 : value); break;
    }
  }

  private float readLive(View v, int prop) {
    switch (prop) {
      case P_TRANSLATE_X: return v.getTranslationX() / density;
      case P_TRANSLATE_Y: return v.getTranslationY() / density;
      case P_SCALE: case P_SCALE_X: return v.getScaleX();
      case P_SCALE_Y: return v.getScaleY();
      case P_ROTATE:  return v.getRotation();
      case P_OPACITY: return v.getAlpha();
    }
    return 0f;
  }

  private static float ease(int e, float t) {
    switch (e) {
      case E_EASE_IN:     return t * t;
      case E_EASE_OUT:    return 1f - (1f - t) * (1f - t);
      case E_EASE_IN_OUT: return t < 0.5f ? 2f * t * t : 1f - 2f * (1f - t) * (1f - t);
      default:            return t;
    }
  }

  // ---- helpers --------------------------------------------------------------

  private void schedule() {
    if (!scheduled) { scheduled = true; Choreographer.getInstance().postFrameCallback(this); }
  }

  private void setOwned(int handle, int prop, boolean on) {
    boolean[] o = owned.get(handle);
    if (o == null) { if (!on) return; o = new boolean[PROP_COUNT]; owned.put(handle, o); }
    o[prop] = on;
  }

  private static String sig(float from, float to, long dur, long delay, int easing,
                            boolean spring, float st, float dp, float m) {
    return (Float.isNaN(from) ? "n" : Float.toString(from)) + "/" + to + "/" + dur + "/" + delay
        + "/" + easing + "/" + (spring ? ("s" + st + "," + dp + "," + m) : "t");
  }

  private static long key(int handle, int prop) { return ((long) handle << 8) | (prop & 0xFF); }
  private static float clamp01(float t) { return t < 0 ? 0 : t > 1 ? 1 : t; }
  private static String payload(int prop) { return "{\"prop\":\"" + propName(prop) + "\"}"; }

  public static String propName(int p) {
    switch (p) {
      case P_TRANSLATE_X: return "translateX"; case P_TRANSLATE_Y: return "translateY";
      case P_SCALE: return "scale"; case P_SCALE_X: return "scaleX"; case P_SCALE_Y: return "scaleY";
      case P_ROTATE: return "rotate"; default: return "opacity";
    }
  }

  public static int propOrdinal(String name) {
    switch (name) {
      case "translateX": return P_TRANSLATE_X; case "translateY": return P_TRANSLATE_Y;
      case "scale": return P_SCALE; case "scaleX": return P_SCALE_X; case "scaleY": return P_SCALE_Y;
      case "rotate": return P_ROTATE; case "opacity": return P_OPACITY; default: return -1;
    }
  }

  public static int easingOrdinal(String kind) {
    switch (kind) {
      case "easeIn": return E_EASE_IN; case "easeOut": return E_EASE_OUT;
      case "easeInOut": return E_EASE_IN_OUT; default: return E_LINEAR;
    }
  }
}
