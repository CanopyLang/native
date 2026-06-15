// CanopyScrollView.java — a real scrolling viewport for RCTScrollView (vertical OR horizontal,
// with optional pull-to-refresh).
//
// A composite FrameLayout that internally assembles, from props that arrive AFTER construction:
//   • a scroller — NestedScrollView (vertical, the default) or HorizontalScrollView (horizontal),
//   • optionally wrapped in a SwipeRefreshLayout (vertical pull-to-refresh).
// The host mounts the scroll children into a SEPARATE inner Yoga content view (its own
// calculateLayout root) and hands it here via setContent(); this view re-parents that content
// into the active scroller whenever orientation / refresh changes (rebuild()). A framework
// scroller measures its child UNSPECIFIED on the scroll axis, so the inner YogaViewGroup takes
// its full natural extent and this view scrolls it — exactly how RN's RCTScrollView works.
//
// AND-7 polish — the difference between "scrolls" and "feels native":
//   • scrollEventThrottle: the host-configurable minimum ms between "scroll" samples (RN's
//     scrollEventThrottle). 0 means every frame (≈16ms cap on a 60Hz panel); larger throttles
//     down to that interval. The FINAL settle sample is always delivered (never throttled away).
//   • onMomentumScrollBegin / onMomentumScrollEnd: the fling lifecycle. "Begin" fires once when a
//     touch-release leaves the scroller still moving (a fling); "End" fires (debounced) when the
//     offset stops changing. Together they bracket the momentum phase RN exposes.
//   • controlled contentOffset: setContentOffset(x,y,animated) drives the scroller to an absolute
//     dp offset, echo-guarded so the resulting scroll sample does not loop back into a re-set.
//   • keyboardDismissMode: "none" (default) | "on-drag" — when "on-drag", the soft keyboard is
//     dismissed the moment the user starts dragging the list (RN/iOS list behaviour).
//
// Emits a throttled "scroll" ({x,y,contentWidth,contentHeight,viewportWidth,viewportHeight} dp),
// "momentumScrollBegin"/"momentumScrollEnd", and "refresh" (when a RefreshControl fires).
// `refreshing` is driven by the prop.

package com.canopyhost.views;

import android.content.Context;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.HorizontalScrollView;

import androidx.core.widget.NestedScrollView;
import androidx.swiperefreshlayout.widget.SwipeRefreshLayout;

import com.canopyhost.CanopyHostJni;

public final class CanopyScrollView extends FrameLayout {

  private static final int MP = ViewGroup.LayoutParams.MATCH_PARENT;
  private static final int WC = ViewGroup.LayoutParams.WRAP_CONTENT;

  /** The default per-sample cap when scrollEventThrottle is 0/unset: one sample per 60Hz frame. */
  static final int FRAME_MS = 16;

  private final float density;
  private int viewHandle = -1;
  private boolean emitScroll = false, emitRefresh = false, emitMomentum = false;
  private boolean scrollEnabled = true, horizontal = false, refreshEnabled = false;

  // AND-7 controlled/config state.
  private int scrollThrottleMs = 0;         // 0 ⇒ frame-cap (FRAME_MS); else the requested floor
  private String keyboardDismissMode = "none";

  private View content;                    // the inner Yoga content root (host-owned)
  private NestedScrollView vScroll;        // vertical
  private HorizontalScrollView hScroll;    // horizontal
  private SwipeRefreshLayout refresh;      // pull-to-refresh wrapper (vertical only)

  private long lastEmit = 0;
  private final Runnable settle = this::emitMomentumEnd;

  // Momentum-phase tracking: a fling begins when a touch-release leaves the scroller moving, so we
  // track whether the user's finger is down and whether we've already announced the current fling.
  private boolean touching = false;        // a finger is currently on the scroller
  private boolean inMomentum = false;      // we've announced momentumScrollBegin for this fling
  private boolean keyboardDismissedThisDrag = false;

  // Echo-guard: a controlled setContentOffset must not bounce back through onScrolled as a user
  // scroll (which would re-emit + risk a feedback loop with a controlled prop). We swallow the
  // exactly-one programmatic sample it produces.
  private boolean suppressNextSample = false;

  public CanopyScrollView(Context context) {
    super(context);
    this.density = context.getResources().getDisplayMetrics().density;
  }

  // ---- host API -------------------------------------------------------------

  public void setViewHandle(int h) { this.viewHandle = h; }
  public void setEmitScroll(boolean on) { this.emitScroll = on; }
  public void setEmitRefresh(boolean on) { this.emitRefresh = on; }
  public void setEmitMomentum(boolean on) { this.emitMomentum = on; }
  public void setScrollEnabled(boolean enabled) { this.scrollEnabled = enabled; }

  /** RN scrollEventThrottle (ms): the minimum gap between "scroll" samples. <=0 ⇒ frame-cap. */
  public void setScrollEventThrottle(int ms) { this.scrollThrottleMs = Math.max(0, ms); }

  /** RN keyboardDismissMode: "none" (default) or "on-drag". Unknown values fall back to "none". */
  public void setKeyboardDismissMode(String mode) {
    this.keyboardDismissMode = (mode == null) ? "none" : mode;
  }

  /** Hand over the inner Yoga content root; assembles the scroller tree around it. */
  public void setContent(View c) { this.content = c; rebuild(); }

  public void setHorizontal(boolean h) { if (h != horizontal) { horizontal = h; rebuild(); } }

  public void setRefreshControl(boolean enabled) { if (enabled != refreshEnabled) { refreshEnabled = enabled; rebuild(); } }

  public void setRefreshing(boolean r) { if (refresh != null) refresh.setRefreshing(r); }

  /**
   * Controlled contentOffset: drive the active scroller to an absolute (x,y) dp offset. The
   * resulting programmatic scroll sample is echo-guarded (suppressed) so a controlled prop does not
   * loop back into the app. `animated` smooth-scrolls; otherwise it jumps.
   */
  public void setContentOffset(float xDp, float yDp, boolean animated) {
    int px = Math.round(xDp * density);
    int py = Math.round(yDp * density);
    suppressNextSample = true;
    if (horizontal) {
      if (hScroll != null) { if (animated) hScroll.smoothScrollTo(px, py); else hScroll.scrollTo(px, py); }
    } else {
      if (vScroll != null) { if (animated) vScroll.smoothScrollTo(px, py); else vScroll.scrollTo(px, py); }
    }
  }

  // ---- assembly -------------------------------------------------------------

  private void rebuild() {
    removeAllViews();
    detach(content);
    if (refresh != null) refresh.removeAllViews();

    View scroller;
    if (horizontal) {
      if (hScroll == null) {
        hScroll = new HorizontalScrollView(getContext()) {
          @Override public boolean onInterceptTouchEvent(MotionEvent e) { trackTouch(e); return scrollEnabled && super.onInterceptTouchEvent(e); }
          @Override public boolean onTouchEvent(MotionEvent e) { trackTouch(e); return scrollEnabled && super.onTouchEvent(e); }
        };
        hScroll.setFillViewport(true);
        hScroll.setOnScrollChangeListener((View.OnScrollChangeListener) (v, sx, sy, ox, oy) -> onScrolled(sx, sy));
      }
      if (content != null) hScroll.addView(content, WC, MP);
      scroller = hScroll;
    } else {
      if (vScroll == null) {
        vScroll = new NestedScrollView(getContext()) {
          @Override public boolean onInterceptTouchEvent(MotionEvent e) { trackTouch(e); return scrollEnabled && super.onInterceptTouchEvent(e); }
          @Override public boolean onTouchEvent(MotionEvent e) { trackTouch(e); return scrollEnabled && super.onTouchEvent(e); }
        };
        vScroll.setFillViewport(true);
        vScroll.setClipToPadding(false);
        vScroll.setOnScrollChangeListener((NestedScrollView.OnScrollChangeListener) (v, sx, sy, ox, oy) -> onScrolled(sx, sy));
      }
      if (content != null) vScroll.addView(content, MP, WC);
      scroller = vScroll;
    }

    if (refreshEnabled && !horizontal) {
      if (refresh == null) {
        refresh = new SwipeRefreshLayout(getContext());
        refresh.setOnRefreshListener(() -> { if (emitRefresh && viewHandle >= 0) CanopyHostJni.emitEvent(viewHandle, "refresh", "{}"); });
      }
      refresh.addView(scroller, MP, MP);
      addView(refresh, MP, MP);
    } else {
      addView(scroller, MP, MP);
    }
  }

  private static void detach(View v) {
    if (v != null && v.getParent() instanceof ViewGroup) ((ViewGroup) v.getParent()).removeView(v);
  }

  // ---- touch / keyboard / momentum bookkeeping ------------------------------

  /** Observe the raw touch stream to drive keyboardDismissMode and the momentum-begin transition. */
  void trackTouch(MotionEvent e) {
    switch (e.getActionMasked()) {
      case MotionEvent.ACTION_DOWN:
        touching = true;
        inMomentum = false;          // a new touch cancels any prior fling phase
        keyboardDismissedThisDrag = false;
        break;
      case MotionEvent.ACTION_MOVE:
        if (touching && !keyboardDismissedThisDrag && "on-drag".equals(keyboardDismissMode)) {
          dismissKeyboard();
          keyboardDismissedThisDrag = true;
        }
        break;
      case MotionEvent.ACTION_UP:
      case MotionEvent.ACTION_CANCEL:
        touching = false;            // finger lifted; any continued motion is now momentum (a fling)
        break;
      default:
        break;
    }
  }

  private void dismissKeyboard() {
    View focused = findFocus();
    android.view.inputmethod.InputMethodManager imm =
        (android.view.inputmethod.InputMethodManager) getContext().getSystemService(Context.INPUT_METHOD_SERVICE);
    if (imm != null) {
      android.os.IBinder token = (focused != null) ? focused.getWindowToken() : getWindowToken();
      if (token != null) imm.hideSoftInputFromWindow(token, 0);
    }
    if (focused != null) focused.clearFocus();
  }

  // ---- scroll events --------------------------------------------------------

  private void onScrolled(int x, int y) {
    // A programmatic (controlled-contentOffset) sample is swallowed once so it does not echo back.
    if (suppressNextSample) { suppressNextSample = false; return; }

    // A scroll sample arriving while the finger is OFF the scroller, and we have not yet announced
    // it, is the start of a fling → momentumScrollBegin (exactly once per fling).
    if (!touching && !inMomentum) {
      inMomentum = true;
      emitMomentumBegin();
    }

    if (!emitScroll || viewHandle < 0) {
      // Even with no scroll subscription, keep the settle timer alive so a momentum-only listener
      // still gets momentumScrollEnd.
      removeCallbacks(settle);
      postDelayed(settle, 100);
      return;
    }
    long now = android.os.SystemClock.uptimeMillis();
    int floorMs = (scrollThrottleMs > 0) ? scrollThrottleMs : FRAME_MS;
    if (now - lastEmit >= floorMs) { lastEmit = now; emitScrollEvent(x, y); }
    removeCallbacks(settle);
    postDelayed(settle, 100); // momentum settled
  }

  private void emitScrollEvent(int x, int y) {
    if (viewHandle < 0) return;
    CanopyHostJni.emitEvent(viewHandle, "scroll", scrollJson(x, y));
  }

  /** Build the RN scroll payload (offset + content/viewport sizes), all in dp. Package-visible for tests. */
  String scrollJson(int x, int y) {
    int contentW = content != null ? content.getWidth() : 0;
    int contentH = content != null ? content.getHeight() : 0;
    return "{\"x\":" + (x / density)
        + ",\"y\":" + (y / density)
        + ",\"contentWidth\":" + (contentW / density)
        + ",\"contentHeight\":" + (contentH / density)
        + ",\"viewportWidth\":" + (getWidth() / density)
        + ",\"viewportHeight\":" + (getHeight() / density) + "}";
  }

  private void emitMomentumBegin() {
    if (emitMomentum && viewHandle >= 0) {
      int off = horizontal ? (hScroll != null ? hScroll.getScrollX() : 0) : (vScroll != null ? vScroll.getScrollY() : 0);
      CanopyHostJni.emitEvent(viewHandle, "momentumScrollBegin", offsetJson(off));
    }
  }

  private void emitMomentumEnd() {
    inMomentum = false; // the fling has settled; the next off-touch sample is a fresh fling
    if (emitMomentum && viewHandle >= 0) {
      int off = horizontal ? (hScroll != null ? hScroll.getScrollX() : 0) : (vScroll != null ? vScroll.getScrollY() : 0);
      CanopyHostJni.emitEvent(viewHandle, "momentumScrollEnd", offsetJson(off));
    }
  }

  /** {"x":..} for a horizontal scroller, {"y":..} for a vertical one (the axis offset in dp). */
  String offsetJson(int offPx) {
    return horizontal ? "{\"x\":" + (offPx / density) + "}" : "{\"y\":" + (offPx / density) + "}";
  }

  // ---- test-only accessors (package-visible; device-free unit coverage) -----

  int throttleFloorMs() { return (scrollThrottleMs > 0) ? scrollThrottleMs : FRAME_MS; }
  boolean isHorizontal() { return horizontal; }
  String keyboardDismissMode() { return keyboardDismissMode; }
  boolean inMomentumForTest() { return inMomentum; }
  void onScrolledForTest(int x, int y) { onScrolled(x, y); }
}
