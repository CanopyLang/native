// CanopyDiskLruCache.java — a tiny, dependency-free, byte-budgeted LRU disk cache for the
// declarative Image pipeline's network bytes.
//
// The old CanopyImageLoader wrote one file per `hashCode_length` into cacheDir/canopy-img and
// NEVER evicted — a long-running image feed grew that directory without bound. This replaces it
// with a self-contained eviction loop: each get() touches the file's lastModified (the LRU clock)
// and each put() trims the directory back under a fixed byte budget by deleting the
// least-recently-used files first.
//
// It is deliberately NOT jakewharton/androidx DiskLruCache — adding a Maven runtime dependency is
// forbidden here (see CanopyImageLoader's header). It caches raw, pre-decode encoded bytes keyed
// by a caller-supplied key (the source URL), so the on-disk entry is dimension-independent; the
// dimension-aware layer is the in-memory bitmap LruCache above it.
//
// Threading: get()/put() run on CanopyImageLoader's background decode pool (off the UI thread).
// The trim/scan is guarded by a per-instance lock so two concurrent puts don't both delete the
// same victim or race the budget accounting.

package com.canopyhost.views;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.util.Arrays;
import java.util.Comparator;

public final class CanopyDiskLruCache {

  private final File dir;
  private final long maxBytes;
  private final Object lock = new Object();

  /** @param dir cache directory (created if missing); @param maxBytes total byte budget. */
  public CanopyDiskLruCache(File dir, long maxBytes) {
    this.dir = dir;
    this.maxBytes = maxBytes;
    if (!dir.exists()) dir.mkdirs();
  }

  /** Stable on-disk filename for a key (hex hash + length, collision-resistant enough for a cache). */
  static String fileNameFor(String key) {
    return Integer.toHexString(key.hashCode()) + "_" + key.length();
  }

  private File fileFor(String key) {
    return new File(dir, fileNameFor(key));
  }

  /** Read the bytes for {@code key}, or null if absent. Touches the entry's LRU clock on a hit. */
  public byte[] get(String key) {
    File f = fileFor(key);
    synchronized (lock) {
      if (!f.exists() || f.length() == 0) return null;
      // Mark as most-recently-used so the next trim evicts something colder.
      f.setLastModified(System.currentTimeMillis());
      try (FileInputStream fis = new FileInputStream(f)) {
        return readAll(fis, (int) f.length());
      } catch (Exception e) {
        return null;
      }
    }
  }

  /** Persist {@code bytes} under {@code key} (best-effort), then trim back under budget. */
  public void put(String key, byte[] bytes) {
    if (bytes == null || bytes.length == 0) return;
    File f = fileFor(key);
    synchronized (lock) {
      try (FileOutputStream fos = new FileOutputStream(f)) {
        fos.write(bytes);
      } catch (Exception e) {
        // A failed write must not leave a truncated, "valid-looking" entry around.
        if (f.exists()) f.delete();
        return;
      }
      f.setLastModified(System.currentTimeMillis());
      trim();
    }
  }

  /** Current total bytes across all entries (test-visible). */
  long sizeBytes() {
    synchronized (lock) {
      File[] files = dir.listFiles();
      if (files == null) return 0;
      long total = 0;
      for (File f : files) total += f.length();
      return total;
    }
  }

  /** Number of entries currently on disk (test-visible). */
  int entryCount() {
    synchronized (lock) {
      File[] files = dir.listFiles();
      return files == null ? 0 : files.length;
    }
  }

  /** Evict the least-recently-used entries until the directory fits the byte budget. */
  private void trim() {
    File[] files = dir.listFiles();
    if (files == null) return;
    long total = 0;
    for (File f : files) total += f.length();
    if (total <= maxBytes) return;
    // Oldest lastModified first = least recently used first.
    Arrays.sort(files, new Comparator<File>() {
      @Override public int compare(File a, File b) {
        return Long.compare(a.lastModified(), b.lastModified());
      }
    });
    for (File f : files) {
      if (total <= maxBytes) break;
      long len = f.length();
      if (f.delete()) total -= len;
    }
  }

  private static byte[] readAll(FileInputStream in, int hint) throws Exception {
    byte[] out = new byte[Math.max(hint, 16)];
    int off = 0, n;
    while ((n = in.read(out, off, out.length - off)) != -1) {
      off += n;
      if (off == out.length) out = Arrays.copyOf(out, out.length * 2);
    }
    return off == out.length ? out : Arrays.copyOf(out, off);
  }
}
