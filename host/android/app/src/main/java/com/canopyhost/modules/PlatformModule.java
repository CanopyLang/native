// PlatformModule.java — common platform APIs behind Native.Platform (module "Platform").
//
// Linking (openURL) + Clipboard (set/get) via the shared C1 native-module mechanism. These touch
// the Activity / system services, so unlike the worker-thread capabilities (Http/StorageSecure)
// they run on the MAIN thread (a main-looper Handler), then resolve back through the same
// resolveModule hop.
//
// Wire contract (must match Native/Platform.can):
//   openURL      {url}    -> null
//   setClipboard {text}   -> null
//   getClipboard {}       -> {text:<string>}

package com.canopyhost.modules;

import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;

import com.canopyhost.CanopyHostJni;
import com.canopyhost.MainActivity;

import org.json.JSONObject;

public final class PlatformModule {

  private static final Handler MAIN = new Handler(Looper.getMainLooper());

  public static void invoke(String method, String argsJson, String callId) {
    MAIN.post(() -> {
      try {
        JSONObject a = new JSONObject(argsJson == null || argsJson.isEmpty() ? "{}" : argsJson);
        Context ctx = MainActivity.appContext();
        switch (method) {
          case "openURL": {
            Intent i = new Intent(Intent.ACTION_VIEW, Uri.parse(a.getString("url")));
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            ctx.startActivity(i);
            resolve(callId, "null");
            break;
          }
          case "setClipboard": {
            ClipboardManager cm = (ClipboardManager) ctx.getSystemService(Context.CLIPBOARD_SERVICE);
            cm.setPrimaryClip(ClipData.newPlainText("canopy", a.getString("text")));
            resolve(callId, "null");
            break;
          }
          case "getClipboard": {
            ClipboardManager cm = (ClipboardManager) ctx.getSystemService(Context.CLIPBOARD_SERVICE);
            CharSequence text = "";
            if (cm.hasPrimaryClip() && cm.getPrimaryClip() != null && cm.getPrimaryClip().getItemCount() > 0) {
              text = cm.getPrimaryClip().getItemAt(0).coerceToText(ctx);
            }
            JSONObject out = new JSONObject();
            out.put("text", text == null ? "" : text.toString());
            resolve(callId, out.toString());
            break;
          }
          default:
            reject(callId, "module_not_found", "Platform." + method);
        }
      } catch (Throwable t) {
        reject(callId, "rejected", t.getClass().getSimpleName() + (t.getMessage() != null ? ": " + t.getMessage() : ""));
      }
    });
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

  private PlatformModule() {}
}
