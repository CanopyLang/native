// AppShellModule.java — the Android host module behind canopy/navigation's Native.AppShell
// (module "AppShell"). Two surfaces:
//   • setStatusBarStyle — one-shot Cmd: set the status-bar icon contrast (light vs. dark icons)
//     on the Activity window. Delegated here over the standard JNI-module path; resolved via
//     CanopyHostJni.resolveModule.
//   • colorScheme       — streaming Sub: the system light/dark setting. Backed by the C++
//     canopy::StreamingJniModule (like Lifecycle), pushed via StreamingBridge.emit. The first
//     subscriber lazily registers a uiMode observer; we also prime the current scheme.
//
// colorScheme is observed via a ComponentCallbacks.onConfigurationChanged hook on the app
// Context (uiMode night bit). That fires when the OS theme flips while the app is alive; the
// initial value is primed on subscribe by reading the current Configuration. (For the
// follow-the-system behavior to deliver config changes without an Activity recreate, the
// integrator adds android:configChanges="uiMode" to the <activity> in the manifest — see the
// integration manifest; without it the Activity is recreated on theme flip and a fresh
// subscribe re-primes the new value anyway.)
//
// THREADING: window writes must run on the main thread (runOnUiThread); the config callback
// fires on the main thread; StreamingBridge.emit / resolveModule hop to the JS thread
// internally. Safe.
//
// Wire contract (must match appshell.js / Native.AppShell.can):
//   setStatusBarStyle (one-shot) {"style":"light"|"dark"} -> null
//   colorScheme       (stream)                            -> {"scheme":"light"|"dark"}

package com.canopyhost.modules;

import android.content.ComponentCallbacks;
import android.content.Context;
import android.content.res.Configuration;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import android.view.Window;
import android.view.WindowInsetsController;

import com.canopyhost.CanopyHostJni;
import com.canopyhost.MainActivity;

import org.json.JSONObject;

public final class AppShellModule {

  public static final String MODULE = "AppShell";

  private static final Handler MAIN = new Handler(Looper.getMainLooper());
  private static boolean colorSchemeObserved = false;

  /** Entry point the C++ StreamingJniModule calls. colorScheme arrives with a sentinel
   *  callId="" (first-subscriber notify); setStatusBarStyle arrives with a real callId. */
  public static void invoke(String method, String argsJson, String callId) {
    try {
      switch (method) {
        case "colorScheme":       ensureColorSchemeObserver(); break;        // notify only
        case "setStatusBarStyle": doSetStatusBarStyle(argsJson, callId); break;
        default:
          if (callId != null && !callId.isEmpty()) {
            reject(callId, "module_not_found", "AppShell." + method);
          }
      }
    } catch (Throwable t) {
      if (callId != null && !callId.isEmpty()) {
        reject(callId, "rejected", String.valueOf(t.getMessage()));
      }
    }
  }

  // ---- setStatusBarStyle (one-shot Cmd) -------------------------------------

  // "light" => light status-bar CONTENT (white icons, for a dark bar); "dark" => dark content
  // (black icons, for a light bar). Uses WindowInsetsController on API 30+, falling back to the
  // legacy SYSTEM_UI_FLAG_LIGHT_STATUS_BAR decor flag below it.
  private static void doSetStatusBarStyle(String argsJson, String callId) throws Exception {
    JSONObject args = new JSONObject(argsJson == null || argsJson.isEmpty() ? "{}" : argsJson);
    final String style = args.optString("style", "dark");
    final boolean lightContent = "light".equals(style);  // light icons => bar content is light

    MainActivity activity = MainActivity.current();
    if (activity == null) {
      reject(callId, "rejected", "AppShell: no foreground activity");
      return;
    }
    activity.runOnUiThread(() -> {
      try {
        Window window = activity.getWindow();
        View decor = window.getDecorView();
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
          WindowInsetsController c = window.getInsetsController();
          if (c != null) {
            // APPEARANCE_LIGHT_STATUS_BARS set => DARK icons (for a light bar). So when the
            // caller asks for "light" content (white icons) we CLEAR that appearance bit.
            int mask = WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS;
            c.setSystemBarsAppearance(lightContent ? 0 : mask, mask);
          }
        } else {
          int flags = decor.getSystemUiVisibility();
          if (lightContent) {
            flags &= ~View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR;   // light icons
          } else {
            flags |= View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR;    // dark icons
          }
          decor.setSystemUiVisibility(flags);
        }
        resolve(callId, "null");
      } catch (Throwable t) {
        reject(callId, "rejected", "AppShell.setStatusBarStyle: " + t.getMessage());
      }
    });
  }

  // ---- colorScheme (streaming Sub) ------------------------------------------

  private static void ensureColorSchemeObserver() {
    runOnMain(() -> {
      Context app = MainActivity.appContext();
      if (app == null) { return; }
      if (!colorSchemeObserved) {
        colorSchemeObserved = true;
        app.registerComponentCallbacks(new ComponentCallbacks() {
          @Override public void onConfigurationChanged(Configuration newConfig) {
            emitScheme(schemeOf(newConfig));
          }
          @Override public void onLowMemory() {}
        });
      }
      // Prime the current scheme so a fresh subscriber gets it immediately.
      emitScheme(schemeOf(app.getResources().getConfiguration()));
    });
  }

  private static String schemeOf(Configuration config) {
    int night = config.uiMode & Configuration.UI_MODE_NIGHT_MASK;
    return night == Configuration.UI_MODE_NIGHT_YES ? "dark" : "light";
  }

  private static void emitScheme(String scheme) {
    StreamingBridge.emit(MODULE, "colorScheme", "{\"scheme\":\"" + scheme + "\"}");
  }

  // ---- helpers --------------------------------------------------------------

  private static void runOnMain(Runnable r) {
    if (Looper.myLooper() == Looper.getMainLooper()) { r.run(); }
    else { MAIN.post(r); }
  }

  private static void resolve(String callId, String resultJson) {
    if (callId == null || callId.isEmpty()) { return; }
    CanopyHostJni.resolveModule(callId, "", resultJson);
  }

  private static void reject(String callId, String code, String message) {
    if (callId == null || callId.isEmpty()) { return; }
    String safe = message == null ? "" : message.replace("\"", "'");
    CanopyHostJni.resolveModule(callId,
        "{\"code\":\"" + code + "\",\"message\":\"" + safe + "\"}", "");
  }

  private AppShellModule() {}
}
