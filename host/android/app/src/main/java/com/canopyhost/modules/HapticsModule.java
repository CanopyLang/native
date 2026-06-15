// HapticsModule.java — the Android host module behind Native.Haptics (module "Haptics").
//
// A JniModule("Haptics") capability: __canopy_call("Haptics", method, …)
// routes to invoke() here. Registered at boot (see the printed registration line).
//
// Wire contract (must match Native/Haptics.can):
//   impact       {style}  -> null   (style "light"|"medium"|"heavy")
//   notification {style}  -> null   (type  "success"|"warning"|"error")
//   selection    {}       -> null
//
// Uses the system Vibrator (Context.VIBRATOR_SERVICE). On SDK>=26 it emits a VibrationEffect
// (createOneShot for the single-buzz styles, createWaveform for the notification patterns);
// on older devices it falls back to the deprecated vibrate(ms) / vibrate(pattern,-1).
// Permission android.permission.VIBRATE is already declared in the manifest.
package com.canopyhost.modules;

import com.canopyhost.CanopyHostJni;

import org.json.JSONObject;

public final class HapticsModule {

  public static void invoke(String method, String argsJson, String callId) {
    try {
      JSONObject args = new JSONObject(argsJson == null || argsJson.isEmpty() ? "{}" : argsJson);
      android.os.Vibrator vib = vibrator();
      switch (method) {
        case "impact": {
          String style = args.optString("style", "medium");
          long ms = "light".equals(style) ? 20L : "heavy".equals(style) ? 60L : 40L;
          oneShot(vib, ms);
          resolve(callId, "null");
          break;
        }
        case "notification": {
          String style = args.optString("style", "success");
          long[] pattern;
          if ("warning".equals(style)) {
            pattern = new long[] { 0L, 40L, 80L, 40L };
          } else if ("error".equals(style)) {
            pattern = new long[] { 0L, 60L, 40L, 60L, 40L, 60L };
          } else {
            pattern = new long[] { 0L, 30L, 60L, 30L };
          }
          waveform(vib, pattern);
          resolve(callId, "null");
          break;
        }
        case "selection": {
          oneShot(vib, 10L);
          resolve(callId, "null");
          break;
        }
        default:
          reject(callId, "module_not_found", "Haptics." + method);
      }
    } catch (Throwable t) {
      reject(callId, "rejected", t.getClass().getSimpleName()
          + (t.getMessage() != null ? ": " + t.getMessage() : ""));
    }
  }

  private static void oneShot(android.os.Vibrator vib, long ms) {
    if (vib == null) { return; }
    if (android.os.Build.VERSION.SDK_INT >= 26) {
      vib.vibrate(android.os.VibrationEffect.createOneShot(
          ms, android.os.VibrationEffect.DEFAULT_AMPLITUDE));
    } else {
      vib.vibrate(ms);
    }
  }

  private static void waveform(android.os.Vibrator vib, long[] pattern) {
    if (vib == null) { return; }
    if (android.os.Build.VERSION.SDK_INT >= 26) {
      vib.vibrate(android.os.VibrationEffect.createWaveform(pattern, -1));
    } else {
      vib.vibrate(pattern, -1);
    }
  }

  private static android.os.Vibrator vibrator() {
    android.content.Context c = com.canopyhost.MainActivity.appContext();
    return c == null ? null
        : (android.os.Vibrator) c.getSystemService(android.content.Context.VIBRATOR_SERVICE);
  }

  private static void resolve(String callId, String resultJson) {
    CanopyHostJni.resolveModule(callId, "", resultJson);
  }

  private static void reject(String callId, String code, String message) {
    try {
      JSONObject err = new JSONObject();
      err.put("code", code);
      err.put("message", message == null ? "" : message);
      CanopyHostJni.resolveModule(callId, err.toString(), "");
    } catch (Exception e) {
      CanopyHostJni.resolveModule(callId, "{\"code\":\"rejected\"}", "");
    }
  }

  private HapticsModule() {}
}
