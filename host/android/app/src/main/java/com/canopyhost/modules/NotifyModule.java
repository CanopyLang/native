// NotifyModule.java — the Android host module behind canopy/notify (module "Notify").
//
// Reached via the shared JNI-module mechanism: C++ canopy::JniModule("Notify").invoke(ctx)
// parks ctx.complete keyed by callId and calls this class's static invoke(method, argsJson,
// callId). We do the real work — post a local notification through NotificationManager — on a
// worker thread, and call CanopyHostJni.resolveModule(callId, errJson, resultJson) when done.
// This mirrors ImageModule.java / StorageSecureModule.java exactly; only the work differs.
//
// Channel: Android 8 (API 26)+ requires a NotificationChannel before any post. We create it
// lazily on first show() (idempotent — createNotificationChannel replaces an existing one),
// so the caller never manages channels. On API < 26 the channel step is skipped.
//
// Permission: Android 13 (API 33)+ gates posting behind the runtime POST_NOTIFICATIONS
// permission. We do NOT prompt here (the app requests it at the right UX moment); instead we
// check NotificationManagerCompat.areNotificationsEnabled() and report posted:false when the
// OS would withhold it, so the Canopy caller gets a truthful Bool rather than a silent drop.
//
// Wire contract (must match notify.js / Notify.can):
//   show {title, body} -> {posted:<bool>}

package com.canopyhost.modules;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.content.Context;
import android.os.Build;

import androidx.core.app.NotificationCompat;
import androidx.core.app.NotificationManagerCompat;

import com.canopyhost.CanopyHostJni;
import com.canopyhost.MainActivity;

import org.json.JSONObject;

import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicInteger;

public final class NotifyModule {

  private static final String CHANNEL_ID = "canopy_default";
  private static final CharSequence CHANNEL_NAME = "Notifications";

  // Distinct ids so a second notification doesn't overwrite the first in the shade.
  private static final AtomicInteger NEXT_ID = new AtomicInteger(1);

  // One worker so channel creation / posting never lands on the JS/main thread.
  private static final ExecutorService EXEC = Executors.newSingleThreadExecutor();

  private static volatile boolean sChannelReady = false;

  /** Entry point the C++ JniModule calls. Dispatches off the JS thread. */
  public static void invoke(String method, String argsJson, String callId) {
    EXEC.execute(() -> {
      try {
        JSONObject args = new JSONObject(argsJson == null || argsJson.isEmpty() ? "{}" : argsJson);
        switch (method) {
          case "show": doShow(args, callId); break;
          default:     reject(callId, "module_not_found", "Notify." + method);
        }
      } catch (Throwable t) {
        reject(callId, "rejected", String.valueOf(t.getMessage()));
      }
    });
  }

  // ---- show -----------------------------------------------------------------

  private static void doShow(JSONObject args, String callId) throws Exception {
    String title = args.optString("title", "");
    String body = args.optString("body", "");
    Context ctx = context();

    ensureChannel(ctx);

    NotificationCompat.Builder builder = new NotificationCompat.Builder(ctx, CHANNEL_ID)
        // android.R.drawable.* is always present (no app drawable resource is shipped by the
        // host template); a real app overrides this with its own small icon.
        .setSmallIcon(android.R.drawable.ic_dialog_info)
        .setContentTitle(title)
        .setContentText(body)
        .setAutoCancel(true)
        .setPriority(NotificationCompat.PRIORITY_DEFAULT);

    NotificationManagerCompat nm = NotificationManagerCompat.from(ctx);

    // On API 33+ posting requires POST_NOTIFICATIONS. We don't prompt; report the truth.
    if (!nm.areNotificationsEnabled()) {
      resolvePosted(callId, false);
      return;
    }

    Notification n = builder.build();
    try {
      nm.notify(NEXT_ID.getAndIncrement(), n);
    } catch (SecurityException se) {
      // Permission revoked between the check and the post — still a clean "withheld", not error.
      resolvePosted(callId, false);
      return;
    }
    resolvePosted(callId, true);
  }

  // ---- channel (API 26+) ----------------------------------------------------

  private static void ensureChannel(Context ctx) {
    if (sChannelReady) { return; }
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      NotificationChannel channel = new NotificationChannel(
          CHANNEL_ID, CHANNEL_NAME, NotificationManager.IMPORTANCE_DEFAULT);
      NotificationManager mgr = ctx.getSystemService(NotificationManager.class);
      if (mgr != null) { mgr.createNotificationChannel(channel); }
    }
    sChannelReady = true;
  }

  // ---- helpers --------------------------------------------------------------

  private static Context context() {
    Context c = MainActivity.appContext();
    if (c == null) { throw new IllegalStateException("Notify: no app context"); }
    return c.getApplicationContext();
  }

  private static void resolvePosted(String callId, boolean posted) throws Exception {
    JSONObject out = new JSONObject();
    out.put("posted", posted);
    resolve(callId, out.toString());
  }

  private static void resolve(String callId, String resultJson) {
    CanopyHostJni.resolveModule(callId, "", resultJson);  // "" err => success
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

  private NotifyModule() {}
}
