// CanopyFrameStatsTest.java — JVM unit test for the RND-4 frame-timing accumulator.
//
// Runs on the host JVM via `:app:testDebugUnitTest` (no device). The device half of RND-4 (the real
// Choreographer hook, the scripted fling) needs an emulator; what IS unit-testable here, device-free,
// is the MATH that turns a stream of inter-vsync intervals into the jank ledger: the dropped-frame
// counts at each threshold, and the p50/p95/p99 frame-time percentiles. That algorithm is the whole
// substance of "is the list scrolling at 60fps?" — so we pin it directly, the same device-free-core
// discipline CanopyCompletionSchedulerTest uses for AND-9.

package com.canopyhost;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

// NOTE: org.json is part of the Android framework and is STUBBED on the plain JVM (the app's
// testOptions.unitTests.returnDefaultValues=true makes every org.json call return a default). So
// these device-free tests assert against CanopyFrameStats' DIRECT numeric accessors — the actual
// jank/percentile math — not its JSON serialization (whose org.json round-trip is exercised on
// device, where the framework org.json is real). That is exactly why CanopyFrameStats exposes
// jankFrames()/percentileMs()/frameCount() as first-class methods alongside toJson().

public final class CanopyFrameStatsTest {

  private static final long MS = 1_000_000L; // ns per ms
  private static final double R = CanopyFrameStats.VSYNC_60HZ_MS; // ~16.667ms

  /** A perfectly smooth 60fps stream: every frame ~16.67ms → zero jank, p50 ≈ refresh. */
  @Test
  public void smooth60fps_hasNoJank() {
    CanopyFrameStats s = new CanopyFrameStats();
    for (int i = 0; i < 600; i++) s.recordIntervalNanos((long) (R * MS)); // exactly one refresh
    assertEquals(600, s.frameCount());
    // A frame == one refresh is NOT a miss (jank is strictly > refresh), so zero jank.
    assertEquals(0.0, s.jankFraction(), 0.0);
    assertEquals(R, s.percentileMs(50), 0.5);  // bucket resolution is 0.25ms
  }

  /** A run with a known fraction of dropped frames reports that fraction at the 1x threshold. */
  @Test
  public void jankFraction_matchesInjectedDrops() {
    CanopyFrameStats s = new CanopyFrameStats();
    // 90 good frames (~16ms) + 10 doubled frames (~33ms, one missed vsync) = 10% jank.
    for (int i = 0; i < 90; i++) s.recordIntervalNanos(16 * MS);
    for (int i = 0; i < 10; i++) s.recordIntervalNanos(33 * MS);
    assertEquals(100, s.frameCount());
    assertEquals(0.10, s.jankFraction(), 1e-9);
    assertEquals(10L, s.jankFrames()); // all 10 doubled frames miss at least one vsync
  }

  /** Multi-threshold buckets: a 70ms hitch counts at 1x, 2x AND 4x; a 33ms only at 1x. */
  @Test
  public void multiThreshold_buckets() {
    CanopyFrameStats s = new CanopyFrameStats();
    for (int i = 0; i < 50; i++) s.recordIntervalNanos(16 * MS); // smooth
    s.recordIntervalNanos(33 * MS);  // > 1x (and ~2x boundary)
    s.recordIntervalNanos(70 * MS);  // > 4x (66.7ms)
    assertEquals(2L, s.jankFrames());   // both the 33 and 70 miss at least one vsync
    assertEquals(1L, s.jankFrames4x()); // only the 70ms is a severe (>4x) hitch
    assertTrue("max must capture the worst frame", s.maxFrameMs() >= 69.0);
  }

  /** Percentiles separate the smooth body from a heavy jank tail. */
  @Test
  public void percentiles_reflectTail() {
    CanopyFrameStats s = new CanopyFrameStats();
    for (int i = 0; i < 95; i++) s.recordIntervalNanos(16 * MS); // smooth body
    for (int i = 0; i < 5; i++) s.recordIntervalNanos(50 * MS);  // 5% heavy tail
    double p50 = s.percentileMs(50);
    double p99 = s.percentileMs(99);
    assertTrue("p50 should sit in the smooth body (~16ms), was " + p50, p50 >= 15.5 && p50 <= 16.75);
    assertTrue("p99 should land in the 50ms tail, was " + p99, p99 >= 49.0 && p99 <= 51.0);
  }

  /** Garbage intervals (first-frame zero, a multi-second background gap) must not invent jank. */
  @Test
  public void ignoresNonFrameIntervals() {
    CanopyFrameStats s = new CanopyFrameStats();
    s.recordIntervalNanos(0);          // first-frame / no prior vsync
    s.recordIntervalNanos(-5 * MS);    // clock glitch
    s.recordIntervalNanos(5000 * MS);  // 5s app-backgrounded gap
    for (int i = 0; i < 10; i++) s.recordIntervalNanos(16 * MS);
    assertEquals("only the 10 real frames count", 10, s.frameCount());
    assertEquals(0.0, s.jankFraction(), 0.0);
  }

  /** reset() clears everything so each scripted segment is isolated. */
  @Test
  public void reset_isolatesSegments() {
    CanopyFrameStats s = new CanopyFrameStats();
    for (int i = 0; i < 20; i++) s.recordIntervalNanos(40 * MS);
    assertTrue(s.jankFraction() > 0.9);
    s.reset();
    assertEquals(0, s.frameCount());
    assertEquals(0.0, s.jankFraction(), 0.0);
    for (int i = 0; i < 10; i++) s.recordIntervalNanos(16 * MS);
    assertEquals(0.0, s.jankFraction(), 0.0);
  }

  /** The overflow bucket still counts an absurdly slow (but sub-second) frame as jank, and max is
   *  floored at the tracked cap so percentiles never silently drop the tail. */
  @Test
  public void overflowFrame_stillCounts() {
    CanopyFrameStats s = new CanopyFrameStats();
    for (int i = 0; i < 30; i++) s.recordIntervalNanos(16 * MS);
    s.recordIntervalNanos(300 * MS); // past MAX_TRACKED_MS (200) but < 1s → overflow, still real
    assertEquals(31, s.frameCount());
    assertEquals(1L, s.jankFrames4x());
    assertEquals(1L, s.overflowFrames());
    assertTrue("max captures the overflow frame", s.maxFrameMs() >= 200.0);
    // The overflow frame still pulls the high percentile into the slow tail.
    assertTrue("p99 lands in the slow tail", s.percentileMs(99) >= 200.0);
  }
}
