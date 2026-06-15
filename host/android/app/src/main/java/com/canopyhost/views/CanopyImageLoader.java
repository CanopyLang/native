// CanopyImageLoader.java — the declarative Image `source` loader for RCTImageView.
//
// RN's <Image source={{uri}}> loads a URL/file/asset/content image by STRING, with memory +
// disk caching, downsampling to the target view, and onLoad/onError callbacks. The host's
// existing bitmapHandle path (CanopyBlobs) is for native-produced pixels and stays untouched;
// this is the complementary by-string path. It is dependency-free on purpose — the host has so
// far vendored only .so's, and a build-time Maven fetch (Glide/Coil) could fail offline — so
// this implements the small slice of an image pipeline we actually need with plain
// HttpURLConnection + BitmapFactory + an LruCache + a bounded disk cache.
//
// Supported source schemes:
//   http(s)://host/path   → network download (disk-cached by source, then memory-cached)
//   file:///abs/path  or  /abs/path   → local file
//   asset:NAME  or  asset://NAME      → app assets (src/main/assets)
//   content://…           → ContentResolver (gallery/picker URIs)
//
// Caching (AND-6):
//   - MEMORY: an LruCache keyed by source + the TARGET DIMENSIONS the bitmap was decoded for, so
//     the same URL at two sizes does not collide and a large decode does not evict a small one's
//     hit. The key buckets dims to the chosen sampleSize so scroll jitter doesn't thrash it.
//   - DISK: a byte-budgeted CanopyDiskLruCache (LRU eviction) of the raw network bytes, keyed by
//     source only (pre-decode bytes are dimension-independent). Replaces the old unbounded
//     hashCode-named files that never evicted.
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
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ThreadFactory;

public final class CanopyImageLoader {

  /** Result delivered on the UI thread: exactly one of bitmap / error is non-null. */
  public interface Callback {
    void onResult(Bitmap bitmap, String error);
  }

  // Memory cache: ~1/8 of the app heap, keyed by source+dims (see memKey). Sized in KB.
  private static final LruCache<String, Bitmap> MEM =
      new LruCache<String, Bitmap>((int) (Runtime.getRuntime().maxMemory() / 1024 / 8)) {
        @Override protected int sizeOf(String key, Bitmap b) { return b.getByteCount() / 1024; }
      };

  // Disk cache: 50MB byte budget, LRU-evicted, keyed by source. Lazily created against the app
  // cacheDir on first network load (so unit tests that never touch the network never need a Context).
  private static final long DISK_BUDGET_BYTES = 50L * 1024 * 1024;
  private static volatile CanopyDiskLruCache DISK;

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
    load(ctx, source, targetW, targetH, null, cb);
  }

  /**
   * As {@link #load(Context, String, int, int, Callback)} but with optional request {@code headers}
   * applied to a network (http/https) fetch — e.g. an Authorization bearer for a private CDN. The
   * headers do NOT participate in the cache key (a given URL is one resource regardless of which
   * auth fetched it); pass null/empty for the common public-asset case.
   */
  public static void load(Context ctx, String source, int targetW, int targetH,
                          Map<String, String> headers, Callback cb) {
    if (source == null || source.isEmpty()) { cb.onResult(null, "empty source"); return; }
    final int wantW = targetW > 0 ? targetW : CAP;
    final int wantH = targetH > 0 ? targetH : CAP;
    final String key = memKey(source, wantW, wantH);
    Bitmap cached = MEM.get(key);
    if (cached != null) { cb.onResult(cached, null); return; }
    final Context app = ctx.getApplicationContext();
    final Map<String, String> hdrs = headers;
    POOL.execute(() -> {
      Bitmap bmp = null; String err = null;
      try {
        byte[] data = read(app, source, hdrs);
        bmp = decode(data, wantW, wantH);
        if (bmp == null) err = "decode failed";
      } catch (Exception e) {
        err = e.getClass().getSimpleName() + (e.getMessage() != null ? ": " + e.getMessage() : "");
      }
      final Bitmap result = bmp; final String error = err;
      MAIN.post(() -> {
        if (result != null) MEM.put(key, result);
        cb.onResult(result, error);
      });
    });
  }

  /** The default per-axis cap when a target dimension is unknown (0). */
  static final int CAP = 2048;

  /**
   * Memory-cache key: source + the dimensions the decode is bucketed to. We bucket the target
   * dims down to the chosen sampleSize's bucket so that scroll jitter (a row that settles at
   * 199px vs 201px) reuses one cache entry instead of decoding twice. Test-visible.
   */
  static String memKey(String source, int wantW, int wantH) {
    return source + "|" + bucket(wantW) + "x" + bucket(wantH);
  }

  // Bucket a requested dimension into power-of-two-ish bands so near-equal target sizes collapse
  // to one key. Bands: ≤64, ≤128, ≤256, ≤512, ≤1024, ≤2048, else the cap.
  private static int bucket(int v) {
    int b = 64;
    while (b < v && b < CAP) b <<= 1;
    return Math.min(b, CAP);
  }

  // ---- source → bytes -------------------------------------------------------

  private static byte[] read(Context ctx, String source, Map<String, String> headers) throws Exception {
    String low = source.toLowerCase();
    if (low.startsWith("http://") || low.startsWith("https://")) return readHttp(ctx, source, headers);
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

  private static CanopyDiskLruCache disk(Context ctx) {
    CanopyDiskLruCache d = DISK;
    if (d == null) {
      synchronized (CanopyImageLoader.class) {
        d = DISK;
        if (d == null) {
          d = new CanopyDiskLruCache(new File(ctx.getCacheDir(), "canopy-img"), DISK_BUDGET_BYTES);
          DISK = d;
        }
      }
    }
    return d;
  }

  private static byte[] readHttp(Context ctx, String source, Map<String, String> headers) throws Exception {
    CanopyDiskLruCache cache = disk(ctx);
    byte[] cachedBytes = cache.get(source);
    if (cachedBytes != null) return cachedBytes;
    HttpURLConnection conn = (HttpURLConnection) new URL(source).openConnection();
    conn.setConnectTimeout(15000);
    conn.setReadTimeout(20000);
    conn.setInstanceFollowRedirects(true);
    conn.setRequestProperty("User-Agent", "CanopyNative/0.1");
    if (headers != null) {
      for (Map.Entry<String, String> e : headers.entrySet()) {
        if (e.getKey() != null && e.getValue() != null) conn.setRequestProperty(e.getKey(), e.getValue());
      }
    }
    try {
      int code = conn.getResponseCode();
      if (code < 200 || code >= 300) throw new Exception("HTTP " + code);
      byte[] bytes;
      try (InputStream in = new BufferedInputStream(conn.getInputStream())) { bytes = readAll(in); }
      cache.put(source, bytes);                                // bounded, LRU-evicting persist
      return bytes;
    } finally {
      conn.disconnect();
    }
  }

  // ---- bytes → bitmap (two-pass downsample) ---------------------------------

  static Bitmap decode(byte[] data, int targetW, int targetH) {
    BitmapFactory.Options bounds = new BitmapFactory.Options();
    bounds.inJustDecodeBounds = true;
    BitmapFactory.decodeByteArray(data, 0, data.length, bounds);
    if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null;
    int wantW = targetW > 0 ? targetW : CAP;
    int wantH = targetH > 0 ? targetH : CAP;
    BitmapFactory.Options opts = new BitmapFactory.Options();
    opts.inSampleSize = sampleSize(bounds.outWidth, bounds.outHeight, wantW, wantH);
    return BitmapFactory.decodeByteArray(data, 0, data.length, opts);
  }

  /**
   * The largest power-of-two sample factor that keeps the decoded image at least as large as the
   * request on both axes. Test-visible (the LRU/sampleSize unit test pins this math).
   */
  static int sampleSize(int w, int h, int reqW, int reqH) {
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

  // ---- test seams -----------------------------------------------------------

  /** Test-only: directly seed/inspect the shared memory cache. */
  static void memPut(String source, int wantW, int wantH, Bitmap b) {
    MEM.put(memKey(source, wantW > 0 ? wantW : CAP, wantH > 0 ? wantH : CAP), b);
  }

  static Bitmap memGet(String source, int wantW, int wantH) {
    return MEM.get(memKey(source, wantW > 0 ? wantW : CAP, wantH > 0 ? wantH : CAP));
  }

  static void memClear() { MEM.evictAll(); }

  private CanopyImageLoader() {}
}
