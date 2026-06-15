// BeforeAfterView.java — the C2 "before/after wipe" native compositor.
//
// The marketing interaction behind Native.BeforeAfter (canopy/native): two RGBA bitmap
// layers — a `before` and an `after`, both pulled from the shared blob registry by handle
// via CanopyBlobs.nativeBlobGetBitmap — drawn one over the other, with the `after` layer
// CLIPPED to a vertical wipe line at `wipeFraction` of the view width. Dragging horizontally
// moves the line; a double tap snaps it to the opposite end with a ValueAnimator.
//
// THE WHOLE POINT — ZERO JS PER FRAME (the C2/C3 fidelity rule):
//   • A GestureDetector + onScroll inside THIS view moves `wipeFraction` and calls
//     invalidate() on every touch sample. The Hermes/TEA loop is never woken during a drag,
//     so a fast finger never round-trips through JS and never janks. We emit only the two
//     SEMANTIC edges of the interaction back into Canopy:
//        - "wipeStart"  (touch down)           payload {}
//        - "wipeCommit" (lift / fling / tween) payload {"fraction": <0..1>}
//   • requestDisallowInterceptTouchEvent(true) once the drag is confirmed horizontal, so a
//     parent scroll container does not steal the gesture (axis bias: we only claim when the
//     horizontal travel dominates the vertical).
//   • A VelocityTracker is fed the raw MotionEvents so onPanEnd-style velocity is available;
//     here we use it only to decide fling direction for the snap, but it is the same source
//     CanopyHost.setEvents reads for the generic onPan* family.
//
// PROPS (top-level, set by CanopyHost.applyProps from the before/afterBeforeAfter component):
//   • beforeHandle : int   blob handle for the underneath layer
//   • afterHandle  : int   blob handle for the clipped-on-top layer
//   • wipeFraction : float controlled wipe position 0..1 (honored unless mid-drag)
//
// It is a plain android.view.View (custom onDraw); it carries no children, so the host wires
// it as a LEAF in makeView. Bitmaps are resolved lazily when a handle prop changes and cached
// until the handle changes again (a handle swap is a single targeted updateProps, never a
// re-mount — same discipline as CanopyBitmap).

package com.canopyhost.views;

import android.animation.ValueAnimator;
import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Rect;
import android.graphics.RectF;
import android.view.GestureDetector;
import android.view.MotionEvent;
import android.view.VelocityTracker;
import android.view.View;
import android.view.animation.DecelerateInterpolator;

import com.canopyhost.CanopyBlobs;
import com.canopyhost.CanopyHostJni;

/** Native before/after wipe compositor (component tag "before/afterBeforeAfter"). */
public final class BeforeAfterView extends View {

  // The Canopy view handle (CanopyHost's CView id) so emitEvent routes back to the right node.
  private int viewHandle = -1;

  private int beforeBlob = 0;
  private int afterBlob = 0;
  private Bitmap beforeBmp = null;
  private Bitmap afterBmp = null;

  // The wipe position in 0..1. `controlled` is the last value Canopy pushed; `wipe` is what we
  // actually draw (== controlled unless the user is mid-drag, when we own it locally).
  private float controlled = 0.5f;
  private float wipe = 0.5f;
  private boolean dragging = false;

  private final GestureDetector detector;
  private VelocityTracker velocity;
  private ValueAnimator snapAnim;

  // Scratch rects reused per draw (no per-frame allocation).
  private final Rect srcRect = new Rect();
  private final RectF dstRect = new RectF();

  public BeforeAfterView(Context context) {
    super(context);
    setClickable(true);
    detector = new GestureDetector(context, new GestureListener());
    detector.setOnDoubleTapListener(new GestureListener());
  }

  // A fixed-size compositor: take whatever the parent (Yoga measure fn) offers for a bounded
  // spec. A plain View reports 0 for AT_MOST/UNSPECIFIED, which would collapse the Yoga leaf —
  // unlike an ImageView, which has intrinsic content size.
  @Override
  protected void onMeasure(int widthMeasureSpec, int heightMeasureSpec) {
    int w = MeasureSpec.getMode(widthMeasureSpec) == MeasureSpec.UNSPECIFIED ? 0 : MeasureSpec.getSize(widthMeasureSpec);
    int h = MeasureSpec.getMode(heightMeasureSpec) == MeasureSpec.UNSPECIFIED ? 0 : MeasureSpec.getSize(heightMeasureSpec);
    setMeasuredDimension(w, h);
  }

  // ---- props (called from CanopyHost.applyProps) ----------------------------

  /** CanopyHost passes the CView id so emitEvent can target this node. */
  public void setViewHandle(int h) { this.viewHandle = h; }

  public void setBeforeHandle(int handle) {
    if (handle == beforeBlob) { return; }
    beforeBlob = handle;
    beforeBmp = (handle > 0) ? CanopyBlobs.nativeBlobGetBitmap(handle) : null;
    invalidate();
  }

  public void setAfterHandle(int handle) {
    if (handle == afterBlob) { return; }
    afterBlob = handle;
    afterBmp = (handle > 0) ? CanopyBlobs.nativeBlobGetBitmap(handle) : null;
    invalidate();
  }

  /** Controlled wipe position. Ignored while the user is dragging so the drag stays glitch-free. */
  public void setWipeFraction(float f) {
    controlled = clamp01(f);
    if (!dragging && (snapAnim == null || !snapAnim.isRunning())) {
      wipe = controlled;
      invalidate();
    }
  }

  // ---- drawing --------------------------------------------------------------

  @Override
  protected void onDraw(Canvas canvas) {
    final int w = getWidth();
    final int h = getHeight();
    if (w == 0 || h == 0) { return; }

    // Layer 1: the BEFORE image, full-bleed (cover-fit).
    if (beforeBmp != null) {
      drawCover(canvas, beforeBmp, w, h);
    }

    // Layer 2: the AFTER image, clipped to [0 .. wipe*w].
    if (afterBmp != null) {
      int splitX = Math.round(wipe * w);
      int saved = canvas.save();
      canvas.clipRect(0, 0, splitX, h);
      drawCover(canvas, afterBmp, w, h);
      canvas.restoreToCount(saved);
    }
  }

  // Draw `bmp` to cover the w x h box, preserving aspect (center-crop), matching the
  // CanopyBitmap "cover" intuition so the two layers register pixel-for-pixel.
  private void drawCover(Canvas canvas, Bitmap bmp, int w, int h) {
    int bw = bmp.getWidth(), bh = bmp.getHeight();
    if (bw <= 0 || bh <= 0) { return; }
    float scale = Math.max((float) w / bw, (float) h / bh);
    float dw = bw * scale, dh = bh * scale;
    float left = (w - dw) * 0.5f, top = (h - dh) * 0.5f;
    srcRect.set(0, 0, bw, bh);
    dstRect.set(left, top, left + dw, top + dh);
    canvas.drawBitmap(bmp, srcRect, dstRect, null);
  }

  // ---- touch: self-driven wipe (no JS per frame) ----------------------------

  @Override
  public boolean onTouchEvent(MotionEvent ev) {
    if (velocity == null) { velocity = VelocityTracker.obtain(); }
    velocity.addMovement(ev);

    boolean handled = detector.onTouchEvent(ev);

    switch (ev.getActionMasked()) {
      case MotionEvent.ACTION_DOWN:
        // Provisional grab; the actual start emit happens once the scroll is confirmed.
        return true;
      case MotionEvent.ACTION_UP:
      case MotionEvent.ACTION_CANCEL:
        if (dragging) {
          dragging = false;
          getParent().requestDisallowInterceptTouchEvent(false);
          controlled = wipe;
          emit("wipeCommit", "{\"fraction\":" + wipe + "}");
        }
        if (velocity != null) { velocity.recycle(); velocity = null; }
        break;
      default:
        break;
    }
    return handled || true;
  }

  private final class GestureListener extends GestureDetector.SimpleOnGestureListener {

    @Override
    public boolean onDown(MotionEvent e) { return true; }

    @Override
    public boolean onScroll(MotionEvent e1, MotionEvent e2, float distanceX, float distanceY) {
      final int w = getWidth();
      if (w == 0) { return false; }

      // Axis bias: only claim the touch stream once horizontal travel dominates, so a parent
      // vertical scroller keeps vertical gestures. distanceX/Y here are per-frame deltas.
      if (!dragging) {
        float totalX = Math.abs(e2.getX() - e1.getX());
        float totalY = Math.abs(e2.getY() - e1.getY());
        if (totalX < totalY) { return false; }        // vertical-dominant → let parent have it
        dragging = true;
        getParent().requestDisallowInterceptTouchEvent(true);
        emit("wipeStart", "{}");
      }

      // Move the wipe directly to the finger's x (absolute) — feels like dragging the seam.
      wipe = clamp01(e2.getX() / w);
      invalidate();                                    // redraw, NO JS round-trip
      return true;
    }

    @Override
    public boolean onDoubleTap(MotionEvent e) {
      // Snap to the opposite end with a native tween; emit one commit at the end.
      float from = wipe;
      float to = (wipe >= 0.5f) ? 0f : 1f;
      animateTo(from, to);
      return true;
    }

    @Override
    public boolean onSingleTapConfirmed(MotionEvent e) {
      // A confirmed single tap is not a wipe interaction; ignore (Canopy can still use onTap
      // via the generic gesture path on a wrapping view if it wants it).
      return false;
    }
  }

  private void animateTo(float from, float to) {
    if (snapAnim != null && snapAnim.isRunning()) { snapAnim.cancel(); }
    snapAnim = ValueAnimator.ofFloat(from, to);
    snapAnim.setDuration(260);
    snapAnim.setInterpolator(new DecelerateInterpolator());
    snapAnim.addUpdateListener(a -> {
      wipe = (float) a.getAnimatedValue();
      invalidate();                                    // native frames, NO JS round-trip
    });
    snapAnim.addListener(new android.animation.AnimatorListenerAdapter() {
      @Override public void onAnimationEnd(android.animation.Animator a) {
        controlled = wipe;
        emit("wipeCommit", "{\"fraction\":" + wipe + "}");
      }
    });
    snapAnim.start();
  }

  // ---- helpers --------------------------------------------------------------

  private void emit(String name, String payloadJson) {
    if (viewHandle >= 0) {
      CanopyHostJni.emitEvent(viewHandle, name, payloadJson);
    }
  }

  private static float clamp01(float f) {
    return f < 0f ? 0f : (f > 1f ? 1f : f);
  }
}
