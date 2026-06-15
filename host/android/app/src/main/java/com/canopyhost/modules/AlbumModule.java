// AlbumModule.java — the Android host module behind canopy/album (module "Album").
//
// Reached via the shared JNI-module mechanism: C++ canopy::JniModule("Album").invoke(ctx)
// parks ctx.complete keyed by callId and calls this class's static invoke(method, argsJson,
// callId). We do the real work — save a native image handle into the device photo gallery —
// on a worker thread, read the android.graphics.Bitmap out of the shared C++ BlobRegistry
// via CanopyBlobs, write it into MediaStore (Pictures/<album>, scoped storage), and call
// CanopyHostJni.resolveModule(callId, errJson, resultJson) when done.
//
// Threading: invoke() returns immediately; the heavy work (compress + MediaStore insert)
// runs on a single-thread executor so the JS/main thread is never blocked. resolveModule
// hops the completion back onto the JS thread (the C1 worker->JS-thread hop), so it is safe
// to call from here.
//
// Handle discipline: this is a CONSUMER. It GETs a Bitmap from the handle, compresses it
// into the MediaStore item's output stream, and recycles its Java copy. It does NOT release
// the handle (the caller owns the handle's lifetime and releases it via Image.release).
// Pixels NEVER cross as JSON — only the int handle does.
//
// Scoped storage (API 29+): we insert with RELATIVE_PATH = "Pictures/<album>" and
// IS_PENDING = 1, stream the bytes into the content uri, then clear IS_PENDING so the item
// becomes visible to the gallery. No WRITE_EXTERNAL_STORAGE permission is required. On API
// <29 we fall back to MediaStore.Images.Media.insertImage-style behavior via a direct
// content-values insert without RELATIVE_PATH/IS_PENDING (DATA-less); see saveLegacy.
//
// Wire contract (must match album.js / Album.can):
//   save   {image:<handle>, format:"jpeg"|"png"} -> {uri:"content://…"}

package com.canopyhost.modules;

import android.content.ContentResolver;
import android.content.ContentValues;
import android.content.Context;
import android.graphics.Bitmap;
import android.net.Uri;
import android.os.Build;
import android.provider.MediaStore;

import com.canopyhost.CanopyBlobs;
import com.canopyhost.CanopyHostJni;
import com.canopyhost.MainActivity;

import org.json.JSONObject;

import java.io.OutputStream;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class AlbumModule {

  // One worker so saves serialize (bounded memory) but never touch the JS/main thread.
  private static final ExecutorService EXEC = Executors.newSingleThreadExecutor();

  /** Entry point the C++ JniModule calls. Dispatches off the JS thread. */
  public static void invoke(String method, String argsJson, String callId) {
    EXEC.execute(() -> {
      try {
        JSONObject args = new JSONObject(argsJson == null || argsJson.isEmpty() ? "{}" : argsJson);
        switch (method) {
          case "save": doSave(args, callId); break;
          default:     reject(callId, "module_not_found", "Album." + method);
        }
      } catch (Throwable t) {
        reject(callId, "rejected", String.valueOf(t.getMessage()));
      }
    });
  }

  // ---- save (MediaStore, scoped storage) ------------------------------------

  private static void doSave(JSONObject args, String callId) throws Exception {
    int handle = args.getInt("image");
    String format = args.optString("format", "jpeg");
    boolean png = "png".equalsIgnoreCase(format);
    // App-chosen gallery sub-album (the package never hardcodes an app name).
    String album = args.optString("album", "Canopy").replaceAll("[^A-Za-z0-9 _-]", "");
    if (album.isEmpty()) album = "Canopy";
    String relativeDir = "Pictures/" + album;

    Bitmap bmp = CanopyBlobs.nativeBlobGetBitmap(handle);  // consumer GET (does NOT release)
    if (bmp == null) { reject(callId, "rejected", "unknown handle " + handle); return; }

    try {
      Context ctx = context();
      ContentResolver cr = ctx.getContentResolver();
      Bitmap.CompressFormat fmt = png ? Bitmap.CompressFormat.PNG : Bitmap.CompressFormat.JPEG;
      String mime = png ? "image/png" : "image/jpeg";
      String ext = png ? ".png" : ".jpg";
      String name = album + "-" + System.currentTimeMillis() + ext;

      Uri collection = MediaStore.Images.Media.EXTERNAL_CONTENT_URI;
      ContentValues values = new ContentValues();
      values.put(MediaStore.Images.Media.DISPLAY_NAME, name);
      values.put(MediaStore.Images.Media.MIME_TYPE, mime);

      boolean scoped = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q;
      if (scoped) {
        values.put(MediaStore.Images.Media.RELATIVE_PATH, relativeDir);
        values.put(MediaStore.Images.Media.IS_PENDING, 1);
      }

      Uri item = cr.insert(collection, values);
      if (item == null) { reject(callId, "rejected", "MediaStore insert returned null"); return; }

      try (OutputStream out = cr.openOutputStream(item)) {
        if (out == null) {
          cr.delete(item, null, null);
          reject(callId, "rejected", "could not open MediaStore output stream");
          return;
        }
        boolean ok = bmp.compress(fmt, png ? 100 : 95, out);
        if (!ok) {
          cr.delete(item, null, null);
          reject(callId, "rejected", "bitmap compress failed");
          return;
        }
      } catch (Exception e) {
        cr.delete(item, null, null);
        throw e;
      }

      if (scoped) {
        // Clear IS_PENDING so the gallery sees the finished item.
        ContentValues done = new ContentValues();
        done.put(MediaStore.Images.Media.IS_PENDING, 0);
        cr.update(item, done, null, null);
      }

      JSONObject res = new JSONObject();
      res.put("uri", item.toString());  // content://…
      resolve(callId, res.toString());
    } finally {
      bmp.recycle();  // recycle our Java copy; the native blob (the caller's handle) is untouched
    }
  }

  // ---- helpers --------------------------------------------------------------

  private static Context context() {
    Context c = MainActivity.appContext();
    if (c == null) { throw new IllegalStateException("Album: no app context"); }
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

  private AlbumModule() {}
}
