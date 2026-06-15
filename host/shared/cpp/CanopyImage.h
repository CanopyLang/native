// CanopyImage.h — minimal, portable RGBA-blob pixel helpers (Foundation, C2).
//
// DECODE / ENCODE / RESIZE all happen Java-side (BitmapFactory / ImageDecoder), where the
// platform codecs and the downsample budget live. The BLOB is the currency: this file only
// provides the few pixel ops that are cleaner in portable C++ than crossing back to Java —
// today just compositing one RGBA blob over another (the "before/after wipe" / watermark
// path the app needs). Everything here operates on canopy::Blob{kind="rgba8"} values
// in the ONE shared globalBlobRegistry(); nothing touches JNI or the jsi::Runtime.
//
// Portable C++ (no platform headers) so iOS can reuse it verbatim. Optional: a capability
// that has no compositing need simply does not call it.

#pragma once

#include "CanopyBlobs.h"

#include <cstdint>

namespace canopy {

// Composite the "rgba8" blob `srcHandle` over the "rgba8" blob `dstHandle` at integer offset
// (x, y), using straight source-over alpha (premultiplied is NOT assumed; the bytes are
// treated as straight R,G,B,A 0..255). Produces a NEW blob (the destination size) and returns
// its handle (refcount 1); the inputs are untouched (the caller still owns/releases them).
// Returns 0 if either handle is not a live "rgba8" blob. Pixels outside the destination are
// clipped. This is the watermark / sticker / before-after-wipe primitive.
BlobHandle imageCompositeOver(BlobHandle dstHandle, BlobHandle srcHandle, int x, int y);

// Produce a NEW "rgba8" blob that is the left `splitX` columns of `aHandle` and the remaining
// columns of `bHandle` (both must be the same size). The before/after wipe reveal at a given
// pixel column. Returns 0 if the handles are not same-size live "rgba8" blobs. (A convenience
// the appBeforeAfter component can bake server-free; the host can also wipe with two
// ImageViews + a clip — this is the all-native alternative.)
BlobHandle imageWipeColumns(BlobHandle aHandle, BlobHandle bHandle, int splitX);

}  // namespace canopy
