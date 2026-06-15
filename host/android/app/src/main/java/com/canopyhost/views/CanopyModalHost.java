// CanopyModalHost.java — the Modal / portal primitive for canopy/native.
//
// A `Native.Modal.modal` renders to a CanopyModalHost view that occupies a 0×0 slot in the
// inline Yoga tree (its children do NOT lay out inline) and instead owns an android.app.Dialog
// whose content is a separate Yoga root the host mounts the modal's children into. This is the
// RN <Modal> model: a top-level overlay that escapes the normal layout, dims the backdrop,
// honours hardware-back / outside-tap (→ requestClose), and toggles via the `visible` prop.
//
// AND-7 polish:
//   • onShow / onDismiss: the present/dismiss lifecycle. "show" fires once the Dialog window is
//     actually on screen (RN's onShow); "dismiss" fires once it leaves (RN's onDismiss). Both are
//     gated by subscription so an unsubscribed modal does no JSI round-trips.
//   • requestClose: hardware-back and (when transparent) a backdrop tap → requestClose; the app
//     decides whether to flip `visible` to False.
//   • status-bar propagation: statusBarTranslucent draws the modal window edge-to-edge under the
//     system bars (RN's statusBarTranslucent); the modal can also theme its OWN status bar
//     (appearance light/dark, colour) independently of the host activity while it is up.
//
// Wire shape (props): visible:"true"/"false", transparent:"true"/"false", animationType:
// "none"|"fade"|"slide", statusBarTranslucent:"true"/"false", statusBarColor:"#rrggbb"/null,
// statusBarStyle:"light"/"dark". Events: requestClose ({}) on back / backdrop tap; show ({}) /
// dismiss ({}) on the present/dismiss lifecycle.

package com.canopyhost.views;

import android.app.Dialog;
import android.content.Context;
import android.graphics.Color;
import android.graphics.drawable.ColorDrawable;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowManager;

import androidx.core.view.WindowCompat;
import androidx.core.view.WindowInsetsControllerCompat;

import com.canopyhost.CanopyHostJni;

public final class CanopyModalHost extends View {

  private final Dialog dialog;
  private ViewGroup content;          // the dialog's Yoga content root (host mounts children here)
  private int handle = 0;
  private boolean visible = false;
  private boolean transparent = false;
  private boolean statusBarTranslucent = false;

  // Event gating: only emit the lifecycle events the app subscribed to (no wasted JSI hops).
  private boolean emitShow = false, emitDismiss = false;

  public CanopyModalHost(Context ctx) {
    super(ctx);
    dialog = new Dialog(ctx, android.R.style.Theme_Translucent_NoTitleBar);
    Window w = dialog.getWindow();
    if (w != null) {
      w.setLayout(WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT);
      w.setBackgroundDrawable(new ColorDrawable(Color.TRANSPARENT));
    }
    // Back press + (when transparent) an outside tap → requestClose; the app decides to close.
    dialog.setOnCancelListener(d -> { if (handle != 0) CanopyHostJni.emitEvent(handle, "requestClose", "{}"); });
    // Lifecycle: show/dismiss fire once the Dialog window is actually on/off screen.
    dialog.setOnShowListener(d -> { if (emitShow && handle != 0) CanopyHostJni.emitEvent(handle, "show", "{}"); });
    dialog.setOnDismissListener(d -> {
      visible = false;
      if (emitDismiss && handle != 0) CanopyHostJni.emitEvent(handle, "dismiss", "{}");
    });
    applyDim();
  }

  /** Called once by the host to hand over the Yoga content root (created by CanopyHost). */
  public void attachContent(ViewGroup contentView) {
    this.content = contentView;
    dialog.setContentView(content,
        new ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
  }

  public ViewGroup content() { return content; }

  public void setViewHandle(int h) { this.handle = h; }

  /** Gate the lifecycle events by what the app subscribed to (mirrors the ScrollView's setEmit*). */
  public void setEmit(boolean show, boolean dismiss) {
    this.emitShow = show;
    this.emitDismiss = dismiss;
  }

  public void setVisible(boolean v) {
    if (v && !visible) {
      dialog.show();
      applyStatusBar();                 // window exists only after show(); theme it now
      if (content != null) content.requestLayout();
    } else if (!v && visible) {
      dialog.dismiss();
    }
    visible = v;
  }

  public void setTransparent(boolean t) {
    transparent = t;
    dialog.setCanceledOnTouchOutside(t); // a backdrop tap closes a transparent (sheet/dialog) modal
    applyDim();
  }

  public void setAnimationType(String type) {
    Window w = dialog.getWindow();
    if (w == null) return;
    if ("none".equals(type)) w.setWindowAnimations(0);
    else w.setWindowAnimations(android.R.style.Animation_Dialog); // fade/slide → platform dialog anim
  }

  // ---- status-bar propagation -----------------------------------------------

  /**
   * statusBarTranslucent (RN): when true, the modal window draws edge-to-edge UNDER the system
   * bars (the content owns the inset region). When false, the window fits inside the system bars.
   */
  public void setStatusBarTranslucent(boolean translucent) {
    statusBarTranslucent = translucent;
    applyStatusBar();
  }

  /** Theme the modal window's status bar with an explicit colour (null/empty ⇒ leave as-is). */
  public void setStatusBarColor(Integer color) {
    this.statusBarColor = color;
    applyStatusBar();
  }

  /** "light" ⇒ light (white) status-bar icons (for a dark bar); "dark" ⇒ dark icons. */
  public void setStatusBarStyle(String style) {
    this.statusBarStyle = style;
    applyStatusBar();
  }

  private Integer statusBarColor = null;
  private String statusBarStyle = null;

  private void applyStatusBar() {
    Window w = dialog.getWindow();
    if (w == null || !dialog.isShowing()) return; // only meaningful once the window is attached
    WindowCompat.setDecorFitsSystemWindows(w, !statusBarTranslucent);
    if (statusBarColor != null) {
      w.addFlags(WindowManager.LayoutParams.FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS);
      w.clearFlags(WindowManager.LayoutParams.FLAG_TRANSLUCENT_STATUS);
      w.setStatusBarColor(statusBarColor);
    }
    if (statusBarStyle != null) {
      WindowInsetsControllerCompat ic = WindowCompat.getInsetsController(w, w.getDecorView());
      // "light" = light content (white icons) → appearance-light-bars OFF (mirrors CanopyStatusBar).
      ic.setAppearanceLightStatusBars(!"light".equals(statusBarStyle));
    }
  }

  private void applyDim() {
    Window w = dialog.getWindow();
    if (w == null) return;
    if (transparent) {
      w.clearFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);
    } else {
      w.addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);
      w.setDimAmount(0.5f);
    }
  }

  // 0×0 in the inline tree — the real content lives in the dialog window.
  @Override protected void onMeasure(int wSpec, int hSpec) { setMeasuredDimension(0, 0); }

  // Dismiss the dialog if the host view is torn down (avoid a leaked window).
  @Override protected void onDetachedFromWindow() {
    super.onDetachedFromWindow();
    if (dialog.isShowing()) dialog.dismiss();
  }

  // ---- test-only accessors (package-visible; device-free unit coverage) -----

  boolean isVisible() { return visible; }
  boolean isStatusBarTranslucent() { return statusBarTranslucent; }
  boolean emitsShow() { return emitShow; }
  boolean emitsDismiss() { return emitDismiss; }
  Dialog dialog() { return dialog; }
}
