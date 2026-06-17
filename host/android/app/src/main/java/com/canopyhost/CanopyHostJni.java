// CanopyHostJni.java — JNI bridge between the C++ JSI installer (CanopyFabric.cpp) and
// the Java mount (CanopyHost.java).
//
// The native side installs __fabric_* on the Hermes runtime; each call hops to the
// registered CanopyHost via these natives. Events flow the other way: CanopyHost calls
// emitEvent(), which routes to canopy::canopyEmitEvent on the JS thread.
//
// Integration template (needs the Android NDK + RN's Hermes). See ../README.md.

package com.canopyhost;

import android.os.Handler;
import android.os.HandlerThread;
import android.os.Looper;

public final class CanopyHostJni {

  static {
    // Load the vendored, version-matched native chain bottom-up so the dynamic linker
    // resolves libcanopyhost.so's DT_NEEDED (libhermes → libjsi + libfbjni). libc++_shared
    // is loaded automatically as an NDK system lib.
    System.loadLibrary("fbjni");
    System.loadLibrary("jsi");
    System.loadLibrary("hermes");
    System.loadLibrary("canopyhost");
  }

  // ==== RND-8 — JS off the UI thread (flag-gated) =======================================
  // By default the JS/Hermes runtime lives on the UI thread (every __fabric_* mount touches
  // android.view, which must run there). RND-8 lets the runtime move to a DEDICATED "CanopyJS"
  // thread; a frame's view writes are marshalled back to the UI thread as ONE flat binary batch
  // (RND-7) per frame, so the JS work decorrelates from view-write latency (the verification
  // criterion: frame drops stop tracking stream rate). This is a LARGE posture change, so it is
  // OPT-IN behind a flag and OFF by default — when off, everything below is byte-for-byte the old
  // single-thread host.
  //
  // The flag is read ONCE (debug-gated): `adb shell setprop debug.canopy.jsthread 1` (or the
  // CANOPY_JS_THREAD env the perf harness exports), mirroring the RND-4 perf-instrumentation gate.
  // In a release build BuildConfig.DEBUG is a compile-time false, so JS_OFF_UI_THREAD folds to false
  // and the whole dedicated-thread branch is dead-stripped — the off-UI-thread path never ships until
  // it has been proven on a device. The native side reads the SAME decision via jsOffUiThread() at
  // install() so C++ and Java agree on one mode for the process's life.
  static final boolean JS_OFF_UI_THREAD = BuildConfig.DEBUG && jsThreadRequested();

  /** Whether the dedicated-JS-thread posture is active for this process. Read from native at
   *  install() so the BatchSink wiring matches; stays constant for the process's life. */
  static boolean jsOffUiThread() { return JS_OFF_UI_THREAD; }

  /** Opt-in runtime flag for RND-8, read once at class init (only ever true in a DEBUG build).
   *  `setprop debug.canopy.jsthread 1` OR CANOPY_JS_THREAD=1. Defaults OFF. Mirrors CanopyFrameMetrics
   *  .perfRequested()'s read path so the same operational muscle memory applies. */
  private static boolean jsThreadRequested() {
    try {
      String p = System.getProperty("debug.canopy.jsthread", "");
      if (p == null || p.isEmpty()) p = readSystemProp("debug.canopy.jsthread");
      if (p == null || p.isEmpty()) p = System.getenv("CANOPY_JS_THREAD");
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

  /** The dedicated JS-runtime thread (off-UI-thread mode only). Started lazily on first use; its
   *  Looper is where g_runtime is created + owned and where the walker runs. Null in single-thread
   *  mode (the runtime lives on the UI thread, so RUNTIME_HANDLER == the main Handler below). */
  private static final HandlerThread JS_THREAD = startJsThreadIfEnabled();

  private static HandlerThread startJsThreadIfEnabled() {
    if (!JS_OFF_UI_THREAD) return null;
    HandlerThread t = new HandlerThread("CanopyJS");
    t.start();
    return t;
  }

  /** The Handler that owns the JS runtime — the dedicated CanopyJS Looper off the UI thread, or the
   *  main Looper in single-thread mode. EVERY entry point that touches g_runtime (boot, emitEvent,
   *  the model handoff, reload, a postToJs completion) marshals onto THIS so the runtime is only ever
   *  touched on its owning thread. The UI thread is reached separately via JS_HANDLER (the main
   *  Looper) for the marshalled view writes (applyBatchOnUi). */
  private static final Handler RUNTIME_HANDLER =
      new Handler(JS_THREAD != null ? JS_THREAD.getLooper() : Looper.getMainLooper());

  /** True when the caller is already on the runtime's thread — then a direct call is correct (and a
   *  re-post would needlessly defer it a loop). */
  private static boolean onRuntimeThread() {
    return Looper.myLooper() == RUNTIME_HANDLER.getLooper();
  }

  /** Run {@code r} on the runtime's thread: inline if already there, else posted. Used by the public
   *  boot/emit/model/reload wrappers so a caller from any thread (MainActivity's onCreate on the UI
   *  thread, a gesture listener) is safe in BOTH modes. */
  static void runOnRuntimeThread(Runnable r) {
    if (onRuntimeThread()) r.run();
    else RUNTIME_HANDLER.post(r);
  }

  /** Register the Java mount the C++ installer forwards __fabric_* calls to. */
  public static native void install(CanopyHost host);

  /** REL-2 SIG: install the native hard-crash floor (off by default; CanopyCrashFloor calls this only
   *  under the CANOPY_SIGNAL_FLOOR opt-in). Loading this class links libcanopyhost (static block). */
  static native void installSignalFloor(String dir, String buildId, String sessionId, String source);

  /** Evaluate the compiled bundle, create a root, and boot the program. RND-8: in off-UI-thread mode
   *  the runtime lives on the CanopyJS thread, so the boot is marshalled there (and g_runtime is
   *  created on that thread, never touched off it). In single-thread mode runtimeHandler is the main
   *  Looper, so an onCreate caller runs it inline — unchanged. */
  public static void boot(byte[] bundle, String flagsJson) {
    runOnRuntimeThread(() -> nativeBoot(bundle, flagsJson));
  }

  /** Evaluate the compiled bundle, create a root, and boot the program (native).
   *
   *  RNV-7: the bundle is delivered as RAW BYTES so a real Hermes .hbc (bytecode) can be booted
   *  directly — Hermes detects the HBC magic and runs bytecode with no on-device parse, falling
   *  back to parsing the bytes as JS source when they are not bytecode. The native side first
   *  gates the .hbc's stamped bytecode-format version against the vendored engine pin
   *  (CanopyAbiGate.h: checkBundleBytecode), the load-time half of the RNV-2 ABI contract. */
  private static native void nativeBoot(byte[] bundle, String flagsJson);

  /** Deliver a native event into JS (called from CanopyHost listeners). RND-8: an event fires on the
   *  UI thread (a gesture/text listener), but it re-enters update/view on the runtime, so it is
   *  marshalled onto the runtime's thread. Single-thread mode runs it inline (already on the UI/JS
   *  thread), so the historical synchronous behaviour is preserved. */
  public static void emitEvent(int handle, String eventName, String payloadJson) {
    runOnRuntimeThread(() -> nativeEmitEvent(handle, eventName, payloadJson));
  }

  private static native void nativeEmitEvent(int handle, String eventName, String payloadJson);

  /** Run a parked native postToJs callback (invoked on the JS-runtime thread). */
  static native void runJsCallback(long id);

  /** RND-8 — replay a frame's marshalled binary batch on the UI thread (off-UI-thread mode only).
   *  Native postToJs's BatchSink parked the bytes + called applyBatchOnUi(id); we post onto the main
   *  Looper and let native runUiBatch(id) replay them where android.view writes are legal. */
  static native void runUiBatch(long id);

  /** No-op trigger so a referencing class forces libcanopyhost.so to load (CanopyBlobs). */
  public static void ensureLoaded() {}

  /** Deliver a JniModule capability completion back into JS (called by the Java module bridges). The
   *  native side parks the completion + hops it via postToJs onto the runtime's Looper, so this is
   *  thread-agnostic — a worker thread calls it and the re-entry lands on the runtime's thread. */
  public static native void resolveModule(String callId, String errJson, String resultJson);

  /** Hand the ORT model bytes to the inference engine (called by MainActivity after boot). RND-8:
   *  off-UI-thread boot() is posted to the CanopyJS thread; marshalling this onto the SAME runtime
   *  Handler preserves the after-boot ordering (g_restoreEngine exists before the bytes arrive). */
  public static void setRestoreEngineModel(byte[] modelBytes) {
    runOnRuntimeThread(() -> nativeSetRestoreEngineModel(modelBytes));
  }

  private static native void nativeSetRestoreEngineModel(byte[] modelBytes);

  // ---- the C1 worker→JS-thread hop (plan C1 §3.5) -------------------------------------
  // postToJs (native) parks a completion and calls scheduleOnJs(id); we drain runJsCallback(id) on
  // the RUNTIME thread, where it is safe to touch g_runtime. In single-thread mode that thread is the
  // main/UI thread (every __fabric_* mount touches android.view); in RND-8 off-UI-thread mode it is
  // the dedicated CanopyJS thread — so the completion poster targets RUNTIME_HANDLER, NOT the main
  // Looper, in both modes (RUNTIME_HANDLER == main Looper when single-threaded).
  //
  // AND-9: a burst of completions arriving within one frame is COALESCED into a single Looper post
  // that drains them all in FIFO order, instead of one Runnable per completion thrashing the thread
  // (plans/dependent/AND-9.md). The whole policy lives in CanopyCompletionScheduler (pure, device-free
  // unit-tested); here we only inject the runtime Looper as the poster and native runJsCallback as the
  // runner.

  /** The MAIN/UI Looper handler. Distinct from RUNTIME_HANDLER in off-UI-thread mode: it carries the
   *  UI-thread work — the marshalled view writes (applyBatchOnUi → runUiBatch), the red-box overlay,
   *  the reload toast — which MUST run on the UI thread, never on the CanopyJS thread. In single-thread
   *  mode it and RUNTIME_HANDLER are both the main Looper. */
  private static final Handler JS_HANDLER = new Handler(Looper.getMainLooper());

  private static final CanopyCompletionScheduler COMPLETIONS =
      new CanopyCompletionScheduler(RUNTIME_HANDLER::post, CanopyHostJni::runJsCallback);

  /** Called FROM native (postToJs): coalesce a parked callback onto the RUNTIME thread (the CanopyJS
   *  Looper in off-UI-thread mode, the main Looper otherwise). A burst within one frame batches into
   *  ONE post (bounded backlog, no dropped completion). */
  static void scheduleOnJs(long id) {
    COMPLETIONS.schedule(id);
  }

  /** Called FROM native (RND-8 BatchSink, off-UI-thread mode only): a frame's marshalled binary batch
   *  is parked under {@code id}; post onto the MAIN/UI Looper so native runUiBatch(id) replays it
   *  where android.view writes are legal. One post per frame (RND-7 collapses the frame to ONE batch),
   *  so the UI thread sees exactly one cross-thread message per frame — the cheapest possible coupling,
   *  which is what lets frame drops decorrelate from a high-frequency stream feeding the JS thread. */
  static void applyBatchOnUi(long id) {
    JS_HANDLER.post(() -> runUiBatch(id));
  }

  /** AND-9 opt-in latest-wins backpressure: a streaming module whose intermediate frames are
   *  disposable (sensor samples, scroll offsets, progress %) routes here instead of scheduleOnJs.
   *  A newer event for the same streamKey supersedes an older still-undrained one; the newest
   *  enqueued id always survives, so the stream's terminal value is never dropped. Called FROM
   *  native (a StreamingJniModule that opted in) on a worker thread — the scheduler synchronizes. */
  static void scheduleLatestOnJs(String streamKey, long id) {
    COMPLETIONS.scheduleLatest(streamKey, id);
  }

  /** AND-9 introspection for a perf dump / the instrumented streaming test: posts saved vs events
   *  enqueued (the coalescing ratio), and how many were dropped by latest-wins backpressure. */
  static long completionPostCount()       { return COMPLETIONS.postCount(); }
  static long completionEnqueuedCount()    { return COMPLETIONS.enqueuedCount(); }
  static long completionSupersededCount()  { return COMPLETIONS.supersededCount(); }

  // ---- error handling: red-box instead of SIGABRT -------------------------------------
  // The C++ guards catch a jsi::JSError at every host↔JS re-entry site and call this instead
  // of letting the exception escape into Hermes' frame (which std::terminate()s the process).
  // We mount a plain-Android overlay so it survives even a walker/reconciler crash.

  /** Called FROM native when a JS/native error crosses a host re-entry site. */
  static void onJsError(String msg, String stack, boolean fatal) {
    JS_HANDLER.post(() -> {
      MainActivity a = MainActivity.current();
      if (a != null) CanopyRedBox.show(a, msg, stack, /*dev=*/true, fatal);
    });
  }

  /** DEV-8: called FROM native after a state-preserving reload that had to DISCARD the captured
   *  model because the new bundle's Model type changed shape (the structural Model type-hash
   *  differs). native.js posts the notice on globalThis.__canopy_reloadNotice; the reload path
   *  drains it and calls here so the developer sees WHY their app state reset (a brief toast)
   *  instead of silently losing state. {@code kind} is "modelChanged" today; {@code message} is the
   *  human-readable text. Best-effort: no activity → no toast (the state reset already happened in
   *  JS regardless). Posted to the main Looper because Toast must run on the UI thread. */
  static void onReloadNotice(String kind, String message) {
    JS_HANDLER.post(() -> {
      MainActivity a = MainActivity.current();
      if (a != null && message != null) {
        android.widget.Toast.makeText(a, message, android.widget.Toast.LENGTH_LONG).show();
      }
    });
  }

  /** Red-box "Reload" button handler. DEV-11: in a DEBUG build with a dev loop attached, recover to
   *  the last-known-good bundle (re-eval the last build that worked + restore the captured model) so a
   *  failed reload is recoverable in place rather than a force-restart. We reach the debug-only
   *  CanopyDevClient reflectively (it is absent from a release APK, so this stays a plain dismiss
   *  there) — mirroring how CanopyDevClient itself reflects into CanopyHost.nativeReload. When no dev
   *  client / no good bundle is available, fall back to dismissing the overlay. */
  public static void reload() {
    JS_HANDLER.post(() -> {
      if (!tryDebugRecover()) {
        CanopyRedBox.dismiss();
      }
    });
  }

  /** Reflectively invoke CanopyDevClient.tryRecoverLastGood() (debug-only class). Returns false when
   *  the class is absent (release), no dev client is attached, or there is no good bundle to recover
   *  to — the caller then dismisses. Any reflection failure degrades to false (never throws). */
  private static boolean tryDebugRecover() {
    try {
      Class<?> cls = Class.forName("com.canopyhost.CanopyDevClient");
      java.lang.reflect.Method m = cls.getDeclaredMethod("tryRecoverLastGood");
      m.setAccessible(true);
      Object r = m.invoke(null);
      return r instanceof Boolean && (Boolean) r;
    } catch (Throwable t) {
      return false; // release build (no CanopyDevClient) or any reflection issue → plain dismiss
    }
  }

  private CanopyHostJni() {}
}
