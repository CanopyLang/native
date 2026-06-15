// ImageModule.java — the Android host module behind canopy/image (module "Image").
//
// Reached via the shared JNI-module mechanism: C++ canopy::JniModule("Image").invoke(ctx)
// parks ctx.complete keyed by callId and calls this class's static invoke(method, argsJson,
// callId). We do the real work — decode (DOWNSAMPLED to a megapixel budget), resize,
// encodeToFile, composite, release — on a worker thread, move android.graphics.Bitmap
// pixels in/out of the shared C++ BlobRegistry via CanopyBlobs, and call
// CanopyHostJni.resolveModule(callId, errJson, resultJson) when done.
//
// Threading: invoke() returns immediately; the heavy work runs on a single-thread executor
// so the JS/main thread is never blocked by a decode. resolveModule hops the completion back
// onto the JS thread (the C1 worker->JS-thread hop), so it is safe to call from here.
//
// Handle discipline: a producing method (decode/resize/composite) PUTs a Bitmap into the
// registry and returns its int handle in {"image":h,"width":w,"height":h}. The Java Bitmap
// it built is recycled after the put (the pixels now live in the native Blob). A consuming
// method (encodeToFile) GETs the Bitmap back from the handle, uses it, and recycles its copy.
// release drops a registry reference. Pixels NEVER cross as JSON.
//
// Wire contract (must match image.js / Image.can):
//   decode       {uri}                          -> {image,width,height}
//   dimensions   {image}                         -> {width,height}
//   resize       {image,maxWidth,maxHeight}      -> {image,width,height}
//   encodeToFile {image,format:"jpeg"|"png",quality:0..1} -> {uri:"file://…"}
//   composite    {dst,src,x,y}                   -> {image,width,height}
//   release      {image}                         -> null

package com.canopyhost.modules;

import android.content.ContentResolver;
import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.net.Uri;

import com.canopyhost.CanopyBlobs;
import com.canopyhost.CanopyHostJni;
import com.canopyhost.MainActivity;

import org.json.JSONObject;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class ImageModule {

  // Downsample budget: a decoded source is never allowed past this many megapixels. A 12 MP
  // photo decodes to ~3 MP here (inSampleSize halving), so it never lands full-res in memory.
  private static final double MAX_MEGAPIXELS = 4.0;

  // One worker so decodes serialize (bounded memory) but never touch the JS/main thread.
  private static final ExecutorService EXEC = Executors.newSingleThreadExecutor();

  /** Entry point the C++ JniModule calls. Dispatches off the JS thread. */
  public static void invoke(String method, String argsJson, String callId) {
    EXEC.execute(() -> {
      try {
        JSONObject args = new JSONObject(argsJson == null || argsJson.isEmpty() ? "{}" : argsJson);
        switch (method) {
          case "decode":       doDecode(args, callId); break;
          case "dimensions":   doDimensions(args, callId); break;
          case "resize":       doResize(args, callId); break;
          case "encodeToFile": doEncodeToFile(args, callId); break;
          case "composite":    doComposite(args, callId); break;
          case "release":      doRelease(args, callId); break;
          default:             reject(callId, "module_not_found", "Image." + method);
        }
      } catch (Throwable t) {
        reject(callId, "rejected", String.valueOf(t.getMessage()));
      }
    });
  }

  // ---- decode (downsampled) -------------------------------------------------

  private static void doDecode(JSONObject args, String callId) throws Exception {
    String uri = args.getString("uri");
    Context ctx = context();
    ContentResolver cr = ctx.getContentResolver();
    Uri parsed = Uri.parse(uri);

    // Pass 1: bounds only (inJustDecodeBounds) — reads the header, NOT the pixels. This is
    // how a 12 MP source is measured without ever decoding it full-res.
    BitmapFactory.Options bounds = new BitmapFactory.Options();
    bounds.inJustDecodeBounds = true;
    try (InputStream in = open(cr, parsed)) {
      BitmapFactory.decodeStream(in, null, bounds);
    }
    if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
      reject(callId, "rejected", "could not read image bounds: " + uri);
      return;
    }

    // Pass 2: decode at the sample size that brings it under the megapixel budget.
    BitmapFactory.Options opts = new BitmapFactory.Options();
    opts.inSampleSize = sampleSizeFor(bounds.outWidth, bounds.outHeight, MAX_MEGAPIXELS);
    opts.inPreferredConfig = Bitmap.Config.ARGB_8888;
    Bitmap bmp;
    try (InputStream in = open(cr, parsed)) {
      bmp = BitmapFactory.decodeStream(in, null, opts);
    }
    if (bmp == null) {
      reject(callId, "rejected", "decode failed: " + uri);
      return;
    }
    resolveBitmap(callId, bmp);  // puts + recycles, returns {image,width,height}
  }

  // ---- dimensions -----------------------------------------------------------

  private static void doDimensions(JSONObject args, String callId) throws Exception {
    int handle = args.getInt("image");
    Bitmap bmp = CanopyBlobs.nativeBlobGetBitmap(handle);
    if (bmp == null) { reject(callId, "rejected", "unknown handle " + handle); return; }
    int w = bmp.getWidth(), h = bmp.getHeight();
    bmp.recycle();
    JSONObject out = new JSONObject();
    out.put("width", w);
    out.put("height", h);
    resolve(callId, out.toString());
  }

  // ---- resize (aspect-preserving, fit within maxWidth x maxHeight) ----------

  private static void doResize(JSONObject args, String callId) throws Exception {
    int handle = args.getInt("image");
    int maxW = args.getInt("maxWidth");
    int maxH = args.getInt("maxHeight");
    Bitmap src = CanopyBlobs.nativeBlobGetBitmap(handle);
    if (src == null) { reject(callId, "rejected", "unknown handle " + handle); return; }

    double scale = Math.min((double) maxW / src.getWidth(), (double) maxH / src.getHeight());
    if (scale >= 1.0) {
      // Already within bounds: produce a fresh handle that aliases the same pixels (a copy,
      // so the input handle's lifetime stays independent).
      Bitmap copy = src.copy(Bitmap.Config.ARGB_8888, false);
      src.recycle();
      resolveBitmap(callId, copy);
      return;
    }
    int w = Math.max(1, (int) Math.round(src.getWidth() * scale));
    int h = Math.max(1, (int) Math.round(src.getHeight() * scale));
    Bitmap scaled = Bitmap.createScaledBitmap(src, w, h, true);
    src.recycle();
    resolveBitmap(callId, scaled);
  }

  // ---- encodeToFile (JPEG/PNG to cacheDir, returns file:// uri) --------------

  private static void doEncodeToFile(JSONObject args, String callId) throws Exception {
    int handle = args.getInt("image");
    String format = args.optString("format", "jpeg");
    double quality = args.optDouble("quality", 0.9);
    Bitmap bmp = CanopyBlobs.nativeBlobGetBitmap(handle);
    if (bmp == null) { reject(callId, "rejected", "unknown handle " + handle); return; }

    boolean png = "png".equalsIgnoreCase(format);
    Bitmap.CompressFormat fmt = png ? Bitmap.CompressFormat.PNG : Bitmap.CompressFormat.JPEG;
    int q = (int) Math.round(Math.max(0.0, Math.min(1.0, quality)) * 100);

    File dir = context().getCacheDir();
    File out = new File(dir, "canopy-img-" + handle + "-" + System.nanoTime() + (png ? ".png" : ".jpg"));
    try (FileOutputStream fos = new FileOutputStream(out)) {
      bmp.compress(fmt, q, fos);
    }
    bmp.recycle();

    JSONObject res = new JSONObject();
    res.put("uri", Uri.fromFile(out).toString());  // file://…
    resolve(callId, res.toString());
  }

  // ---- composite (src over dst at x,y -> new handle) ------------------------

  private static void doComposite(JSONObject args, String callId) throws Exception {
    int dstH = args.getInt("dst");
    int srcH = args.getInt("src");
    int x = args.getInt("x");
    int y = args.getInt("y");
    Bitmap dst = CanopyBlobs.nativeBlobGetBitmap(dstH);
    Bitmap src = CanopyBlobs.nativeBlobGetBitmap(srcH);
    if (dst == null || src == null) {
      if (dst != null) { dst.recycle(); }
      if (src != null) { src.recycle(); }
      reject(callId, "rejected", "unknown handle in composite");
      return;
    }
    Bitmap out = dst.copy(Bitmap.Config.ARGB_8888, true);  // mutable target
    Canvas canvas = new Canvas(out);
    canvas.drawBitmap(src, x, y, null);
    dst.recycle();
    src.recycle();
    resolveBitmap(callId, out);
  }

  // ---- release --------------------------------------------------------------

  private static void doRelease(JSONObject args, String callId) throws Exception {
    int handle = args.getInt("image");
    CanopyBlobs.nativeBlobRelease(handle);
    resolve(callId, "null");
  }

  // ---- helpers --------------------------------------------------------------

  private static InputStream open(ContentResolver cr, Uri uri) throws Exception {
    String scheme = uri.getScheme();
    if ("asset".equals(scheme)) {
      // asset:NAME — read a bundled app asset (for demos/probes shipping a sample image).
      String name = uri.getSchemeSpecificPart();
      while (name.startsWith("/")) name = name.substring(1);
      return MainActivity.appContext().getAssets().open(name);
    }
    if ("file".equals(scheme) || scheme == null) {
      return new java.io.FileInputStream(uri.getPath());
    }
    return cr.openInputStream(uri);
  }

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
    if (c == null) { throw new IllegalStateException("Image: no app context"); }
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

  private ImageModule() {}
}
