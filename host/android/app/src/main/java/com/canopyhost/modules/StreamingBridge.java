// StreamingBridge.java — the Java side of the generic streaming-Sub emit path (canopy/navigation).
//
// Pure-Java capabilities that need a SUBSCRIPTION (a Sub that emits many events on one callId)
// cannot use the shared CanopyHostJni.resolveModule path — jniResolve erases the pending row on
// the first resolve. Instead the C++ side is a canopy::StreamingJniModule that owns the live
// stream sinks, and Java pushes events into them through this one bridge:
//
//   StreamingBridge.emit("Lifecycle", "appState", "{\"state\":\"background\"}");
//
// which routes (over the native nativeEmit export in StreamingJniModule.cpp) to the named
// module's emit(channel, json) → every live subscriber's ctx.complete → postToJs →
// __canopy_resolve (a streamed event). This mirrors BillingModule's nativeEmit, but generalized
// so any streaming capability (LifecycleModule, AppShellModule) reuses ONE bridge.
//
// nativeEmit hops onto the JS thread internally (the C1 worker→JS-thread hop), so emit() is safe
// to call from any thread — the main Looper after onTrimMemory, an OnBackPressedCallback, a
// uiMode-change broadcast.

package com.canopyhost.modules;

public final class StreamingBridge {

  // Push one event onto a live Sub channel. moduleName is the Native.Module name ("Lifecycle",
  // "AppShell"); channel is the streaming method ("appState", "memoryPressure", "backPressed",
  // "colorScheme"); eventJson is the wire payload the Canopy decoder reads. No-op if no module
  // by that name was registered or no subscriber is live on the channel.
  public static void emit(String moduleName, String channel, String eventJson) {
    nativeEmit(moduleName, channel, eventJson == null ? "" : eventJson);
  }

  /** Forwarded to canopy::streamingEmit by Java_com_canopyhost_modules_StreamingBridge_nativeEmit
   *  in StreamingJniModule.cpp (linked into libcanopyhost.so). */
  private static native void nativeEmit(String moduleName, String channel, String eventJson);

  private StreamingBridge() {}
}
