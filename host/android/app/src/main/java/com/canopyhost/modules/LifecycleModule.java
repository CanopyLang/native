// LifecycleModule.java — the Android host module behind canopy/navigation's Native.Lifecycle
// (module "Lifecycle"). App-state, memory pressure, and hardware/gesture back are all live
// SUBSCRIPTIONS, so the C++ side is a canopy::StreamingJniModule (not the erase-on-resolve
// JniModule path), and we push events through StreamingBridge.emit(...). One method —
// allowDefaultBack — is a one-shot Cmd delegated here over the standard JNI-module path and
// resolved via CanopyHostJni.resolveModule.
//
// WHAT EACH CHANNEL OBSERVES:
//   • appState       — ProcessLifecycleOwner: ON_START -> foreground, ON_STOP -> background.
//                      Emits {"state":"foreground"|"background"} on every transition, and the
//                      C++ side primes a fresh subscriber with the last value.
//   • memoryPressure — a ComponentCallbacks2.onTrimMemory hook (registered on the app Context):
//                      emits {"level":"moderate"|"low"|"critical"} on the matching trim levels.
//                      The level is bucketed from the Android TRIM_MEMORY_* constants so the
//                      Canopy side sees a small, stable taxonomy.
//   • backPressed    — MainActivity owns an OnBackPressedCallback (ComponentActivity's
//                      OnBackPressedDispatcher). While enabled it INTERCEPTS the hardware/gesture
//                      back, emits {} on this channel, and consumes the event (the app decides
//                      what to do — pop a NavStack, close a sheet). To let the system handle it
//                      (finish the activity), the app calls allowDefaultBack.
//
// SUBSCRIBE LAZINESS: the C++ StreamingJniModule calls invoke(channel, args, "") (sentinel
// callId="") the first time a channel gets a subscriber, so we register the corresponding OS
// observer only when something is listening. Subscribing twice is a no-op (the observers are
// idempotent / guarded). We never unsubscribe the OS observers (they are cheap and process-
// lived); the C++ side simply stops having sinks to emit to when the last Sub goes away.
//
// THREADING: ProcessLifecycleOwner + onTrimMemory + the back callback all fire on the MAIN
// thread; StreamingBridge.emit / CanopyHostJni.resolveModule hop onto the JS thread internally,
// so calling them from the main thread is safe. We register observers on the main thread.
//
// Wire contract (must match lifecycle.js / Native.Lifecycle.can):
//   appState         (stream) -> {"state":"foreground"|"background"}
//   memoryPressure   (stream) -> {"level":"moderate"|"low"|"critical"}
//   backPressed      (stream) -> {}
//   allowDefaultBack (one-shot){} -> null   (re-dispatches the current back press to the system)

package com.canopyhost.modules;

import android.content.ComponentCallbacks2;
import android.content.Context;
import android.content.res.Configuration;
import android.os.Handler;
import android.os.Looper;

import androidx.lifecycle.DefaultLifecycleObserver;
import androidx.lifecycle.LifecycleOwner;
import androidx.lifecycle.ProcessLifecycleOwner;

import com.canopyhost.CanopyHostJni;
import com.canopyhost.MainActivity;

public final class LifecycleModule {

  public static final String MODULE = "Lifecycle";

  private static final Handler MAIN = new Handler(Looper.getMainLooper());

  // Guard double-registration of the process-lived OS observers (a channel may be subscribed,
  // dropped, and re-subscribed many times; the observer is registered once).
  private static boolean appStateObserved = false;
  private static boolean memoryObserved = false;
  private static boolean backObserved = false;

  /** Entry point the C++ StreamingJniModule calls. For a streaming channel it arrives with a
   *  sentinel callId="" (first-subscriber notify): we register the OS observer and DO NOT
   *  resolve. For the one-shot allowDefaultBack a real callId arrives and we resolve it. */
  public static void invoke(String method, String argsJson, String callId) {
    try {
      switch (method) {
        case "appState":        ensureAppStateObserver(); break;        // notify only, no resolve
        case "memoryPressure":  ensureMemoryObserver();   break;        // notify only, no resolve
        case "backPressed":     ensureBackObserver();     break;        // notify only, no resolve
        case "allowDefaultBack": doAllowDefaultBack(callId); break;     // one-shot Cmd
        default:
          if (callId != null && !callId.isEmpty()) {
            reject(callId, "module_not_found", "Lifecycle." + method);
          }
      }
    } catch (Throwable t) {
      if (callId != null && !callId.isEmpty()) {
        reject(callId, "rejected", String.valueOf(t.getMessage()));
      }
    }
  }

  // ---- appState (ProcessLifecycleOwner) -------------------------------------

  private static void ensureAppStateObserver() {
    runOnMain(() -> {
      if (appStateObserved) { return; }
      appStateObserved = true;
      ProcessLifecycleOwner.get().getLifecycle().addObserver(new DefaultLifecycleObserver() {
        @Override public void onStart(LifecycleOwner owner) { emitAppState("foreground"); }
        @Override public void onStop(LifecycleOwner owner)  { emitAppState("background"); }
      });
      // Prime: emit the current state immediately so a just-subscribed app gets it at once
      // (the app is, by definition, in the foreground when it first subscribes).
      emitAppState("foreground");
    });
  }

  private static void emitAppState(String state) {
    StreamingBridge.emit(MODULE, "appState", "{\"state\":\"" + state + "\"}");
  }

  // ---- memoryPressure (ComponentCallbacks2.onTrimMemory) --------------------

  private static void ensureMemoryObserver() {
    runOnMain(() -> {
      if (memoryObserved) { return; }
      Context app = MainActivity.appContext();
      if (app == null) { return; }
      memoryObserved = true;
      app.registerComponentCallbacks(new ComponentCallbacks2() {
        @Override public void onTrimMemory(int level) {
          String bucket = bucketTrim(level);
          if (bucket != null) {
            StreamingBridge.emit(MODULE, "memoryPressure", "{\"level\":\"" + bucket + "\"}");
          }
        }
        @Override public void onConfigurationChanged(Configuration newConfig) {}
        @Override public void onLowMemory() {
          StreamingBridge.emit(MODULE, "memoryPressure", "{\"level\":\"critical\"}");
        }
      });
    });
  }

  // Bucket the Android TRIM_MEMORY_* ladder into a small stable taxonomy. RUNNING_* levels
  // (foreground app under pressure) and the UI-hidden / background levels both map to a 3-step
  // moderate/low/critical scale; the trivially-low COMPLETE/MODERATE background levels are
  // surfaced too because they are the strongest "free memory now" signals.
  private static String bucketTrim(int level) {
    switch (level) {
      case ComponentCallbacks2.TRIM_MEMORY_RUNNING_MODERATE:
      case ComponentCallbacks2.TRIM_MEMORY_UI_HIDDEN:
      case ComponentCallbacks2.TRIM_MEMORY_BACKGROUND:
        return "moderate";
      case ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW:
      case ComponentCallbacks2.TRIM_MEMORY_MODERATE:
        return "low";
      case ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL:
      case ComponentCallbacks2.TRIM_MEMORY_COMPLETE:
        return "critical";
      default:
        return null;  // unknown / nothing-to-do levels are dropped
    }
  }

  // ---- backPressed (OnBackPressedDispatcher, owned by MainActivity) ---------

  private static void ensureBackObserver() {
    runOnMain(() -> {
      if (backObserved) { return; }
      MainActivity activity = MainActivity.current();
      if (activity == null) { return; }
      backObserved = true;
      activity.enableBackInterception();  // installs / enables the OnBackPressedCallback
    });
  }

  /** Called by MainActivity's OnBackPressedCallback (on the main thread) when an intercepted
   *  back press fires. Emits an empty event on the backPressed channel; the app reacts. */
  public static void onBackPressed() {
    StreamingBridge.emit(MODULE, "backPressed", "{}");
  }

  // ---- allowDefaultBack (one-shot Cmd) --------------------------------------

  // Let the system handle the CURRENT (or next) back press: temporarily yield interception so
  // the dispatcher falls through to the default handler (finish the activity / leave the app),
  // then restore interception. MainActivity does the dispatcher dance on the main thread.
  private static void doAllowDefaultBack(String callId) {
    runOnMain(() -> {
      MainActivity activity = MainActivity.current();
      if (activity != null) { activity.allowDefaultBack(); }
      resolve(callId, "null");
    });
  }

  // ---- helpers --------------------------------------------------------------

  private static void runOnMain(Runnable r) {
    if (Looper.myLooper() == Looper.getMainLooper()) { r.run(); }
    else { MAIN.post(r); }
  }

  private static void resolve(String callId, String resultJson) {
    if (callId == null || callId.isEmpty()) { return; }
    CanopyHostJni.resolveModule(callId, "", resultJson);  // "" err => success
  }

  private static void reject(String callId, String code, String message) {
    if (callId == null || callId.isEmpty()) { return; }
    String safe = message == null ? "" : message.replace("\"", "'");
    CanopyHostJni.resolveModule(callId,
        "{\"code\":\"" + code + "\",\"message\":\"" + safe + "\"}", "");
  }

  private LifecycleModule() {}
}
