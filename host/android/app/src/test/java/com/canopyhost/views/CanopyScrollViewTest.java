// CanopyScrollViewTest.java — JVM unit test (Robolectric) for the AND-7 ScrollView polish.
//
// AND-7 is "the difference between 'scrolls' and 'feels native'": scrollEventThrottle, the fling
// lifecycle (momentumScrollBegin/End), controlled contentOffset, and keyboardDismissMode. The
// device-tactile half (real fling physics, the soft keyboard) needs an emulator (CanopyFixtureUiTest);
// what IS device-free unit-testable here is the pure config + transition logic that decides WHAT the
// host emits and WHEN:
//
//   (a) scrollEventThrottle → throttleFloorMs(): 0/unset ⇒ the per-frame cap; a positive value is
//       the honoured floor between "scroll" samples.
//   (b) the scroll/offset JSON payloads (scrollJson / offsetJson) are well-formed and density-correct.
//   (c) the momentum-begin transition: a scroll sample arriving with the finger OFF the scroller is
//       a fling start (announced once); a fresh ACTION_DOWN re-arms it; the settle resets it.
//   (d) controlled setContentOffset swallows exactly the one programmatic sample it produces
//       (the echo-guard), so a controlled prop never loops back as a user scroll.
//   (e) keyboardDismissMode is recorded ("none" default, "on-drag", null ⇒ "none").
//
// These never call the native emitEvent (the events are gated off / handle = -1 by default), so they
// run on the host JVM via `:app:testDebugUnitTest` with no emulator and no loaded .so.

package com.canopyhost.views;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import android.os.SystemClock;
import android.view.MotionEvent;

import org.json.JSONException;
import org.json.JSONObject;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;

@RunWith(RobolectricTestRunner.class)
public final class CanopyScrollViewTest {

  private CanopyScrollView make() {
    CanopyScrollView sv = new CanopyScrollView(RuntimeEnvironment.getApplication());
    sv.setContent(new android.widget.FrameLayout(RuntimeEnvironment.getApplication())); // builds the scroller tree
    return sv;
  }

  private static MotionEvent ev(int action) {
    long t = SystemClock.uptimeMillis();
    return MotionEvent.obtain(t, t, action, 0f, 0f, 0);
  }

  // ---- (a) scrollEventThrottle → the honoured sample floor -----------------------------------

  @Test
  public void throttle_zeroOrUnsetIsTheFrameCap() {
    CanopyScrollView sv = make();
    assertEquals("unset ⇒ frame cap", CanopyScrollView.FRAME_MS, sv.throttleFloorMs());
    sv.setScrollEventThrottle(0);
    assertEquals("0 ⇒ frame cap", CanopyScrollView.FRAME_MS, sv.throttleFloorMs());
  }

  @Test
  public void throttle_positiveValueIsHonouredAsFloor() {
    CanopyScrollView sv = make();
    sv.setScrollEventThrottle(100);
    assertEquals(100, sv.throttleFloorMs());
    // a negative throttle is clamped to 0 ⇒ falls back to the frame cap
    sv.setScrollEventThrottle(-5);
    assertEquals(CanopyScrollView.FRAME_MS, sv.throttleFloorMs());
  }

  // ---- (b) the scroll + offset JSON payloads --------------------------------------------------

  @Test
  public void scrollJson_isWellFormedAndCarriesTheRnFields() throws JSONException {
    CanopyScrollView sv = make();
    JSONObject o = new JSONObject(sv.scrollJson(0, 0)); // must parse → well-formed JSON
    assertTrue(o.has("x"));
    assertTrue(o.has("y"));
    assertTrue(o.has("contentWidth"));
    assertTrue(o.has("contentHeight"));
    assertTrue(o.has("viewportWidth"));
    assertTrue(o.has("viewportHeight"));
  }

  @Test
  public void offsetJson_axisDependsOnOrientation() throws JSONException {
    CanopyScrollView sv = make();
    // vertical (default): {"y":..}
    JSONObject v = new JSONObject(sv.offsetJson(0));
    assertTrue(v.has("y"));
    assertFalse(v.has("x"));
    // horizontal: {"x":..}
    sv.setHorizontal(true);
    assertTrue(sv.isHorizontal());
    JSONObject h = new JSONObject(sv.offsetJson(0));
    assertTrue(h.has("x"));
    assertFalse(h.has("y"));
  }

  // ---- (c) the momentum-begin transition ------------------------------------------------------

  // A scroll sample arriving with the finger OFF the scroller is a fling start: inMomentum flips on
  // (announced once). The default handle = -1 / emitMomentum = false means no native emit fires.
  @Test
  public void momentum_offTouchSampleStartsTheFling() {
    CanopyScrollView sv = make();
    sv.trackTouch(ev(MotionEvent.ACTION_DOWN));
    sv.trackTouch(ev(MotionEvent.ACTION_UP));     // finger lifted → subsequent motion is momentum
    assertFalse(sv.inMomentumForTest());
    sv.onScrolledForTest(0, 10);                  // a fling sample
    assertTrue("off-touch sample begins the fling", sv.inMomentumForTest());
  }

  // A fresh ACTION_DOWN cancels any prior fling phase (re-arms momentum-begin for the next fling).
  @Test
  public void momentum_freshTouchReArmsTheFling() {
    CanopyScrollView sv = make();
    sv.trackTouch(ev(MotionEvent.ACTION_DOWN));
    sv.trackTouch(ev(MotionEvent.ACTION_UP));
    sv.onScrolledForTest(0, 10);
    assertTrue(sv.inMomentumForTest());
    sv.trackTouch(ev(MotionEvent.ACTION_DOWN));   // user grabs the list again
    assertFalse("a new touch cancels the prior fling phase", sv.inMomentumForTest());
  }

  // A scroll sample while the finger is DOWN is NOT a fling (a drag, not momentum).
  @Test
  public void momentum_onTouchSampleIsNotAFling() {
    CanopyScrollView sv = make();
    sv.trackTouch(ev(MotionEvent.ACTION_DOWN));
    sv.onScrolledForTest(0, 10);                  // a finger-down drag sample
    assertFalse("a drag sample is not a fling", sv.inMomentumForTest());
  }

  // ---- (d) controlled contentOffset echo-guard ------------------------------------------------

  // setContentOffset arms the echo-guard so the ONE programmatic scroll sample it produces is
  // swallowed (does not start a phantom fling / re-emit).
  @Test
  public void contentOffset_swallowsTheProgrammaticEcho() {
    CanopyScrollView sv = make();
    sv.trackTouch(ev(MotionEvent.ACTION_DOWN));
    sv.trackTouch(ev(MotionEvent.ACTION_UP));     // off-touch: an unguarded sample WOULD start a fling
    sv.setContentOffset(0, 40, false);            // programmatic → arms the guard
    sv.onScrolledForTest(0, 40);                  // the echo sample
    assertFalse("the programmatic echo is swallowed, no phantom fling", sv.inMomentumForTest());
    // the guard is one-shot: a subsequent genuine off-touch sample DOES start a fling
    sv.onScrolledForTest(0, 80);
    assertTrue(sv.inMomentumForTest());
  }

  // ---- (e) keyboardDismissMode recording ------------------------------------------------------

  @Test
  public void keyboardDismissMode_recordsValueWithNoneDefault() {
    CanopyScrollView sv = make();
    assertEquals("none", sv.keyboardDismissMode());
    sv.setKeyboardDismissMode("on-drag");
    assertEquals("on-drag", sv.keyboardDismissMode());
    sv.setKeyboardDismissMode(null);              // a recycled view that dropped the prop
    assertEquals("none", sv.keyboardDismissMode());
  }
}
