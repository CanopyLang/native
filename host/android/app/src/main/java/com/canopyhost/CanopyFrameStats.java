// CanopyFrameStats.java — RND-4: the pure frame-timing accumulator (device-free).
//
// This is the math half of the on-device frame instrumentation. CanopyFrameMetrics feeds it raw
// per-frame nanosecond intervals from the real Choreographer; this class turns that stream into the
// numbers the perf question actually needs:
//
//   "Does a windowed list scroll at 60fps once lazy is fixed?"  ->  jank% + p50/p95/p99 frame time.
//
// A "frame" here is the wall-clock gap between two consecutive vsync callbacks (Choreographer
// doFrame deltas). On a healthy 60Hz surface that gap is ~16.67ms; a gap materially longer than the
// refresh interval means the UI thread missed a vsync (a dropped/janky frame the user sees as a
// stutter). We count those at several thresholds and keep an exact-percentile histogram of the
// gaps, so a single scripted-fling run yields a comparable jank ledger.
//
// WHY A SEPARATE PURE CLASS (mirrors CanopyCompletionScheduler): the Choreographer driver needs a
// device; the accumulation/percentile/jank logic does not. Keeping it here, with NO android import,
// makes the entire metric algorithm unit-testable on the host JVM (CanopyFrameStatsTest) — the same
// device-free-core discipline the AND-9 scheduler uses.
//
// THREADING: every method is called from the Choreographer callback (the UI thread) except the
// snapshot reads, which the dump path may call from another thread; snapshot() is synchronized with
// record() so a dump taken mid-fling sees a consistent histogram, never a torn count.
//
// MEMORY: the histogram is a fixed bucketed array (sub-millisecond resolution up to a cap, then one
// overflow bucket), so a multi-minute capture allocates nothing per frame — no growing sample list.

package com.canopyhost;

import org.json.JSONArray;
import org.json.JSONObject;

/** Pure per-frame interval accumulator: jank counts + exact-ish percentiles, no Android deps. */
public final class CanopyFrameStats {

  // The nominal 60Hz vsync interval. A frame whose interval exceeds this missed a vsync. We keep it
  // configurable (high-refresh panels report a smaller interval) but default to 60Hz, the worst case
  // for a "is it smooth?" question and the refresh rate of the x86_64 emulator this runs on.
  public static final double VSYNC_60HZ_MS = 1000.0 / 60.0; // 16.667ms

  // Jank thresholds (ms). >refresh = "missed ONE vsync" (a single dropped frame, the basic jank
  // signal); the multi-frame buckets surface the severe hitches that a list-fling reveals.
  private final double refreshMs;
  private final double oneMiss;   // > 1 refresh  (any dropped frame)
  private final double twoMiss;   // > 2 refresh  (a visible stutter)
  private final double fourMiss;  // > 4 refresh  (a severe hitch, ~ >66ms at 60Hz)

  // Histogram: bucket index = floor(ms * BUCKETS_PER_MS), capped at OVERFLOW_BUCKET. 0.25ms
  // resolution to MAX_TRACKED_MS gives exact-enough percentiles for frame timing without a sample
  // list. Anything slower than the cap lands in the overflow bucket (still counted for jank/max).
  static final int BUCKETS_PER_MS = 4;          // 0.25ms resolution
  static final int MAX_TRACKED_MS = 200;        // frames slower than 200ms overflow (still counted)
  static final int OVERFLOW_BUCKET = MAX_TRACKED_MS * BUCKETS_PER_MS;
  private final long[] hist = new long[OVERFLOW_BUCKET + 1];

  private long frames = 0;
  private long jankOne = 0, jankTwo = 0, jankFour = 0;
  private double sumMs = 0.0;
  private double maxMs = 0.0;
  private long overflowFrames = 0;

  public CanopyFrameStats() { this(VSYNC_60HZ_MS); }

  public CanopyFrameStats(double refreshMs) {
    this.refreshMs = refreshMs;
    this.oneMiss = refreshMs;
    this.twoMiss = refreshMs * 2.0;
    this.fourMiss = refreshMs * 4.0;
  }

  /** Record one inter-vsync interval in nanoseconds (the gap between two doFrame callbacks). A
   *  non-positive or absurd interval (first frame, a clock glitch, app backgrounded) is ignored so
   *  it can never invent a fake hitch. */
  public synchronized void recordIntervalNanos(long nanos) {
    if (nanos <= 0) return;
    double ms = nanos / 1_000_000.0;
    // A gap of multiple seconds is the app having been paused/backgrounded, not a rendered frame —
    // dropping it keeps "jank during the fling" honest (we only ever drive frames while interacting).
    if (ms > 1000.0) return;

    frames++;
    sumMs += ms;
    if (ms > maxMs) maxMs = ms;
    if (ms > oneMiss) jankOne++;
    if (ms > twoMiss) jankTwo++;
    if (ms > fourMiss) jankFour++;

    int b = (int) Math.floor(ms * BUCKETS_PER_MS);
    if (b >= OVERFLOW_BUCKET) { hist[OVERFLOW_BUCKET]++; overflowFrames++; }
    else if (b < 0) hist[0]++;
    else hist[b]++;
  }

  /** Convenience for callers holding two absolute vsync timestamps (Choreographer frameTimeNanos). */
  public void recordFrame(long prevVsyncNanos, long thisVsyncNanos) {
    recordIntervalNanos(thisVsyncNanos - prevVsyncNanos);
  }

  public synchronized long frameCount() { return frames; }

  /** Dropped-frame counts at each vsync-miss threshold (1x/2x/4x refresh). Exposed directly (not
   *  only via JSON) so the device-free unit test can assert the jank math without org.json. */
  public synchronized long jankFrames()   { return jankOne; }
  public synchronized long jankFrames2x() { return jankTwo; }
  public synchronized long jankFrames4x() { return jankFour; }
  public synchronized long overflowFrames() { return overflowFrames; }

  /** Exact-as-bucketed percentile (ms) over the recorded frame intervals. p in [0,100]. */
  public synchronized double percentileMs(double p) {
    if (frames == 0) return 0.0;
    long target = (long) Math.ceil((p / 100.0) * frames);
    if (target < 1) target = 1;
    long cum = 0;
    for (int i = 0; i <= OVERFLOW_BUCKET; i++) {
      cum += hist[i];
      if (cum >= target) {
        if (i == OVERFLOW_BUCKET) return MAX_TRACKED_MS; // floor for the overflow tail
        // bucket midpoint, in ms
        return (i + 0.5) / BUCKETS_PER_MS;
      }
    }
    return maxMs;
  }

  public synchronized double meanMs() { return frames == 0 ? 0.0 : sumMs / frames; }
  public synchronized double maxFrameMs() { return maxMs; }

  /** Fraction (0..1) of frames that missed at least one vsync — the headline jank metric. */
  public synchronized double jankFraction() { return frames == 0 ? 0.0 : (double) jankOne / frames; }

  /** Reset all counters (the dump path resets between scripted segments so each fling is isolated). */
  public synchronized void reset() {
    frames = 0; jankOne = 0; jankTwo = 0; jankFour = 0;
    sumMs = 0.0; maxMs = 0.0; overflowFrames = 0;
    java.util.Arrays.fill(hist, 0L);
  }

  /** Render the accumulated stats to a JSON object the harness (harness/perf-report.js) parses.
   *  `label` tags the segment (e.g. "list-fling"); `extra` carries caller context (rows, host op
   *  counts) and may be null. Effective frame rate is frames/elapsed when an elapsed is supplied. */
  public synchronized JSONObject toJson(String label, JSONObject extra) {
    JSONObject o = new JSONObject();
    try {
      o.put("label", label == null ? "" : label);
      o.put("refreshHz", Math.round(1000.0 / refreshMs));
      o.put("refreshMs", round3(refreshMs));
      o.put("frames", frames);
      o.put("jankFrames", jankOne);          // > 1 refresh
      o.put("jankFrames2x", jankTwo);         // > 2 refresh
      o.put("jankFrames4x", jankFour);        // > 4 refresh
      o.put("jankPct", round3(jankFraction() * 100.0));
      o.put("p50Ms", round3(percentileMs(50)));
      o.put("p90Ms", round3(percentileMs(90)));
      o.put("p95Ms", round3(percentileMs(95)));
      o.put("p99Ms", round3(percentileMs(99)));
      o.put("meanMs", round3(meanMs()));
      o.put("maxMs", round3(maxMs));
      o.put("overflowFrames", overflowFrames);
      // The whole point of RND-4's "label as upper-bound-on-jank" note: emulator timings are a
      // ceiling on real-device jank, never a floor. Carry that caveat IN the data so a downstream
      // reader (perf-report.js, a CI gate) can never mistake an emulator number for a device number.
      o.put("caveat", "emulator/x86_64 frame timings are an UPPER BOUND on real-device jank "
          + "(no GPU compositor parity, host-scheduler noise) — not a device measurement");
      if (extra != null) o.put("context", extra);
    } catch (Exception e) {
      // org.json on a pure JVM never throws here for these types; tolerate defensively.
    }
    return o;
  }

  /** A compact histogram (only non-empty buckets) for offline inspection — used by the dump file. */
  public synchronized JSONArray histogramJson() {
    JSONArray arr = new JSONArray();
    try {
      for (int i = 0; i <= OVERFLOW_BUCKET; i++) {
        if (hist[i] == 0) continue;
        JSONObject b = new JSONObject();
        double lo = (double) i / BUCKETS_PER_MS;
        b.put("ms", round3(lo));
        b.put("count", hist[i]);
        if (i == OVERFLOW_BUCKET) b.put("overflow", true);
        arr.put(b);
      }
    } catch (Exception ignored) { }
    return arr;
  }

  private static double round3(double v) { return Math.round(v * 1000.0) / 1000.0; }
}
