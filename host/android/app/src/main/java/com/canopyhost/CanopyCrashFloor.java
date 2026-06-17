// CanopyCrashFloor.java — REL-2: the Android crash FLOOR (JVM half).
//
// WHAT THIS IS (and is NOT). The existing red-box (CanopyRedBox + the C++ guardJsCall seam) catches
// RECOVERABLE errors — a JSI/native exception that is *thrown and caught* at a host↔JS re-entry point —
// and shows an overlay instead of letting it std::terminate() into a SIGABRT. This class is the
// complementary LAST RESORT for the UNRECOVERABLE case the red-box cannot reach: a Java Throwable that
// escapes a thread with no guard on its stack (a wrong-thread view write, an OOM, a module bug on a
// worker thread). Those today go straight to Android's default handler → a bare FATAL EXCEPTION + a
// silent process kill, with NO record keyed to the build the user was running.
//
// WHAT IT DOES. install() sets a JVM Thread.UncaughtExceptionHandler that writes a small, buildId-keyed
// crash record (JSON, under filesDir/crashes/) and then ALWAYS chains the previously-installed default
// handler — so the OS still produces its tombstone/logcat and kills the process. We never swallow a
// crash; we only leave a breadcrumb the next launch (drainPending) can surface to the REL-4 crash-free
// metric / a future TEL-1 sink. This runs on a still-functioning JVM (the crash is a Java Throwable,
// not a corrupt-memory signal), so ordinary file I/O here is safe — there is NO async-signal constraint.
//
// SCOPE. This is the JVM half only. A native NDK signal handler (SIGSEGV/SIGABRT) for hard crashes is
// deliberately NOT shipped here: in an async-signal context almost everything is unsafe (no heap, no
// locks, no JNI), a buggy handler is strictly WORSE than none, and it cannot be validated without a
// device. The honest interim posture for native signals is the OS tombstone + Play's native collection;
// see docs/guarantee.md caveat (host signals) and plans/MASTER-PLAN.md REL-2.
package com.canopyhost;

import android.content.Context;
import android.util.Log;

import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;

/** REL-2 JVM crash floor: persist a buildId-keyed record for an uncaught Throwable, then chain the
 *  prior default handler. All methods are static + fully defensive (they must never themselves throw). */
public final class CanopyCrashFloor {

  private static final String TAG = "CanopyCrashFloor";
  // TEL-1: the on-disk telemetry RING (no-network default). Holds both the per-launch session-start
  // beacons (the crash-free denominator) and the crash records (the numerator); capped + pruned.
  private static final String DIR = "telemetry";
  private static final int MAX_RECORDS = 200;  // cap on-disk growth; oldest are pruned on install.

  // The anonymous per-process-launch id (random UUID; never device-stable, no PII) that ties a crash
  // to its session so REL-4 can compute crash-free = 1 - sessions-with-fatal / total-sessions.
  private static volatile String sSessionId = "";
  private static volatile boolean sInstalled = false;

  private CanopyCrashFloor() {}

  /** Install the JVM uncaught-exception handler. Idempotent. {@code buildId} is the content-addressed
   *  bundle id (the REL-4 crash-free key); pass "unknown" if it could not be read. Safe to call early
   *  in onCreate — the handler captures and CHAINS whatever default was set before us. */
  public static synchronized void install(final Context ctx, final String buildId) {
    if (sInstalled || ctx == null) return;
    sInstalled = true;
    final Context app = ctx.getApplicationContext();
    final String bid = (buildId == null || buildId.isEmpty()) ? "unknown" : buildId;
    // BuildConfig.VERSION_CODE is a compile-time int (no API-level / PackageManager call) — safe on
    // every minSdk and never throws from inside the handler.
    final long versionCode = BuildConfig.VERSION_CODE;
    final Thread.UncaughtExceptionHandler prior = Thread.getDefaultUncaughtExceptionHandler();

    sSessionId = java.util.UUID.randomUUID().toString();
    final String sid = sSessionId;

    pruneOldRecords(app);          // bound disk growth BEFORE installing (off the crash path).
    writeSessionStart(app, bid, versionCode, sid);   // TEL-1: the crash-free denominator beacon.

    // REL-2 SIG (the native hard-crash half): OFF BY DEFAULT. A buggy async-signal handler is a net
    // reliability regression and a hard signal already yields an OS tombstone — so install the native
    // floor ONLY under the CANOPY_SIGNAL_FLOOR opt-in (device-validation lane). Records to the SAME
    // telemetry dir. Wrapped so a missing lib / link error can never worsen boot.
    if (System.getenv("CANOPY_SIGNAL_FLOOR") != null) {
      try {
        File tdir = new File(app.getFilesDir(), DIR);
        if (tdir.exists() || tdir.mkdirs()) {
          CanopyHostJni.installSignalFloor(tdir.getAbsolutePath(), bid, sid, source());
          Log.i(TAG, "SIG native signal floor installed (opt-in)");
        }
      } catch (Throwable t) {
        Log.w(TAG, "SIG native signal floor unavailable (continuing without it): " + t);
      }
    }

    Thread.setDefaultUncaughtExceptionHandler((thread, throwable) -> {
      try {
        writeRecord(app, bid, versionCode, sid, thread, throwable);
      } catch (Throwable ignored) {
        // The floor must NEVER make a crash worse. Swallow any failure to record and fall through to
        // the prior handler so the OS still gets its clean tombstone + kill.
      }
      // ALWAYS chain — never swallow the crash. If there was no prior handler, re-raise so the default
      // termination proceeds (a swallowed uncaught exception would hang the dead thread).
      if (prior != null) {
        prior.uncaughtException(thread, throwable);
      } else {
        // No prior handler: kill the process the way the platform default would.
        android.os.Process.killProcess(android.os.Process.myPid());
        System.exit(10);
      }
    });
    Log.i(TAG, "crash floor installed (buildId " + safeShort(bid) + ", versionCode " + versionCode + ")");
  }

  /** Serialize one crash event (schema 2) to the telemetry ring. Keyed by buildId + platform +
   *  sessionId so REL-4 can decrement the right per-build crash-free numerator exactly once. */
  private static void writeRecord(Context app, String buildId, long versionCode, String sessionId,
                                  Thread thread, Throwable t) throws Exception {
    File dir = new File(app.getFilesDir(), DIR);
    if (!dir.exists() && !dir.mkdirs()) return;
    long ts = System.currentTimeMillis();
    // Include the thread id so a cascading MULTI-THREAD crash in the same millisecond writes distinct
    // files instead of overwriting each other (the exact scenario this floor exists to capture).
    long tid = thread == null ? 0L : thread.getId();
    File out = new File(dir, "crash-" + buildId + "-" + ts + "-" + tid + ".json");
    String json = "{"
        + "\"schema\":2"
        + ",\"eventType\":\"crash\""
        + ",\"kind\":\"jvm-uncaught\""
        + ",\"platform\":\"android\""
        + ",\"buildId\":\"" + esc(buildId) + "\""
        + ",\"sessionId\":\"" + esc(sessionId) + "\""
        + ",\"appVersion\":\"" + versionCode + "\""
        + ",\"source\":\"" + source() + "\""
        + ",\"timestampMs\":" + ts
        + ",\"thread\":\"" + esc(thread == null ? "?" : thread.getName()) + "\""
        + ",\"errorClass\":\"" + esc(t == null ? "?" : t.getClass().getName()) + "\""
        + ",\"message\":\"" + esc(t == null ? "" : String.valueOf(t.getMessage())) + "\""
        + ",\"frames\":" + framesJson(t)
        + ",\"fatal\":true"
        + "}";
    try (FileOutputStream fos = new FileOutputStream(out)) {
      fos.write(json.getBytes(StandardCharsets.UTF_8));
    }
  }

  /** TEL-1: write the per-launch session-start beacon (the crash-free DENOMINATOR). Runs once at
   *  install on a healthy JVM, so ordinary file I/O is safe (no async-signal constraint). */
  private static void writeSessionStart(Context app, String buildId, long versionCode, String sessionId) {
    try {
      File dir = new File(app.getFilesDir(), DIR);
      if (!dir.exists() && !dir.mkdirs()) return;
      long ts = System.currentTimeMillis();
      File out = new File(dir, "session-" + sessionId + ".json");
      String json = "{"
          + "\"schema\":2"
          + ",\"eventType\":\"session-start\""
          + ",\"platform\":\"android\""
          + ",\"buildId\":\"" + esc(buildId) + "\""
          + ",\"sessionId\":\"" + esc(sessionId) + "\""
          + ",\"appVersion\":\"" + versionCode + "\""
          + ",\"osVersion\":\"" + esc("Android " + android.os.Build.VERSION.RELEASE) + "\""
          + ",\"source\":\"" + source() + "\""
          + ",\"timestampMs\":" + ts
          + "}";
      try (FileOutputStream fos = new FileOutputStream(out)) {
        fos.write(json.getBytes(StandardCharsets.UTF_8));
      }
    } catch (Throwable ignored) { /* a missing beacon must never block boot */ }
  }

  /** The headline crash-free metric is only computed from "device" events; an emulator is caveated. */
  private static String source() {
    try {
      String fp = android.os.Build.FINGERPRINT == null ? "" : android.os.Build.FINGERPRINT;
      String prod = android.os.Build.PRODUCT == null ? "" : android.os.Build.PRODUCT;
      boolean emu = fp.contains("generic") || fp.contains("emulator") || prod.contains("sdk")
          || "google_sdk".equals(prod) || android.os.Build.MODEL.contains("Emulator");
      return emu ? "emulator" : "device";
    } catch (Throwable t) {
      return "unknown";
    }
  }

  /** TEL-1 sink. The on-disk ring IS the default sink: records PERSIST locally (no network) so the
   *  crashfree-report can read the last launch's session-start + crash events. Records are forwarded
   *  off-device ONLY when the user has opted in (SharedPreferences {@code canopy.telemetry.optIn},
   *  default false) AND a {@code telemetryEndpoint} is configured — otherwise this makes ZERO network
   *  calls. Call once at boot. Returns the number of events currently in the ring. */
  public static int drainPending(Context ctx) {
    if (ctx == null) return 0;
    int n = 0;
    try {
      File dir = new File(ctx.getApplicationContext().getFilesDir(), DIR);
      File[] files = dir.listFiles();
      if (files != null) {
        for (File f : files) {
          if (f.getName().endsWith(".json")) n++;
        }
      }
      boolean optIn = telemetryOptIn(ctx.getApplicationContext());
      if (optIn) {
        // (TEL-1 HTTP sink: POST the ring as newline-delimited JSON to telemetryEndpoint here, then
        // clear forwarded events. Opt-in + endpoint required; stubbed until an endpoint is wired.)
        Log.i(TAG, "telemetry opt-in ON — " + n + " event(s) ready to forward");
      } else {
        Log.i(TAG, "telemetry opt-in OFF (no network) — " + n + " event(s) retained in the local ring");
      }
    } catch (Throwable t) {
      Log.w(TAG, "drainPending error (tolerated): " + t);
    }
    return n;
  }

  /** Telemetry consent — default FALSE (no network without explicit opt-in). */
  private static boolean telemetryOptIn(Context app) {
    try {
      return app.getSharedPreferences("canopy", Context.MODE_PRIVATE)
          .getBoolean("canopy.telemetry.optIn", false);
    } catch (Throwable t) {
      return false;
    }
  }

  // ---- helpers (all defensive) ----

  /** Keep at most MAX_RECORDS crash files (delete the oldest). Runs at install (off the crash path)
   *  so the cap holds even if a relaunch can never reach drainPending (e.g. a boot crash loop). */
  private static void pruneOldRecords(Context app) {
    try {
      File dir = new File(app.getFilesDir(), DIR);
      File[] fs = dir.listFiles();
      if (fs == null || fs.length <= MAX_RECORDS) return;
      java.util.Arrays.sort(fs, (a, b) -> Long.compare(a.lastModified(), b.lastModified()));
      for (int i = 0; i < fs.length - MAX_RECORDS; i++) fs[i].delete();
    } catch (Throwable ignored) { }
  }

  /** The stack as a JSON array of frame strings (schema-2 `frames`, unified with the iOS array). */
  private static String framesJson(Throwable t) {
    StringBuilder sb = new StringBuilder("[");
    if (t != null) {
      int lines = 0;
      for (StackTraceElement e : t.getStackTrace()) {
        if (lines > 0) sb.append(',');
        sb.append('"').append(esc(e.toString())).append('"');
        if (++lines >= 30) break;   // cap — a record is a breadcrumb, not a full dump
      }
    }
    return sb.append(']').toString();
  }

  /** JSON-escape a string (quotes, backslash, control chars) so the record stays valid JSON. */
  private static String esc(String s) {
    if (s == null) return "";
    StringBuilder sb = new StringBuilder(s.length() + 16);
    for (int i = 0; i < s.length(); i++) {
      char c = s.charAt(i);
      switch (c) {
        case '"':  sb.append("\\\""); break;
        case '\\': sb.append("\\\\"); break;
        case '\n': sb.append("\\n"); break;
        case '\r': sb.append("\\r"); break;
        case '\t': sb.append("\\t"); break;
        default:
          if (c < 0x20) sb.append(String.format("\\u%04x", (int) c));
          else sb.append(c);
      }
    }
    return sb.toString();
  }

  private static String safeShort(String s) {
    return s.length() > 12 ? s.substring(0, 12) : s;
  }
}
