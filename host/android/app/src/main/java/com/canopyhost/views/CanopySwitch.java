// CanopySwitch.java — a controlled Switch (RCTSwitch) for canopy/native.
//
// A controlled toggle: `value` is driven from the model, and onValueChange reports user flips.
// The echo-guard (suppress) is load-bearing: a programmatic setChecked from applyProps must NOT
// re-fire the listener — otherwise the change re-dispatches re-entrantly INSIDE the host's
// updateProps (where the JS event context is invalid → "sendToApp: undefined is not a function",
// a red-box). This mirrors CanopyTextInput's controlled-value discipline exactly.

package com.canopyhost.views;

import android.content.Context;
import android.widget.Switch;

import com.canopyhost.CanopyHostJni;

public final class CanopySwitch extends Switch {

  private int handle = 0;
  private boolean emit = false;
  private boolean suppress = false;

  public CanopySwitch(Context ctx) {
    super(ctx);
    setOnCheckedChangeListener((button, checked) -> {
      if (suppress || !emit || handle == 0) return;
      CanopyHostJni.emitEvent(handle, "valueChange", "{\"value\":" + checked + "}");
    });
  }

  public void setViewHandle(int h) { this.handle = h; }

  /** Subscribe to valueChange only when the app asked for it (via setEvents). */
  public void setEmit(boolean e) { this.emit = e; }

  /** Controlled set: skip if unchanged, and never re-fire the change listener. */
  public void setCheckedControlled(boolean v) {
    if (isChecked() == v) return;
    suppress = true;
    setChecked(v);
    suppress = false;
  }
}
