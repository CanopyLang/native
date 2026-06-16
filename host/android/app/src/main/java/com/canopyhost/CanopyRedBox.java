// CanopyRedBox.java — the dev red-box / prod error overlay.
//
// When a JS exception crosses a host re-entry site (bundle eval, boot, a Cmd/Sub completion,
// an event dispatch), the C++ guard routes (message, stack) here instead of letting the C++
// exception escape into Hermes' frame and SIGABRT the process. This is mounted with PLAIN
// Android views (NOT through the Canopy walker), so it survives even a walker/reconciler crash.
//
// Dev (BuildConfig.DEBUG): full message + symbolicated-ish JS stack, scrollable, with Dismiss
// + Reload. Prod: a calm branded "Something went wrong" with Restart (no stack leak).

package com.canopyhost;

import android.app.Activity;
import android.graphics.Color;
import android.graphics.Typeface;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

public final class CanopyRedBox {

  private static FrameLayout current; // single overlay; replaced on a new error

  /** Show the overlay on top of the activity's content. Must run on the UI thread. */
  public static void show(Activity activity, String message, String stack, boolean dev, boolean fatal) {
    if (activity == null) return;
    dismiss(); // collapse to the most recent error

    FrameLayout overlay = new FrameLayout(activity);
    overlay.setBackgroundColor(dev ? 0xF2B00020 : 0xFF0E0E10); // crimson scrim (dev) / charcoal (prod)
    overlay.setClickable(true); // swallow taps to the broken tree underneath

    LinearLayout col = new LinearLayout(activity);
    col.setOrientation(LinearLayout.VERTICAL);
    col.setPadding(dp(activity, 24), dp(activity, 56), dp(activity, 24), dp(activity, 24));

    TextView title = new TextView(activity);
    title.setText(dev ? (fatal ? "Native error" : "JS error") : "Something went wrong");
    title.setTextColor(Color.WHITE);
    title.setTextSize(22);
    title.setTypeface(null, Typeface.BOLD);
    col.addView(title);

    if (dev) {
      TextView msg = new TextView(activity);
      msg.setText(message == null ? "(no message)" : message);
      msg.setTextColor(0xFFFFE0E0);
      msg.setTextSize(15);
      msg.setPadding(0, dp(activity, 12), 0, dp(activity, 12));
      col.addView(msg);

      ScrollView sv = new ScrollView(activity);
      TextView st = new TextView(activity);
      st.setText(stack == null || stack.isEmpty() ? "(no stack)" : stack);
      st.setTextColor(0xFFE8ECFF);
      st.setTextSize(12);
      st.setTypeface(Typeface.MONOSPACE);
      sv.addView(st);
      col.addView(sv, new LinearLayout.LayoutParams(
          ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f)); // grow to fill
    } else {
      TextView sub = new TextView(activity);
      sub.setText("The app hit an unexpected problem. Please restart.");
      sub.setTextColor(0xFFA8A29A);
      sub.setTextSize(15);
      sub.setPadding(0, dp(activity, 12), 0, dp(activity, 24));
      col.addView(sub);
      View spacer = new View(activity);
      col.addView(spacer, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));
    }

    LinearLayout row = new LinearLayout(activity);
    row.setOrientation(LinearLayout.HORIZONTAL);
    if (dev && !fatal) {
      row.addView(button(activity, "Dismiss", v -> dismiss()), grow(activity));
    }
    row.addView(button(activity, dev ? "Reload" : "Restart", v -> {
      dismiss();
      // DEV-11: in a debug build with a dev loop attached, this recovers to the last-known-good
      // bundle (re-eval the last build that worked + restore the captured model) rather than a hard
      // restart; falls back to a plain dismiss when no good bundle is available / in release.
      CanopyHostJni.reload();
    }), grow(activity));
    col.addView(row);

    overlay.addView(col, new FrameLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

    activity.addContentView(overlay, new FrameLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
    current = overlay;
  }

  public static void dismiss() {
    if (current != null && current.getParent() instanceof ViewGroup) {
      ((ViewGroup) current.getParent()).removeView(current);
    }
    current = null;
  }

  private static Button button(Activity a, String label, View.OnClickListener onClick) {
    Button b = new Button(a);
    b.setText(label);
    b.setAllCaps(false);
    b.setOnClickListener(onClick);
    return b;
  }

  private static LinearLayout.LayoutParams grow(Activity a) {
    LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
    lp.setMargins(dp(a, 4), 0, dp(a, 4), 0);
    return lp;
  }

  private static int dp(Activity a, int v) {
    return Math.round(v * a.getResources().getDisplayMetrics().density);
  }

  private CanopyRedBox() {}
}
