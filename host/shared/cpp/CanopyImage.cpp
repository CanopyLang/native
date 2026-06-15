// CanopyImage.cpp — portable RGBA-blob pixel helpers. No platform headers, no JNI.

#include "CanopyImage.h"  // -> CanopyBlobs.h declares globalBlobRegistry() (portable; no JNI pull-in)

#include <algorithm>
#include <cstring>

namespace canopy {

namespace {

inline uint8_t blend(uint8_t s, uint8_t d, uint32_t a) {
  // straight source-over: out = s*a + d*(255-a), rounded, in 0..255.
  return static_cast<uint8_t>((s * a + d * (255u - a) + 127u) / 255u);
}

}  // namespace

BlobHandle imageCompositeOver(BlobHandle dstHandle, BlobHandle srcHandle, int x, int y) {
  auto dst = globalBlobRegistry().get(dstHandle);
  auto src = globalBlobRegistry().get(srcHandle);
  if (!dst || !src || dst->kind != "rgba8" || src->kind != "rgba8") { return 0; }
  if (dst->width <= 0 || dst->height <= 0 || src->width <= 0 || src->height <= 0) { return 0; }

  Blob out;
  out.kind = "rgba8";
  out.width = dst->width;
  out.height = dst->height;
  out.metaJson = dst->metaJson;
  out.bytes = dst->bytes;  // start from a copy of the destination

  const int dw = dst->width, dh = dst->height;
  const int sw = src->width, sh = src->height;
  const uint8_t* sp = src->bytes.data();
  uint8_t* op = out.bytes.data();

  for (int sy = 0; sy < sh; ++sy) {
    int dy = y + sy;
    if (dy < 0 || dy >= dh) { continue; }
    for (int sx = 0; sx < sw; ++sx) {
      int dx = x + sx;
      if (dx < 0 || dx >= dw) { continue; }
      const uint8_t* s = sp + (static_cast<size_t>(sy) * sw + sx) * 4u;
      uint8_t* d = op + (static_cast<size_t>(dy) * dw + dx) * 4u;
      uint32_t a = s[3];
      d[0] = blend(s[0], d[0], a);
      d[1] = blend(s[1], d[1], a);
      d[2] = blend(s[2], d[2], a);
      d[3] = static_cast<uint8_t>(std::min<uint32_t>(255u, a + d[3] * (255u - a) / 255u));
    }
  }

  return globalBlobRegistry().put(std::move(out));
}

BlobHandle imageWipeColumns(BlobHandle aHandle, BlobHandle bHandle, int splitX) {
  auto a = globalBlobRegistry().get(aHandle);
  auto b = globalBlobRegistry().get(bHandle);
  if (!a || !b || a->kind != "rgba8" || b->kind != "rgba8") { return 0; }
  if (a->width != b->width || a->height != b->height) { return 0; }
  if (a->width <= 0 || a->height <= 0) { return 0; }

  const int w = a->width, h = a->height;
  int split = std::max(0, std::min(w, splitX));

  Blob out;
  out.kind = "rgba8";
  out.width = w;
  out.height = h;
  out.metaJson = a->metaJson;
  out.bytes.resize(static_cast<size_t>(w) * h * 4u);

  const size_t rowBytes = static_cast<size_t>(w) * 4u;
  const size_t leftBytes = static_cast<size_t>(split) * 4u;
  for (int row = 0; row < h; ++row) {
    const size_t off = static_cast<size_t>(row) * rowBytes;
    std::memcpy(out.bytes.data() + off, a->bytes.data() + off, leftBytes);
    std::memcpy(out.bytes.data() + off + leftBytes, b->bytes.data() + off + leftBytes,
                rowBytes - leftBytes);
  }

  return globalBlobRegistry().put(std::move(out));
}

}  // namespace canopy
