// ShareImageModule.java — the Android host module behind canopy/share-image (module
// "ShareImage").
//
// Reached via the shared JNI-module mechanism: C++ canopy::JniModule("ShareImage").invoke(ctx)
// parks ctx.complete keyed by callId and calls this class's static invoke(method, argsJson,
// callId). We do the real work — share a native image handle to other apps — by baking the
// blob's pixels to a cache file, wrapping it in a FileProvider content:// uri, and launching
// an Intent.ACTION_SEND chooser. We read the android.graphics.Bitmap out of the shared C++
// BlobRegistry via CanopyBlobs and call CanopyHostJni.resolveModule(callId, errJson,
// resultJson) when done.
//
// Threading: invoke() returns immediately. The bake (compress to cache file) runs on a
// single-thread executor off the JS/main thread. The actual chooser launch must happen on
// the UI thread with an Activity context, so we post it onto the main Looper. We resolve the
// call once the chooser has been presented (errJson "" => success); on API 22+ a
// ChooserReceiver upgrades the result with the chosen component (still "presented").
//
// Handle discipline: this is a CONSUMER. It GETs a Bitmap from the handle, compresses it to
// a cache file, recycles its Java copy, and does NOT release the handle (the caller owns the
// handle's lifetime). Pixels NEVER cross as JSON — only the int handle does.
//
// FileProvider: shared files go through a <provider> declared in the manifest with authority
// "<applicationId>.fileprovider" and the paths in res/xml/file_paths.xml (the cache-path the
// bake writes to). FileProvider.getUriForFile grants the receiving app a temporary read via
// FLAG_GRANT_READ_URI_PERMISSION — never a raw file:// (which would throw FileUriExposed).
//
// Wire contract (must match share-image.js / ShareImage.can):
//   image   {image:<handle>} -> {outcome:"presented"|"dismissed"}

package com.canopyhost.modules;

import android.app.Activity;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.graphics.Bitmap;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;

import androidx.core.content.FileProvider;

import com.canopyhost.CanopyBlobs;
import com.canopyhost.CanopyHostJni;
import com.canopyhost.MainActivity;

import org.json.JSONObject;

import java.io.File;
import java.io.FileOutputStream;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicInteger;

public final class ShareImageModule {

  private static final String FILEPROVIDER_SUFFIX = ".fileprovider";
  private static final String CHOOSER_ACTION = "com.canopyhost.modules.SHARE_IMAGE_CHOSEN";

  // One worker so bakes serialize (bounded memory) but never touch the JS/main thread.
  private static final ExecutorService EXEC = Executors.newSingleThreadExecutor();
  private static final Handler MAIN = new Handler(Looper.getMainLooper());
  private static final AtomicInteger REQ = new AtomicInteger(1);

  /** Entry point the C++ JniModule calls. Dispatches off the JS thread. */
  public static void invoke(String method, String argsJson, String callId) {
    EXEC.execute(() -> {
      try {
        JSONObject args = new JSONObject(argsJson == null || argsJson.isEmpty() ? "{}" : argsJson);
        switch (method) {
          case "image": doImage(args, callId); break;
          default:      reject(callId, "module_not_found", "ShareImage." + method);
        }
      } catch (Throwable t) {
        reject(callId, "rejected", String.valueOf(t.getMessage()));
      }
    });
  }

  // ---- image (bake -> FileProvider uri -> ACTION_SEND chooser) --------------

  private static void doImage(JSONObject args, String callId) throws Exception {
    int handle = args.getInt("image");
    Bitmap bmp = CanopyBlobs.nativeBlobGetBitmap(handle);  // consumer GET (does NOT release)
    if (bmp == null) { reject(callId, "rejected", "unknown handle " + handle); return; }

    final Uri contentUri;
    try {
      Context ctx = context();
      File shareDir = new File(ctx.getCacheDir(), "share");
      if (!shareDir.exists() && !shareDir.mkdirs() && !shareDir.exists()) {
        reject(callId, "rejected", "could not create cache/share dir");
        return;
      }
      File out = new File(shareDir, "share-" + handle + "-" + System.nanoTime() + ".jpg");
      try (FileOutputStream fos = new FileOutputStream(out)) {
        if (!bmp.compress(Bitmap.CompressFormat.JPEG, 95, fos)) {
          reject(callId, "rejected", "bitmap compress failed");
          return;
        }
      }
      String authority = ctx.getPackageName() + FILEPROVIDER_SUFFIX;
      contentUri = FileProvider.getUriForFile(ctx, authority, out);
    } finally {
      bmp.recycle();  // recycle our Java copy; the native blob (the caller's handle) is untouched
    }

    // The chooser must launch on the UI thread with an Activity context.
    MAIN.post(() -> launchChooser(contentUri, callId));
  }

  private static void launchChooser(Uri contentUri, String callId) {
    try {
      Activity activity = MainActivity.current();
      Context launchCtx = (activity != null) ? activity : context();

      Intent send = new Intent(Intent.ACTION_SEND);
      send.setType("image/jpeg");
      send.putExtra(Intent.EXTRA_STREAM, contentUri);
      send.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
      // ClipData carries the grant to the chooser's OWN preview process (intentresolver),
      // not just the eventual receiver — without it the chooser thumbnail hits a
      // SecurityException opening the FileProvider.
      send.setClipData(android.content.ClipData.newRawUri("", contentUri));

      Intent chooser;
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP_MR1) {
        // API 22+: a ChooserReceiver tells us the chosen component (upgrades the result).
        Context appCtx = context();
        Intent receiver = new Intent(CHOOSER_ACTION).setPackage(appCtx.getPackageName());
        int flags = PendingIntent.FLAG_UPDATE_CURRENT
            | (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S ? PendingIntent.FLAG_MUTABLE : 0);
        PendingIntent pi = PendingIntent.getBroadcast(appCtx, REQ.getAndIncrement(), receiver, flags);
        appCtx.registerReceiver(new ChooserReceiver(), new IntentFilter(CHOOSER_ACTION),
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU
                ? Context.RECEIVER_NOT_EXPORTED : 0);
        chooser = Intent.createChooser(send, "Share image", pi.getIntentSender());
      } else {
        chooser = Intent.createChooser(send, "Share image");
      }

      chooser.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
      if (activity == null) {
        chooser.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
      }
      launchCtx.startActivity(chooser);

      // We can only reliably report that the chooser was presented. The optional
      // ChooserReceiver fires later (after the user picks) but we do not block on it — a
      // single resolve per callId, exactly like the JNI contract.
      JSONObject res = new JSONObject();
      res.put("outcome", "presented");
      resolve(callId, res.toString());
    } catch (Throwable t) {
      reject(callId, "rejected", "share chooser failed: " + t.getMessage());
    }
  }

  // Best-effort: logs which app the user picked. We do NOT re-resolve here (the call was
  // already resolved when the chooser was presented — one resolve per callId).
  static final class ChooserReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context ctx, Intent intent) {
      ComponentName chosen = (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP_MR1)
          ? intent.getParcelableExtra(Intent.EXTRA_CHOSEN_COMPONENT) : null;
      android.util.Log.i("ShareImageModule", "share chosen: " + chosen);
      try { ctx.unregisterReceiver(this); } catch (Exception ignored) {}
    }
  }

  // ---- helpers --------------------------------------------------------------

  private static Context context() {
    Context c = MainActivity.appContext();
    if (c == null) { throw new IllegalStateException("ShareImage: no app context"); }
    return c;
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

  private ShareImageModule() {}
}
