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
  private static final String DIR = "crashes";
  private static final int MAX_RECORDS = 50;   // cap on-disk growth; oldest are pruned on install.

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

    Thread.setDefaultUncaughtExceptionHandler((thread, throwable) -> {
      try {
        writeRecord(app, bid, versionCode, thread, throwable);
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

  /** Serialize one crash record to filesDir/crashes/&lt;buildId&gt;-&lt;ts&gt;.json. Keyed by buildId +
   *  platform so REL-4 can decrement the right per-build crash-free numerator. */
  private static void writeRecord(Context app, String buildId, long versionCode,
                                  Thread thread, Throwable t) throws Exception {
    File dir = new File(app.getFilesDir(), DIR);
    if (!dir.exists() && !dir.mkdirs()) return;
    long ts = System.currentTimeMillis();
    File out = new File(dir, buildId + "-" + ts + ".json");
    String json = "{"
        + "\"schema\":1"
        + ",\"kind\":\"jvm-uncaught\""
        + ",\"platform\":\"android\""
        + ",\"buildId\":\"" + esc(buildId) + "\""
        + ",\"versionCode\":" + versionCode
        + ",\"timestampMs\":" + ts
        + ",\"thread\":\"" + esc(thread == null ? "?" : thread.getName()) + "\""
        + ",\"throwable\":\"" + esc(t == null ? "?" : t.getClass().getName()) + "\""
        + ",\"message\":\"" + esc(t == null ? "" : String.valueOf(t.getMessage())) + "\""
        + ",\"stack\":\"" + esc(stackOf(t)) + "\""
        + ",\"fatal\":true"
        + "}";
    try (FileOutputStream fos = new FileOutputStream(out)) {
      fos.write(json.getBytes(StandardCharsets.UTF_8));
    }
  }

  /** Read + log any crash records left by a PRIOR launch, then delete them (consumed). Call once at
   *  boot. Returns the number drained. A future TEL-1 sink forwards each record before deletion. */
  public static int drainPending(Context ctx) {
    if (ctx == null) return 0;
    int n = 0;
    try {
      File dir = new File(ctx.getApplicationContext().getFilesDir(), DIR);
      File[] files = dir.listFiles();
      if (files == null) return 0;
      for (File f : files) {
        if (!f.getName().endsWith(".json")) continue;
        Log.w(TAG, "prior-run crash record: " + f.getName());
        // (TEL-1 will forward `f` to the crash sink here before deleting.)
        if (f.delete()) n++;
      }
      if (n > 0) Log.w(TAG, "drained " + n + " prior-run crash record(s)");
    } catch (Throwable t) {
      Log.w(TAG, "drainPending error (tolerated): " + t);
    }
    return n;
  }

  // ---- helpers (all defensive) ----

  private static String stackOf(Throwable t) {
    if (t == null) return "";
    StringBuilder sb = new StringBuilder();
    int lines = 0;
    for (StackTraceElement e : t.getStackTrace()) {
      sb.append(e.toString()).append('\n');
      if (++lines >= 30) break;   // cap — a record is a breadcrumb, not a full dump
    }
    return sb.toString();
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
