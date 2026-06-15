// CanopyComponentFactory.java — the Java side of canopy::CanopyViewFactory (CanopyAbi.h),
// Phase 4 Escape-hatch M1.
//
// A third-party library registers one of these (via CanopyViewRegistry.register) so its native
// view class mounts for a custom Fabric tag WITHOUT editing the host's makeView switch. The host's
// existing applyProps seams already handle style / background / testID / events generically, so a
// style-only custom view needs only create(); a view with component-specific props overrides
// applyProp + reset.

package com.canopyhost;

import android.content.Context;
import android.view.View;

public interface CanopyComponentFactory {

  /** Create the native view for a fresh handle. Called from CanopyHost.makeView's default case. */
  View create(Context context);

  /** Apply a custom (non-style) prop. Style/background/testID/events route through the host's
   *  existing applyProps seams; override this only for component-specific props. Default no-op. */
  default void applyProp(View view, String key, String value) {}

  /** Reset a custom prop to its default on a RECYCLED view — MANDATORY per the ABI contract: the
   *  walker diffs a dropped prop by null-encoding its key, so a reused view must restore the
   *  default or it leaks a prior screen's state. No-op for style-only views. */
  default void reset(View view, String key) {}
}
