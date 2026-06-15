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

  /** Evaluate the compiled bundle, create a root, and boot the program. */
  public static native void boot(String bundleJs, String flagsJson);

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
  // we post runJsCallback(id) onto the main Looper, where it is safe to touch the runtime.

  private static final Handler JS_HANDLER = new Handler(Looper.getMainLooper());

  /** Called FROM native (postToJs): schedule a parked callback onto the JS/main thread. */
  static void scheduleOnJs(long id) {
    JS_HANDLER.post(() -> runJsCallback(id));
  }

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

  /** Best-effort reload (full re-eval + re-boot). Stub until the dev-loop lands; dismisses now. */
  public static void reload() {
    JS_HANDLER.post(CanopyRedBox::dismiss);
  }

  private CanopyHostJni() {}
}
