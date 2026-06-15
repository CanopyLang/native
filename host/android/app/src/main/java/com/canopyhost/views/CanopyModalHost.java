// CanopyModalHost.java — the Modal / portal primitive for canopy/native.
//
// A `Native.Modal.modal` renders to a CanopyModalHost view that occupies a 0×0 slot in the
// inline Yoga tree (its children do NOT lay out inline) and instead owns an android.app.Dialog
// whose content is a separate Yoga root the host mounts the modal's children into. This is the
// RN <Modal> model: a top-level overlay that escapes the normal layout, dims the backdrop,
// honours hardware-back / outside-tap (→ requestClose), and toggles via the `visible` prop.
//
// Wire shape (props): visible:"true"/"false", transparent:"true"/"false", animationType:
// "none"|"fade"|"slide". Event: requestClose ({}) on back / backdrop tap.

package com.canopyhost.views;

import android.app.Dialog;
import android.content.Context;
import android.graphics.Color;
import android.graphics.drawable.ColorDrawable;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowManager;

import com.canopyhost.CanopyHostJni;

public final class CanopyModalHost extends View {

  private final Dialog dialog;
  private ViewGroup content;          // the dialog's Yoga content root (host mounts children here)
  private int handle = 0;
  private boolean visible = false;
  private boolean transparent = false;

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
    dialog.setOnDismissListener(d -> visible = false);
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

  public void setVisible(boolean v) {
    if (v && !visible) {
      dialog.show();
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
}
