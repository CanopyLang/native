// CanopyImageLoader.java — the declarative Image `source` loader for RCTImageView.
//
// RN's <Image source={{uri}}> loads a URL/file/asset/content image by STRING, with memory +
// disk caching, downsampling to the target view, and onLoad/onError callbacks. The host's
// existing bitmapHandle path (CanopyBlobs) is for native-produced pixels and stays untouched;
// this is the complementary by-string path. It is dependency-free on purpose — the host has so
// far vendored only .so's, and a build-time Maven fetch (Glide/Coil) could fail offline — so
// this implements the small slice of an image pipeline we actually need with plain
// HttpURLConnection + BitmapFactory + an LruCache + a disk cache.
//
// Supported source schemes:
//   http(s)://host/path   → network download (disk-cached by source hash, then memory-cached)
//   file:///abs/path  or  /abs/path   → local file
//   asset:NAME  or  asset://NAME      → app assets (src/main/assets)
//   content://…           → ContentResolver (gallery/picker URIs)
//
// Threading: load() is called on the JS == main/UI thread (CanopyHost.applyProps). Decode runs
// on a small background pool; the result is posted back to the main looper, so the supplied
// Callback always runs on the UI thread where it is safe to touch the view + emit the event.

package com.canopyhost.views;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.util.LruCache;

import java.io.BufferedInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ThreadFactory;

public final class CanopyImageLoader {

  /** Result delivered on the UI thread: exactly one of bitmap / error is non-null. */
  public interface Callback {
    void onResult(Bitmap bitmap, String error);
  }

  // Memory cache: ~1/8 of the app heap, keyed by source string. Sized in KB.
  private static final LruCache<String, Bitmap> MEM =
      new LruCache<String, Bitmap>((int) (Runtime.getRuntime().maxMemory() / 1024 / 8)) {
        @Override protected int sizeOf(String key, Bitmap b) { return b.getByteCount() / 1024; }
      };

  private static final Handler MAIN = new Handler(Looper.getMainLooper());

  private static final ExecutorService POOL = Executors.newFixedThreadPool(3, new ThreadFactory() {
    @Override public Thread newThread(Runnable r) {
      Thread t = new Thread(r, "canopy-image");
      t.setDaemon(true);
      t.setPriority(Thread.NORM_PRIORITY - 1);
      return t;
    }
  });

  /**
   * Load {@code source} into a bitmap, downsampled toward {@code targetW x targetH} (pass 0 for
   * an unbounded axis — a 2048px cap applies). The callback runs on the UI thread.
   */
  public static void load(Context ctx, String source, int targetW, int targetH, Callback cb) {
    if (source == null || source.isEmpty()) { cb.onResult(null, "empty source"); return; }
    Bitmap cached = MEM.get(source);
    if (cached != null) { cb.onResult(cached, null); return; }
    final Context app = ctx.getApplicationContext();
    POOL.execute(() -> {
      Bitmap bmp = null; String err = null;
      try {
        byte[] data = read(app, source);
        bmp = decode(data, targetW, targetH);
        if (bmp == null) err = "decode failed";
      } catch (Exception e) {
        err = e.getClass().getSimpleName() + (e.getMessage() != null ? ": " + e.getMessage() : "");
      }
      final Bitmap result = bmp; final String error = err;
      MAIN.post(() -> {
        if (result != null) MEM.put(source, result);
        cb.onResult(result, error);
      });
    });
  }

  // ---- source → bytes -------------------------------------------------------

  private static byte[] read(Context ctx, String source) throws Exception {
    String low = source.toLowerCase();
    if (low.startsWith("http://") || low.startsWith("https://")) return readHttp(ctx, source);
    InputStream in;
    if (low.startsWith("asset:")) {
      String name = source.substring(low.startsWith("asset://") ? 8 : 6);
      in = ctx.getAssets().open(name);
    } else if (low.startsWith("content://")) {
      in = ctx.getContentResolver().openInputStream(Uri.parse(source));
    } else if (low.startsWith("file://")) {
      in = new FileInputStream(source.substring(7));
    } else if (source.startsWith("/")) {
      in = new FileInputStream(source);
    } else {
      // Bare name: treat as an asset (RN's require()-style local image).
      in = ctx.getAssets().open(source);
    }
    try { return readAll(in); } finally { in.close(); }
  }

  private static byte[] readHttp(Context ctx, String source) throws Exception {
    File cacheFile = diskFile(ctx, source);
    if (cacheFile.exists() && cacheFile.length() > 0) {
      try (FileInputStream fis = new FileInputStream(cacheFile)) { return readAll(fis); }
    }
    HttpURLConnection conn = (HttpURLConnection) new URL(source).openConnection();
    conn.setConnectTimeout(15000);
    conn.setReadTimeout(20000);
    conn.setInstanceFollowRedirects(true);
    conn.setRequestProperty("User-Agent", "CanopyNative/0.1");
    try {
      int code = conn.getResponseCode();
      if (code < 200 || code >= 300) throw new Exception("HTTP " + code);
      byte[] bytes;
      try (InputStream in = new BufferedInputStream(conn.getInputStream())) { bytes = readAll(in); }
      writeDisk(cacheFile, bytes);                              // best-effort persist
      return bytes;
    } finally {
      conn.disconnect();
    }
  }

  // ---- bytes → bitmap (two-pass downsample) ---------------------------------

  private static Bitmap decode(byte[] data, int targetW, int targetH) {
    BitmapFactory.Options bounds = new BitmapFactory.Options();
    bounds.inJustDecodeBounds = true;
    BitmapFactory.decodeByteArray(data, 0, data.length, bounds);
    if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null;
    int wantW = targetW > 0 ? targetW : 2048;
    int wantH = targetH > 0 ? targetH : 2048;
    BitmapFactory.Options opts = new BitmapFactory.Options();
    opts.inSampleSize = sampleSize(bounds.outWidth, bounds.outHeight, wantW, wantH);
    return BitmapFactory.decodeByteArray(data, 0, data.length, opts);
  }

  private static int sampleSize(int w, int h, int reqW, int reqH) {
    int sample = 1;
    while ((w / (sample * 2)) >= reqW && (h / (sample * 2)) >= reqH) sample *= 2;
    return sample;
  }

  // ---- helpers --------------------------------------------------------------

  private static byte[] readAll(InputStream in) throws Exception {
    ByteArrayOutputStream out = new ByteArrayOutputStream(Math.max(8192, in.available()));
    byte[] buf = new byte[8192];
    int n;
    while ((n = in.read(buf)) != -1) out.write(buf, 0, n);
    return out.toByteArray();
  }

  private static File diskFile(Context ctx, String source) {
    File dir = new File(ctx.getCacheDir(), "canopy-img");
    if (!dir.exists()) dir.mkdirs();
    return new File(dir, Integer.toHexString(source.hashCode()) + "_" + (source.length()));
  }

  private static void writeDisk(File f, byte[] bytes) {
    try (FileOutputStream fos = new FileOutputStream(f)) { fos.write(bytes); } catch (Exception ignored) {}
  }

  private CanopyImageLoader() {}
}
