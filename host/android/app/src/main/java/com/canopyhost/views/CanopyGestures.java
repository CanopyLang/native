// CanopyGestures.java — the C3 gesture installer for the generic Native.Events family.
//
// Backs Native.Events.onPan / onPanStart / onPanEnd / onTap / onDoubleTap. Where the host's
// CanopyHost.setEvents handles the simple "press" click, gesture events need a real
// android.view.GestureDetector + a VelocityTracker, so that logic lives here (one NEW file)
// and CanopyHost.setEvents just calls CanopyGestures.install(...) when the requested event
// set contains a gesture name. Keeping it here means the only edit to the shared CanopyHost
// is the one-line dispatch in the integration manifest.
//
// WHAT IT DOES (mirrors the GestureDetector idioms the platform already ships):
//   • onScroll        → "pan" (every frame) + "panStart" (first confirmed scroll). Emits the
//                       cumulative translation from the gesture's start, IN DP (physical-px
//                       delta / display density) so it lines up with Native.Attributes' dp
//                       layout values.
//   • ACTION_UP/fling → "panEnd" with the VelocityTracker fling velocity (dp/s) in vx/vy.
//   • onSingleTapConfirmed → "tap"  (payload {})
//   • onDoubleTap          → "doubleTap" (payload {})
//   • requestDisallowInterceptTouchEvent(true) once the drag is confirmed along its dominant
//     axis, so a parent scroll container does not steal the pan (axis bias).
//
// PAYLOAD WIRE SHAPE (read by Native.Events.panDecoder):
//   {"dx":<dp>,"dy":<dp>,"vx":<dp/s>,"vy":<dp/s>}
//
// The names array is the JSON the walker sends to setEvents (e.g. ["pan","panEnd","press"]);
// we sniff it with contains(...) exactly like the existing "press" check. install() is
// idempotent per view: it replaces any prior touch listener it set.

package com.canopyhost.views;

import android.content.Context;
import android.view.GestureDetector;
import android.view.MotionEvent;
import android.view.ScaleGestureDetector;
import android.view.VelocityTracker;
import android.view.View;
import android.view.ViewParent;

import com.canopyhost.CanopyHostJni;

/** Installs a GestureDetector + ScaleGestureDetector + VelocityTracker that emit the
 * Native.Events gesture family: pan/tap/doubleTap/longPress/pinch. */
public final class CanopyGestures {

  /**
   * Wire the requested gesture families on {@code view}, emitting to the Canopy node {@code
   * handle}. The want* flags (derived from the setEvents names array) say which families to emit.
   * {@code density} converts physical-pixel deltas to dp. Safe to call repeatedly for the view.
   */
  public static void install(Context ctx, View view, int handle, float density,
                             boolean wantPan, boolean wantTap, boolean wantDouble,
                             boolean wantLong, boolean wantPinch, boolean wantPress) {
    Handler h = new Handler(view, handle, density, wantPan, wantTap, wantDouble, wantLong, wantPinch, wantPress);
    GestureDetector detector = new GestureDetector(ctx, h);
    detector.setOnDoubleTapListener(h);
    detector.setIsLongpressEnabled(wantLong);
    h.detector = detector;
    if (wantPinch) h.scaleDetector = new ScaleGestureDetector(ctx, h);
    view.setClickable(true);
    view.setOnTouchListener(h);
  }

  private CanopyGestures() {}

  // The single object that is GestureDetector listener + OnTouchListener for one view.
  private static final class Handler extends GestureDetector.SimpleOnGestureListener
      implements View.OnTouchListener, GestureDetector.OnDoubleTapListener,
                 ScaleGestureDetector.OnScaleGestureListener {

    private final View view;
    private final int handle;
    private final float density;
    private final boolean wantPan, wantTap, wantDouble, wantLong, wantPinch, wantPress;

    GestureDetector detector;
    ScaleGestureDetector scaleDetector;
    private VelocityTracker velocity;
    private boolean dragging;
    private boolean axisLocked;       // once true, the dominant axis is decided
    private boolean horizontal;       // the locked axis (only meaningful if axisLocked)
    private boolean pinching;         // a pinch is in progress (suppresses pan)
    private float pinchScale = 1f;    // cumulative scale from the pinch start
    private float startX, startY;     // gesture origin (physical px)

    Handler(View view, int handle, float density,
            boolean wantPan, boolean wantTap, boolean wantDouble, boolean wantLong, boolean wantPinch, boolean wantPress) {
      this.view = view;
      this.handle = handle;
      this.density = density;
      this.wantPan = wantPan;
      this.wantTap = wantTap;
      this.wantDouble = wantDouble;
      this.wantLong = wantLong;
      this.wantPinch = wantPinch;
      this.wantPress = wantPress;
    }

    @Override
    public boolean onTouch(View v, MotionEvent ev) {
      if (velocity == null) { velocity = VelocityTracker.obtain(); }
      velocity.addMovement(ev);
      if (scaleDetector != null) scaleDetector.onTouchEvent(ev);
      boolean handled = detector.onTouchEvent(ev);

      switch (ev.getActionMasked()) {
        case MotionEvent.ACTION_DOWN:
          startX = ev.getX();
          startY = ev.getY();
          dragging = false;
          axisLocked = false;
          return true;
        case MotionEvent.ACTION_UP:
        case MotionEvent.ACTION_CANCEL:
          if (dragging && wantPan) {
            velocity.computeCurrentVelocity(1000); // px/s
            float vx = velocity.getXVelocity() / density;
            float vy = velocity.getYVelocity() / density;
            emit("panEnd", (ev.getX() - startX) / density, (ev.getY() - startY) / density, vx, vy);
          }
          releaseParent();
          dragging = false;
          if (velocity != null) { velocity.recycle(); velocity = null; }
          break;
        default:
          break;
      }
      return handled || true;
    }

    @Override public boolean onDown(MotionEvent e) { return true; }

    @Override
    public boolean onScroll(MotionEvent e1, MotionEvent e2, float dX, float dY) {
      if (!wantPan || pinching) { return false; }
      float totalX = e2.getX() - startX;
      float totalY = e2.getY() - startY;

      if (!axisLocked) {
        // Decide the dominant axis once past slop, then claim the touch stream for it.
        if (Math.abs(totalX) < 1f && Math.abs(totalY) < 1f) { return false; }
        axisLocked = true;
        horizontal = Math.abs(totalX) >= Math.abs(totalY);
        claimParent();              // requestDisallowInterceptTouchEvent(true)
        dragging = true;
        emit("panStart", totalX / density, totalY / density, 0f, 0f);
      }
      emit("pan", totalX / density, totalY / density, 0f, 0f);
      return true;
    }

    @Override
    public boolean onSingleTapConfirmed(MotionEvent e) {
      // The touch listener consumes the stream, so the separate OnClickListener never fires —
      // route a confirmed tap to "press" too when the view wanted it (press + gestures coexist).
      boolean did = false;
      if (wantPress) { CanopyHostJni.emitEvent(handle, "press", "{}"); did = true; }
      if (wantTap) { CanopyHostJni.emitEvent(handle, "tap", "{}"); did = true; }
      return did;
    }

    @Override
    public boolean onDoubleTap(MotionEvent e) {
      if (wantDouble) { CanopyHostJni.emitEvent(handle, "doubleTap", "{}"); return true; }
      return false;
    }

    @Override public boolean onDoubleTapEvent(MotionEvent e) { return false; }

    @Override
    public void onLongPress(MotionEvent e) {
      if (wantLong) {
        CanopyHostJni.emitEvent(handle, "longPress",
            "{\"x\":" + (e.getX() / density) + ",\"y\":" + (e.getY() / density) + "}");
      }
    }

    // ---- pinch (ScaleGestureDetector) ----------------------------------------

    @Override
    public boolean onScaleBegin(ScaleGestureDetector d) {
      pinching = true;
      pinchScale = 1f;
      claimParent();
      emitScale("pinchStart", d);
      return true;
    }

    @Override
    public boolean onScale(ScaleGestureDetector d) {
      pinchScale *= d.getScaleFactor();   // cumulative scale from the gesture start (RN semantics)
      emitScale("pinch", d);
      return true;
    }

    @Override
    public void onScaleEnd(ScaleGestureDetector d) {
      emitScale("pinchEnd", d);
      pinching = false;
    }

    private void emitScale(String name, ScaleGestureDetector d) {
      String payload = "{\"scale\":" + pinchScale
          + ",\"focusX\":" + (d.getFocusX() / density)
          + ",\"focusY\":" + (d.getFocusY() / density) + "}";
      CanopyHostJni.emitEvent(handle, name, payload);
    }

    private void emit(String name, float dx, float dy, float vx, float vy) {
      String payload = "{\"dx\":" + dx + ",\"dy\":" + dy
          + ",\"vx\":" + vx + ",\"vy\":" + vy + "}";
      CanopyHostJni.emitEvent(handle, name, payload);
    }

    private void claimParent() {
      ViewParent p = view.getParent();
      if (p != null) { p.requestDisallowInterceptTouchEvent(true); }
    }

    private void releaseParent() {
      ViewParent p = view.getParent();
      if (p != null) { p.requestDisallowInterceptTouchEvent(false); }
    }
  }
}
