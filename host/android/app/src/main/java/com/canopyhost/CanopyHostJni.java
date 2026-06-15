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

  /** Register the Java mount the C++ installer forwards __fabric_* calls to. */
  public static native void install(CanopyHost host);

  /** Evaluate the compiled bundle, create a root, and boot the program.
   *
   *  RNV-7: the bundle is delivered as RAW BYTES so a real Hermes .hbc (bytecode) can be booted
   *  directly — Hermes detects the HBC magic and runs bytecode with no on-device parse, falling
   *  back to parsing the bytes as JS source when they are not bytecode. The native side first
   *  gates the .hbc's stamped bytecode-format version against the vendored engine pin
   *  (CanopyAbiGate.h: checkBundleBytecode), the load-time half of the RNV-2 ABI contract. */
  public static native void boot(byte[] bundle, String flagsJson);

  /** Deliver a native event into JS (called from CanopyHost listeners). */
  public static native void emitEvent(int handle, String eventName, String payloadJson);

  /** Run a parked native postToJs callback (invoked on the JS/main thread). */
  static native void runJsCallback(long id);

  /** No-op trigger so a referencing class forces libcanopyhost.so to load (CanopyBlobs). */
  public static void ensureLoaded() {}

  /** Deliver a JniModule capability completion back into JS (called by the Java module bridges). */
  public static native void resolveModule(String callId, String errJson, String resultJson);

  /** Hand the ORT model bytes to the inference engine (called by MainActivity after boot). */
  public static native void setRestoreEngineModel(byte[] modelBytes);

  // ---- the C1 worker→JS-thread hop (plan C1 §3.5) -------------------------------------
  // For the direct-views host the JS thread is the main/UI thread (every __fabric_* mount
  // touches android.view). postToJs (native) parks a completion and calls scheduleOnJs(id);
  // we drain runJsCallback(id) on the main Looper, where it is safe to touch the runtime.
  //
  // AND-9: a burst of completions arriving within one frame is COALESCED into a single main-Looper
  // post that drains them all in FIFO order, instead of one Runnable per completion thrashing the UI
  // thread (plans/dependent/AND-9.md). The whole policy lives in CanopyCompletionScheduler (pure,
  // device-free unit-tested); here we only inject the real main Looper as the poster and the native
  // runJsCallback as the runner.

  private static final Handler JS_HANDLER = new Handler(Looper.getMainLooper());

  private static final CanopyCompletionScheduler COMPLETIONS =
      new CanopyCompletionScheduler(JS_HANDLER::post, CanopyHostJni::runJsCallback);

  /** Called FROM native (postToJs): coalesce a parked callback onto the JS/main thread. A burst
   *  within one frame batches into ONE main-Looper post (bounded backlog, no dropped completion). */
  static void scheduleOnJs(long id) {
    COMPLETIONS.schedule(id);
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

  /** Best-effort reload (full re-eval + re-boot). Stub until the dev-loop lands; dismisses now. */
  public static void reload() {
    JS_HANDLER.post(CanopyRedBox::dismiss);
  }

  private CanopyHostJni() {}
}
