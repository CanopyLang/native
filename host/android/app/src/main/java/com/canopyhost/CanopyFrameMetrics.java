// CanopyFrameMetrics.java — RND-4: on-device frame instrumentation (Android).
//
// The Choreographer half of the frame instrumentation. A SINGLE Choreographer.FrameCallback runs on
// the UI thread; each vsync it measures the gap since the previous vsync and feeds it to the pure
// CanopyFrameStats accumulator. The result answers the one perf question a device alone can settle:
// "does a windowed list fling at 60fps?" — by counting frames that missed a vsync (jank) during a
// scripted fling and reporting p50/p95/p99 frame time.
//
// WHY A WHOLE-HOST FRAME LOOP (and not per-installFn timers): the RND-4 plan also calls for ns
// timers wrapping each CanopyFabric.cpp installFn → __canopy_perfDump. That C++ JSI surface lives in
// the shared/cpp lane (host/shared/cpp/CanopyFabric.cpp), NOT this Java host lane, so it is wired
// there. What is unambiguously the Android host's job — and the part that actually measures rendered
// frames, which a JS-CPU timer cannot — is THIS: hook the real Choreographer and count dropped
// frames during interaction. The two are complementary: the C++ timers attribute JS/host CPU cost
// per mutation; this attributes the user-visible result (jank) to the whole frame.
//
// COMPILED OUT OF RELEASE (the plan's CANOPY_PERF guard): instrumentation only attaches when BOTH
//   (a) this is a DEBUG build (BuildConfig.DEBUG == false in release), AND
//   (b) the runtime opt-in flag is set: `adb shell setprop debug.canopy.perf 1` (or the env
//       CANOPY_PERF=1 picked up by perf-android.sh).
// Because the guard's first term is BuildConfig.DEBUG — a compile-time `false` in release — R8 sees
// ENABLED as a constant `false` in a release build and dead-strips the whole frame-callback path:
// no Choreographer hook, no per-frame work, nothing ships. This achieves "compiled out of release"
// without touching the build.gradle owned by the build lane; the dev/CI perf run (always a debug
// APK) gets the full instrumentation. Even in debug, NOTHING runs until the prop is set, so a normal
// debug session pays zero per-frame cost.
//
// THREADING: start()/stop()/the doFrame callback all run on the UI/main thread (Choreographer fires
// doFrame there, and start() is called from MainActivity.onCreate on the main thread). dumpNow() may
// be invoked from a binder/shell thread (the perf script triggers it); CanopyFrameStats.snapshot/
// toJson are synchronized, so a dump taken mid-fling is consistent.

package com.canopyhost;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.Choreographer;

import org.json.JSONObject;

import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;

/** Choreographer-driven per-frame jank/timing capture, feeding the pure CanopyFrameStats. */
public final class CanopyFrameMetrics implements Choreographer.FrameCallback {

  static final String TAG = "CanopyPerf";

  // THE COMPILE-OUT GATE. This is the PURE BuildConfig.DEBUG constant — nothing else. R8 sees it as
  // a literal `false` in a release build, so every `if (!ENABLED) return;` guard below (and in
  // MainActivity) folds to an unconditional early-return and the per-frame body is dead-stripped.
  // It MUST stay a bare `= BuildConfig.DEBUG` (no method call in the initializer) for that folding to
  // happen — mixing in a runtime check here is what keeps R8 from proving the branch dead. The
  // runtime opt-in (the setprop) is a SEPARATE check done at install time, gated behind this constant,
  // so an ordinary debug run still does zero per-frame work until the flag is set.
  public static final boolean ENABLED = BuildConfig.DEBUG;

  /** Opt-in runtime flag, read at install time (only ever reached in a DEBUG build). `setprop
   *  debug.canopy.perf 1` (survives until reboot) OR the CANOPY_PERF env the perf script exports.
   *  Defaults OFF, so a normal debug session never attaches the Choreographer hook. */
  private static boolean perfRequested() {
    try {
      String p = System.getProperty("debug.canopy.perf", "");
      if (p == null || p.isEmpty()) p = readSystemProp("debug.canopy.perf");
      if (p == null || p.isEmpty()) p = System.getenv("CANOPY_PERF");
      return p != null && (p.equals("1") || p.equalsIgnoreCase("true") || p.equalsIgnoreCase("on"));
    } catch (Throwable t) {
      return false;
    }
  }

  /** Android system properties are not visible via System.getProperty; read via the framework. */
  private static String readSystemProp(String key) {
    try {
      Class<?> sp = Class.forName("android.os.SystemProperties");
      return (String) sp.getMethod("get", String.class).invoke(null, key);
    } catch (Throwable t) {
      return "";
    }
  }

  private final Context appContext;
  private final CanopyFrameStats stats;
  private final Handler main = new Handler(Looper.getMainLooper());

  private boolean running = false;
  private long lastVsyncNanos = 0L;
  private long startedAtNanos = 0L;
  private String segment = "all";

  // Optional host-op probe so a dump can correlate jank with host mutation volume during the same
  // window (set by CanopyHost if available). Kept as a Supplier to avoid a hard back-dependency.
  public interface LongProbe { long get(); }
  private LongProbe hostOpProbe = null;

  private static CanopyFrameMetrics sInstance;

  /** The process-wide instance (created by MainActivity when ENABLED). May be null. */
  public static CanopyFrameMetrics get() { return sInstance; }

  /** Install + start the frame instrumentation if ENABLED; otherwise a cheap no-op returning null.
   *  Called from MainActivity.onCreate. Idempotent. */
  public static CanopyFrameMetrics installIfEnabled(Context ctx) {
    if (!ENABLED) return null;          // release: R8 folds this to `return null` and strips the rest
    if (!perfRequested()) return null;  // debug, flag unset: no Choreographer hook, zero per-frame work
    if (sInstance == null) {
      sInstance = new CanopyFrameMetrics(ctx.getApplicationContext());
      sInstance.start("boot");
      Log.i(TAG, "frame instrumentation ON (debug.canopy.perf set). "
          + "Dump: am broadcast -a com.canopyhost.PERF_DUMP, or adb shell setprop debug.canopy.perf.dump 1");
    }
    return sInstance;
  }

  private CanopyFrameMetrics(Context appContext) {
    this.appContext = appContext;
    this.stats = new CanopyFrameStats();
  }

  public void setHostOpProbe(LongProbe p) { this.hostOpProbe = p; }

  public CanopyFrameStats stats() { return stats; }

  /** Begin a fresh capture segment: reset stats, label it, and arm the Choreographer. */
  public synchronized void start(String label) {
    this.segment = label == null ? "all" : label;
    stats.reset();
    lastVsyncNanos = 0L;
    startedAtNanos = System.nanoTime();
    if (!running) {
      running = true;
      Choreographer.getInstance().postFrameCallback(this);
    }
  }

  /** Stop arming new frame callbacks (the in-flight one will see running==false and not re-post). */
  public synchronized void stop() { running = false; }

  @Override
  public void doFrame(long frameTimeNanos) {
    if (lastVsyncNanos != 0L) {
      stats.recordIntervalNanos(frameTimeNanos - lastVsyncNanos);
    }
    lastVsyncNanos = frameTimeNanos;
    // Re-arm only while running. A continuously-armed callback is exactly how Choreographer reports
    // the device's real frame cadence: between rendered frames doFrame still fires at vsync, so a UI
    // thread blocked past a vsync shows up as a long gap here — the jank we want to count.
    if (running) Choreographer.getInstance().postFrameCallback(this);
  }

  /** Build the dump JSON (segment stats + context). Safe to call off the UI thread. */
  public JSONObject snapshotJson() {
    JSONObject ctx = new JSONObject();
    try {
      double elapsedMs = (System.nanoTime() - startedAtNanos) / 1_000_000.0;
      ctx.put("segment", segment);
      ctx.put("elapsedMs", Math.round(elapsedMs * 1000.0) / 1000.0);
      long fc = stats.frameCount();
      ctx.put("effectiveFps", elapsedMs > 0 ? Math.round((fc / (elapsedMs / 1000.0)) * 100.0) / 100.0 : 0);
      if (hostOpProbe != null) ctx.put("hostOps", hostOpProbe.get());
      ctx.put("abi", android.os.Build.SUPPORTED_ABIS != null && android.os.Build.SUPPORTED_ABIS.length > 0
          ? android.os.Build.SUPPORTED_ABIS[0] : "unknown");
      ctx.put("device", android.os.Build.MODEL + " / api" + android.os.Build.VERSION.SDK_INT);
    } catch (Exception ignored) { }
    JSONObject out = stats.toJson(segment, ctx);
    try { out.put("histogram", stats.histogramJson()); } catch (Exception ignored) { }
    return out;
  }

  /** Write the dump to logcat AND to a file under the app's external files dir, where the perf
   *  script (scripts/perf-android.sh) pulls it. Returns the file path, or null on failure. */
  public String dumpNow() {
    JSONObject out = snapshotJson();
    String json = out.toString();
    Log.i(TAG, "PERF_DUMP " + json);   // logcat path: greppable by perf-android.sh as a fallback
    try {
      File dir = appContext.getExternalFilesDir("perf");
      if (dir == null) return null;
      if (!dir.exists()) dir.mkdirs();
      File f = new File(dir, "frame-metrics.json");
      try (FileOutputStream fos = new FileOutputStream(f)) {
        fos.write(json.getBytes(StandardCharsets.UTF_8));
      }
      Log.i(TAG, "PERF_DUMP written -> " + f.getAbsolutePath());
      return f.getAbsolutePath();
    } catch (Exception e) {
      Log.w(TAG, "perf dump file write failed: " + e);
      return null;
    }
  }
}
