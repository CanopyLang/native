// CanopyModalHostTest.java — JVM unit test (Robolectric) for the AND-7 Modal polish.
//
// AND-7's Modal half adds the present/dismiss lifecycle (onShow/onDismiss), keeps requestClose
// (back / backdrop tap), and propagates status-bar config to the modal's OWN window. The visible
// device behaviour (the present/dismiss animation, the actual bar appearance) needs an emulator
// (CanopyFixtureUiTest); what IS device-free unit-testable here is the gating + state logic that
// decides what the host emits and how the dialog is configured:
//
//   (a) setEmit records the show/dismiss subscription (mirrors the ScrollView's setEmit*), so an
//       unsubscribed modal does no JSI round-trips.
//   (b) the visible prop toggles the underlying Dialog (show ⇄ dismiss) and the isVisible() state.
//   (c) transparent flips canceledOnTouchOutside (a backdrop tap → requestClose only when transparent).
//   (d) statusBarTranslucent / statusBarColor / statusBarStyle are recorded without throwing before
//       the window is attached (applyStatusBar early-outs until the dialog is showing).
//
// The lifecycle events are gated off by default (emitShow/emitDismiss = false, handle = 0), so these
// never call the native emitEvent — they run on the host JVM via `:app:testDebugUnitTest`, no emulator.

package com.canopyhost.views;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import android.view.ViewGroup;
import android.widget.FrameLayout;

import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;

@RunWith(RobolectricTestRunner.class)
public final class CanopyModalHostTest {

  private CanopyModalHost make() {
    CanopyModalHost mh = new CanopyModalHost(RuntimeEnvironment.getApplication());
    ViewGroup content = new FrameLayout(RuntimeEnvironment.getApplication());
    mh.attachContent(content);
    return mh;
  }

  // ---- (a) lifecycle-event subscription gating ------------------------------------------------

  @Test
  public void setEmit_recordsShowDismissSubscription() {
    CanopyModalHost mh = make();
    assertFalse("unsubscribed by default", mh.emitsShow());
    assertFalse(mh.emitsDismiss());
    mh.setEmit(true, false);
    assertTrue(mh.emitsShow());
    assertFalse(mh.emitsDismiss());
    mh.setEmit(false, true);
    assertFalse(mh.emitsShow());
    assertTrue(mh.emitsDismiss());
  }

  // ---- (b) visible toggles the dialog ---------------------------------------------------------

  @Test
  public void visible_togglesTheDialogAndState() {
    CanopyModalHost mh = make();
    assertFalse(mh.isVisible());
    assertFalse(mh.dialog().isShowing());
    mh.setVisible(true);
    assertTrue("shown after visible=true", mh.isVisible());
    assertTrue(mh.dialog().isShowing());
    mh.setVisible(false);
    assertFalse("hidden after visible=false", mh.isVisible());
    assertFalse(mh.dialog().isShowing());
  }

  // Re-applying the SAME visible value is a no-op (no spurious show/dismiss churn).
  @Test
  public void visible_idempotentApply() {
    CanopyModalHost mh = make();
    mh.setVisible(true);
    mh.setVisible(true);               // already showing → no-op
    assertTrue(mh.isVisible());
    assertTrue(mh.dialog().isShowing());
    mh.setVisible(false);
    mh.setVisible(false);              // already hidden → no-op
    assertFalse(mh.isVisible());
  }

  // ---- (c) transparent → backdrop-tap cancel --------------------------------------------------

  @Test
  public void transparent_enablesBackdropCancel() {
    CanopyModalHost mh = make();
    mh.setVisible(true);
    mh.setTransparent(true);
    assertTrue("a transparent modal cancels on an outside tap",
        org.robolectric.Shadows.shadowOf(mh.dialog()).isCancelable());
  }

  // ---- (d) status-bar propagation state -------------------------------------------------------

  @Test
  public void statusBarTranslucent_isRecorded() {
    CanopyModalHost mh = make();
    assertFalse("opaque by default", mh.isStatusBarTranslucent());
    mh.setStatusBarTranslucent(true);
    assertTrue(mh.isStatusBarTranslucent());
  }

  // The status-bar setters must not throw before the window is attached (applyStatusBar early-outs
  // until the dialog is showing) — a modal configured while hidden is the common case.
  @Test
  public void statusBar_settersAreSafeBeforeShow() {
    CanopyModalHost mh = make();
    mh.setStatusBarColor(0xFF112233);
    mh.setStatusBarStyle("light");
    mh.setStatusBarTranslucent(true);
    // and applying them again AFTER show must also not throw
    mh.setVisible(true);
    mh.setStatusBarColor(0xFF445566);
    mh.setStatusBarStyle("dark");
    assertTrue(mh.isStatusBarTranslucent());
  }
}
