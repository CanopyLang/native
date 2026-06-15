// CanopyBlobs.java — the Bitmap <-> Blob bridge (Java side).
//
// Lets a Java capability move android.graphics.Bitmap pixels in and out of the ONE shared
// C++ BlobRegistry (canopy/native host/shared/cpp/CanopyBlobs.h, reached via the global
// registry in CanopyJni.cpp). Binary NEVER crosses the __canopy_* ABI as JSON — only the
// int handle returned here does. The native bodies live in CanopyJni.cpp.
//
//   • nativeBlobPutBitmap(bitmap) : reads an ARGB_8888 Bitmap into a fresh "rgba8" Blob
//       and returns its int handle (refcount 1). The Bitmap MUST be ARGB_8888 — convert
//       with bitmap.copy(Bitmap.Config.ARGB_8888, false) first if it isn't. Returns 0 on
//       failure.
//   • nativeBlobGetBitmap(handle) : reconstructs an ARGB_8888 Bitmap from the Blob behind
//       a handle (for the host's CanopyBitmap renderer, or to re-encode a processed result).
//       Returns null for an unknown/freed handle.
//   • nativeBlobRelease(handle) : drops one reference; frees the native pixels at zero.
//
// The native chain (libcanopyhost.so + libhermes/jsi/fbjni) is already loaded by
// CanopyHostJni's static initializer; this class declares natives implemented in the same
// .so, so it needs no loadLibrary of its own (referencing CanopyHostJni first guarantees
// the load).

package com.canopyhost;

import android.graphics.Bitmap;

public final class CanopyBlobs {

  static {
    // Force CanopyHostJni's static initializer (which loads libcanopyhost.so) before any
    // native method here is linked.
    CanopyHostJni.ensureLoaded();
  }

  /** Put an ARGB_8888 Bitmap into the shared native BlobRegistry; returns its handle (0 = fail). */
  public static native int nativeBlobPutBitmap(Bitmap bitmap);

  /** Reconstruct an ARGB_8888 Bitmap from a blob handle (null if unknown/freed). */
  public static native Bitmap nativeBlobGetBitmap(int handle);

  /** Release one reference on a blob handle (frees native pixels at zero). */
  public static native void nativeBlobRelease(int handle);

  /** Put a raw byte[] into the shared native BlobRegistry as a "bytes" blob; returns its handle
   *  (refcount 1). The currency for non-bitmap binary (Http bodies, file reads, model tensors) so
   *  capabilities move binary as an int handle, never base64 through JSON. 0 = failure. */
  public static native int nativeBlobPutBytes(byte[] bytes);

  /** Read the bytes behind a blob handle (null if unknown/freed); the array is a fresh copy. */
  public static native byte[] nativeBlobGetBytes(int handle);

  /** Convenience alias for {@link #nativeBlobPutBytes}. */
  public static int putBytes(byte[] bytes) { return nativeBlobPutBytes(bytes); }

  /** Convenience alias for {@link #nativeBlobGetBytes}. */
  public static byte[] getBytes(int handle) { return nativeBlobGetBytes(handle); }

  /** Dev smoke (Phase 4 Capability M0): round-trip a known byte[] through the native registry —
   *  put → get → release — and confirm the bytes survive. Proves the bytes-blob bridge is wired
   *  end to end. Returns true on success. Called once at boot under BuildConfig.DEBUG. */
  public static boolean selfTest() {
    byte[] in = new byte[] { 0, 1, 2, (byte) 0xFF, (byte) 0x80, 42, -7 };
    int h = nativeBlobPutBytes(in);
    if (h == 0) { return false; }
    byte[] out = nativeBlobGetBytes(h);
    nativeBlobRelease(h);
    return java.util.Arrays.equals(in, out);
  }

  /**
   * Convenience: coerce any Bitmap to ARGB_8888 (the only config the bridge accepts) and put
   * it. Returns the handle. The input is recycled only if a copy was made.
   */
  public static int put(Bitmap bitmap) {
    if (bitmap == null) { return 0; }
    if (bitmap.getConfig() != Bitmap.Config.ARGB_8888) {
      Bitmap argb = bitmap.copy(Bitmap.Config.ARGB_8888, false);
      int h = nativeBlobPutBitmap(argb);
      argb.recycle();
      return h;
    }
    return nativeBlobPutBitmap(bitmap);
  }

  private CanopyBlobs() {}
}
