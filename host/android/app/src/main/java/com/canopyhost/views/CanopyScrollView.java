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
// Emits a throttled "scroll" ({x,y,contentWidth,contentHeight,viewportWidth,viewportHeight} dp),
// a debounced "momentumScrollEnd", and "refresh" (when a RefreshControl fires). `refreshing` is
// driven by the prop.

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

  private final float density;
  private int viewHandle = -1;
  private boolean emitScroll = false, emitRefresh = false;
  private boolean scrollEnabled = true, horizontal = false, refreshEnabled = false;

  private View content;                    // the inner Yoga content root (host-owned)
  private NestedScrollView vScroll;        // vertical
  private HorizontalScrollView hScroll;    // horizontal
  private SwipeRefreshLayout refresh;      // pull-to-refresh wrapper (vertical only)

  private long lastEmit = 0;
  private final Runnable settle = this::emitMomentumEnd;

  public CanopyScrollView(Context context) {
    super(context);
    this.density = context.getResources().getDisplayMetrics().density;
  }

  // ---- host API -------------------------------------------------------------

  public void setViewHandle(int h) { this.viewHandle = h; }
  public void setEmitScroll(boolean on) { this.emitScroll = on; }
  public void setEmitRefresh(boolean on) { this.emitRefresh = on; }
  public void setScrollEnabled(boolean enabled) { this.scrollEnabled = enabled; }

  /** Hand over the inner Yoga content root; assembles the scroller tree around it. */
  public void setContent(View c) { this.content = c; rebuild(); }

  public void setHorizontal(boolean h) { if (h != horizontal) { horizontal = h; rebuild(); } }

  public void setRefreshControl(boolean enabled) { if (enabled != refreshEnabled) { refreshEnabled = enabled; rebuild(); } }

  public void setRefreshing(boolean r) { if (refresh != null) refresh.setRefreshing(r); }

  // ---- assembly -------------------------------------------------------------

  private void rebuild() {
    removeAllViews();
    detach(content);
    if (refresh != null) refresh.removeAllViews();

    View scroller;
    if (horizontal) {
      if (hScroll == null) {
        hScroll = new HorizontalScrollView(getContext()) {
          @Override public boolean onInterceptTouchEvent(MotionEvent e) { return scrollEnabled && super.onInterceptTouchEvent(e); }
          @Override public boolean onTouchEvent(MotionEvent e) { return scrollEnabled && super.onTouchEvent(e); }
        };
        hScroll.setFillViewport(true);
        hScroll.setOnScrollChangeListener((View.OnScrollChangeListener) (v, sx, sy, ox, oy) -> onScrolled(sx, sy));
      }
      if (content != null) hScroll.addView(content, WC, MP);
      scroller = hScroll;
    } else {
      if (vScroll == null) {
        vScroll = new NestedScrollView(getContext()) {
          @Override public boolean onInterceptTouchEvent(MotionEvent e) { return scrollEnabled && super.onInterceptTouchEvent(e); }
          @Override public boolean onTouchEvent(MotionEvent e) { return scrollEnabled && super.onTouchEvent(e); }
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

  // ---- scroll events --------------------------------------------------------

  private void onScrolled(int x, int y) {
    if (!emitScroll || viewHandle < 0) return;
    long now = android.os.SystemClock.uptimeMillis();
    if (now - lastEmit >= 16) { lastEmit = now; emitScrollEvent(x, y); } // ~60fps cap
    removeCallbacks(settle);
    postDelayed(settle, 100); // momentum settled
  }

  private void emitScrollEvent(int x, int y) {
    int contentW = content != null ? content.getWidth() : 0;
    int contentH = content != null ? content.getHeight() : 0;
    String json = "{\"x\":" + (x / density)
        + ",\"y\":" + (y / density)
        + ",\"contentWidth\":" + (contentW / density)
        + ",\"contentHeight\":" + (contentH / density)
        + ",\"viewportWidth\":" + (getWidth() / density)
        + ",\"viewportHeight\":" + (getHeight() / density) + "}";
    CanopyHostJni.emitEvent(viewHandle, "scroll", json);
  }

  private void emitMomentumEnd() {
    if (emitScroll && viewHandle >= 0) {
      int off = horizontal ? (hScroll != null ? hScroll.getScrollX() : 0) : (vScroll != null ? vScroll.getScrollY() : 0);
      CanopyHostJni.emitEvent(viewHandle, "momentumScrollEnd",
          horizontal ? "{\"x\":" + (off / density) + "}" : "{\"y\":" + (off / density) + "}");
    }
  }
}
