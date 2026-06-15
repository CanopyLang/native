// CanopyImageLoaderTest.java — JVM unit test for the AND-6 image cache/sample/eviction/gating math.
//
// Runs on the host JVM via `:app:testDebugUnitTest` (no device). Robolectric supplies shadows for
// the Android framework types the loader touches (android.graphics.Bitmap, android.util.LruCache),
// so the in-memory cache de-dup can be exercised without an emulator. The pure helpers
// (sampleSize, memKey, the disk-eviction loop, event gating) need no framework and assert directly.
//
// Coverage maps to the AND-6 test strategy:
//   (a) sampleSize() picks the right power-of-two for source-vs-target dims.
//   (b) memKey() de-dups same source+dims to ONE cache entry (and separates differing dims).
//   (c) identical source+dims is served from the MEM cache (no second decode).
//   (d) CanopyDiskLruCache evicts the least-recently-used entries past its byte budget.
//   (e) load/error/loadEnd events are gated by the subscribed-name set (CanopyHost.parseImageEvents).

package com.canopyhost.views;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertSame;
import static org.junit.Assert.assertTrue;

import android.graphics.Bitmap;

import com.canopyhost.CanopyHost;

import org.junit.After;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;

import java.io.File;
import java.nio.file.Files;
import java.util.Set;

@RunWith(RobolectricTestRunner.class)
public final class CanopyImageLoaderTest {

  @After
  public void tearDown() {
    CanopyImageLoader.memClear();
  }

  // (a) sampleSize: the largest power-of-two factor that keeps the decode ≥ the request on both axes.
  @Test
  public void sampleSize_picksCorrectPowerOfTwo() {
    // 4000x3000 toward 1000x750: /4 → 1000x750 still ≥ request, /8 would undershoot → 4.
    assertEquals(4, CanopyImageLoader.sampleSize(4000, 3000, 1000, 750));
    // 2000x2000 toward 1000x1000: /2 → 1000x1000 ≥ request → 2.
    assertEquals(2, CanopyImageLoader.sampleSize(2000, 2000, 1000, 1000));
    // Source smaller than request: never upsample → 1.
    assertEquals(1, CanopyImageLoader.sampleSize(500, 500, 1000, 1000));
    // Exact 2x on one axis only: must not over-sample (the smaller axis gates it).
    assertEquals(1, CanopyImageLoader.sampleSize(2000, 1000, 1000, 1000));
  }

  // (b) memKey: same source + same target dims → one key; differing dims → different keys.
  @Test
  public void memKey_dedupsBySourceAndDims() {
    String a = CanopyImageLoader.memKey("http://x/y.png", 200, 200);
    String b = CanopyImageLoader.memKey("http://x/y.png", 201, 199); // jitter buckets to the same band
    String c = CanopyImageLoader.memKey("http://x/y.png", 1000, 1000);
    String d = CanopyImageLoader.memKey("http://z/q.png", 200, 200);
    assertEquals("scroll jitter must collapse to one cache key", a, b);
    assertFalse("a clearly larger target is a distinct decode", a.equals(c));
    assertFalse("a different source is a distinct entry", a.equals(d));
  }

  // (c) MEM cache: a seeded source+dims returns the SAME Bitmap instance (no re-decode).
  @Test
  public void memCache_servesCachedInstance() {
    Bitmap bmp = Bitmap.createBitmap(32, 32, Bitmap.Config.ARGB_8888);
    CanopyImageLoader.memPut("http://x/y.png", 200, 200, bmp);
    Bitmap got1 = CanopyImageLoader.memGet("http://x/y.png", 200, 200);
    Bitmap got2 = CanopyImageLoader.memGet("http://x/y.png", 201, 199); // same bucket → same hit
    assertNotNull(got1);
    assertSame("cache must hand back the identical instance, not a re-decode", bmp, got1);
    assertSame("jittered dims hit the same entry", bmp, got2);
    assertNull("a different target size is a miss", CanopyImageLoader.memGet("http://x/y.png", 1000, 1000));
  }

  // (d) Disk cache: writing past the byte budget evicts the least-recently-used entry first.
  @Test
  public void diskCache_evictsLruPastBudget() throws Exception {
    File dir = Files.createTempDirectory("canopy-disk-test").toFile();
    // Budget = 25 bytes; each entry is 10 bytes → at most 2 fit.
    CanopyDiskLruCache cache = new CanopyDiskLruCache(dir, 25);
    byte[] ten = new byte[10];

    cache.put("a", ten);
    cache.put("b", ten);
    assertEquals(2, cache.entryCount());
    assertNotNull(cache.get("a"));
    assertNotNull(cache.get("b"));

    // Touch "a" so "b" becomes the least-recently-used, then overflow with "c".
    // (lastModified has ms granularity; nudge "a" forward to guarantee ordering.)
    new File(dir, CanopyDiskLruCache.fileNameFor("a")).setLastModified(System.currentTimeMillis() + 10_000);
    new File(dir, CanopyDiskLruCache.fileNameFor("b")).setLastModified(System.currentTimeMillis() - 10_000);
    cache.put("c", ten);

    assertTrue("total bytes must stay within budget", cache.sizeBytes() <= 25);
    assertNotNull("freshly-written c survives", cache.get("c"));
    assertNotNull("recently-touched a survives", cache.get("a"));
    assertNull("the LRU entry b is evicted", cache.get("b"));
  }

  // (e) Event gating: only subscribed load lifecycle events are recognised; a substring is not a hit.
  @Test
  public void eventGating_recognisesOnlySubscribedNames() {
    Set<String> onlyLoad = CanopyHost.parseImageEvents("[\"press\",\"load\"]");
    assertTrue(onlyLoad.contains("load"));
    assertFalse("error not subscribed → must not be emitted", onlyLoad.contains("error"));
    assertFalse(onlyLoad.contains("loadEnd"));

    Set<String> all = CanopyHost.parseImageEvents("[\"load\",\"error\",\"loadEnd\"]");
    assertTrue(all.contains("load"));
    assertTrue(all.contains("error"));
    assertTrue(all.contains("loadEnd"));

    // "loadEnd" must NOT spuriously register "load" via substring matching, and vice-versa.
    Set<String> onlyLoadEnd = CanopyHost.parseImageEvents("[\"loadEnd\"]");
    assertTrue(onlyLoadEnd.contains("loadEnd"));
    assertFalse("quoted-token match: load is a distinct token from loadEnd", onlyLoadEnd.contains("load"));

    assertTrue("empty/absent subscription emits nothing", CanopyHost.parseImageEvents("[]").isEmpty());
    assertTrue("null is safe", CanopyHost.parseImageEvents(null).isEmpty());
  }
}
