// PhotosModule.java — the Android host module behind canopy/photos (module "Photos").
//
// Reached via the shared JNI-module mechanism: C++ canopy::JniModule("Photos").invoke(ctx)
// parks ctx.complete keyed by callId and calls this class's static invoke(method, argsJson,
// callId). The big difference from ImageModule: "pick" can't run purely on a worker thread —
// it has to open the Android Photo Picker, which is an ActivityResult flow owned by the
// Activity. ComponentActivity requires the launcher be REGISTERED before STARTED, so the
// launcher lives in MainActivity (registered in onCreate) and we drive it through a static
// accessor MainActivity.launchPhotoPicker(callId). When the user finishes, MainActivity calls
// us back on the MAIN thread via onPickResult(callId, uri) — null uri means the user
// dismissed the picker. We then decode the content:// uri (DOWNSAMPLED to a megapixel budget)
// on a worker thread, move the Bitmap into the shared C++ BlobRegistry via CanopyBlobs, and
// call CanopyHostJni.resolveModule(callId, errJson, resultJson).
//
// Threading: invoke() and onPickResult() are quick + UI-thread-safe (they only kick off the
// picker / hand decode to a worker). The heavy decode runs on a single-thread executor so the
// JS/main thread is never blocked. resolveModule hops the completion back onto the JS thread
// (the C1 worker->JS-thread hop), so it is safe to call from the worker.
//
// Handle discipline (identical to ImageModule): "pick" PUTs the decoded Bitmap into the
// registry and returns {"image":h,"width":w,"height":h}; the Java Bitmap is recycled after the
// put (pixels now live in the native Blob). "release" drops a registry reference. Pixels NEVER
// cross as JSON — only the int handle.
//
// Wire contract (must match photos.js / Photos.can):
//   pick     {}             -> {image,width,height}   |  err {code:"cancelled"} on dismiss
//   release  {image}        -> null

package com.canopyhost.modules;

import android.content.ContentResolver;
import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.net.Uri;

import com.canopyhost.CanopyBlobs;
import com.canopyhost.CanopyHostJni;
import com.canopyhost.MainActivity;

import org.json.JSONObject;

import java.io.InputStream;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class PhotosModule {

  // Downsample budget: a picked source is never decoded past this many megapixels. Matches
  // canopy/image's ImageModule so a picked photo and a decoded one land at the same fidelity.
  private static final double MAX_MEGAPIXELS = 4.0;

  // One worker so decodes serialize (bounded memory) but never touch the JS/main thread.
  private static final ExecutorService EXEC = Executors.newSingleThreadExecutor();

  /** Entry point the C++ JniModule calls. */
  public static void invoke(String method, String argsJson, String callId) {
    try {
      switch (method) {
        case "pick":    doPick(callId); break;
        case "release": doRelease(argsJson, callId); break;
        default:        reject(callId, "module_not_found", "Photos." + method);
      }
    } catch (Throwable t) {
      reject(callId, "rejected", String.valueOf(t.getMessage()));
    }
  }

  /** Optional cancel hook the C++ JniModule calls on __canopy_cancel. We can't recall a picker
   *  that is already on screen, but we drop the parked callId so a late result no-ops. */
  public static void cancel(String callId) {
    MainActivity.cancelPhotoPick(callId);
  }

  // ---- pick -----------------------------------------------------------------

  // Launch the picker on the MAIN thread (ActivityResult APIs require it). MainActivity owns
  // the launcher (registered in onCreate, before STARTED) and remembers callId so its result
  // callback can route back here via onPickResult. If no Activity is available, reject.
  private static void doPick(String callId) {
    MainActivity activity = MainActivity.current();
    if (activity == null) {
      reject(callId, "rejected", "Photos: no foreground activity to host the picker");
      return;
    }
    activity.runOnUiThread(() -> {
      try {
        MainActivity.launchPhotoPicker(callId);
      } catch (Throwable t) {
        reject(callId, "rejected", "Photos: could not launch picker: " + t.getMessage());
      }
    });
  }

  // Called by MainActivity (on the MAIN thread) when the ActivityResult lands. A null uri means
  // the user dismissed the picker without choosing — resolve as a "cancelled" rejection so the
  // Canopy side maps it to Native.Module.Rejected and the app can treat it as a no-op. A real
  // uri is decoded (downsampled) on the worker thread, then resolved with the blob handle.
  public static void onPickResult(String callId, Uri uri) {
    if (uri == null) {
      reject(callId, "cancelled", "picker dismissed");
      return;
    }
    EXEC.execute(() -> {
      try {
        decodeUriToHandle(callId, uri);
      } catch (Throwable t) {
        reject(callId, "rejected", "Photos decode failed: " + String.valueOf(t.getMessage()));
      }
    });
  }

  // ---- decode (downsampled, identical strategy to ImageModule.doDecode) -----

  private static void decodeUriToHandle(String callId, Uri uri) throws Exception {
    Context ctx = context();
    ContentResolver cr = ctx.getContentResolver();

    // Pass 1: bounds only (inJustDecodeBounds) — reads the header, NOT the pixels, so a 12 MP
    // photo is measured without ever decoding it full-res.
    BitmapFactory.Options bounds = new BitmapFactory.Options();
    bounds.inJustDecodeBounds = true;
    try (InputStream in = cr.openInputStream(uri)) {
      BitmapFactory.decodeStream(in, null, bounds);
    }
    if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
      reject(callId, "rejected", "could not read picked image bounds: " + uri);
      return;
    }

    // Pass 2: decode at the sample size that brings it under the megapixel budget.
    BitmapFactory.Options opts = new BitmapFactory.Options();
    opts.inSampleSize = sampleSizeFor(bounds.outWidth, bounds.outHeight, MAX_MEGAPIXELS);
    opts.inPreferredConfig = Bitmap.Config.ARGB_8888;
    Bitmap bmp;
    try (InputStream in = cr.openInputStream(uri)) {
      bmp = BitmapFactory.decodeStream(in, null, opts);
    }
    if (bmp == null) {
      reject(callId, "rejected", "decode failed: " + uri);
      return;
    }
    resolveBitmap(callId, bmp);  // puts + recycles, returns {image,width,height}
  }

  // ---- release --------------------------------------------------------------

  private static void doRelease(String argsJson, String callId) throws Exception {
    JSONObject args = new JSONObject(argsJson == null || argsJson.isEmpty() ? "{}" : argsJson);
    int handle = args.getInt("image");
    CanopyBlobs.nativeBlobRelease(handle);
    resolve(callId, "null");
  }

  // ---- helpers (mirrors ImageModule) ----------------------------------------

  // Largest power-of-two sample size that keeps width*height under the megapixel budget.
  private static int sampleSizeFor(int w, int h, double maxMegapixels) {
    long budget = (long) (maxMegapixels * 1_000_000.0);
    int sample = 1;
    long pixels = (long) w * h;
    while (pixels / ((long) sample * sample) > budget) {
      sample *= 2;
    }
    return sample;
  }

  // Put a Bitmap into the shared registry, recycle the Java copy, resolve {image,width,height}.
  private static void resolveBitmap(String callId, Bitmap bmp) throws Exception {
    int w = bmp.getWidth(), h = bmp.getHeight();
    int handle = CanopyBlobs.put(bmp);   // coerces to ARGB_8888 + puts (refcount 1)
    bmp.recycle();                       // pixels now live in the native Blob
    if (handle == 0) { reject(callId, "rejected", "blob put failed"); return; }
    JSONObject out = new JSONObject();
    out.put("image", handle);
    out.put("width", w);
    out.put("height", h);
    resolve(callId, out.toString());
  }

  private static Context context() {
    Context c = MainActivity.appContext();
    if (c == null) { throw new IllegalStateException("Photos: no app context"); }
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

  private PhotosModule() {}
}
