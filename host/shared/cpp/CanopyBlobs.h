// CanopyBlobs.h — the opaque binary-handle registry (plan C1 §2.3).
//
// The ABI's marshalling is JSON strings + ints — EXCEPT for anything large or binary
// (decoded bitmaps, model input/output tensors, picked-image bytes, baked cards). A 12 MP
// scan is ~36-48 MB decoded; round-tripping that as base64 JSON through Hermes would OOM
// and is absurd. So binary NEVER crosses the ABI: it lives here, in a native side-table
// keyed by an int32 handle, and only the int crosses into JS — exactly paralleling the
// Fabric view Handle (CanopyFabric.h:27-28).
//
// A module that PRODUCES binary (decode an asset, pick a photo, run inference) registers
// the result with put() and returns {"bitmap": <handle>}. A module that CONSUMES binary
// (display, save, pass to ORT) takes the handle in its argsJson and get()s it. Hermes GC
// never sees the bytes, so lifetime is manual: explicit retain()/release() refcounting
// (C1 §7.2 — a handle consumed by both "display" and "save" must not be freed by the
// first). This is the C1 currency only; C2 (image) owns the decode/downsample policy.
//
// Portable: a platform-neutral byte buffer + shape/EXIF metadata. iOS/Android wrap their
// CGImage/Bitmap behind the same handle in their platform layer; this shared registry is
// the contract they share.

#pragma once

#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

namespace canopy {

using BlobHandle = int32_t;

// A unit of native binary. `kind` distinguishes bitmaps from raw byte blobs ("rgba8",
// "jpeg", "png", "tensor", "bytes", …); width/height are meaningful for bitmaps; metaJson
// carries EXIF/orientation/colorspace or model-tensor shape as needed.
struct Blob {
  std::string kind;
  std::vector<uint8_t> bytes;
  int width = 0;
  int height = 0;
  std::string metaJson;  // "" or a JSON object
};

// A thread-safe, refcounted handle table. put() mints a fresh handle (refcount 1); retain()
// bumps it; release() drops it and frees at zero. get() returns nullptr for an unknown or
// freed handle. Safe to call from worker threads (modules run off the JS thread).
class BlobRegistry {
 public:
  // Register `blob`, returning a fresh handle with refcount 1.
  BlobHandle put(Blob blob);

  // Borrow a blob by handle (nullptr if unknown/freed). The pointer is valid only while the
  // caller holds a reference; copy out what you need rather than retaining the pointer.
  std::shared_ptr<Blob> get(BlobHandle handle);

  // Bump the refcount (a second consumer claims the handle).
  void retain(BlobHandle handle);

  // Drop a reference; frees the native bytes when the count hits zero.
  void release(BlobHandle handle);

  // Diagnostics: how many handles are currently live (for the live-handle leak assertion
  // the image package asserts across a batch — C1/C4).
  size_t liveCount();

 private:
  struct Entry {
    std::shared_ptr<Blob> blob;
    int refs = 0;
  };
  std::mutex mu_;
  std::unordered_map<BlobHandle, Entry> table_;
  BlobHandle next_ = 1;
};

// THE single process-wide BlobRegistry, declared here (the portable header) so platform-neutral
// consumers (CanopyImage.cpp) get it WITHOUT pulling in a platform bridge. The DEFINITION is
// platform-specific: Android in CanopyJni.cpp, iOS in CanopyBlobRegistryHost.mm.
BlobRegistry& globalBlobRegistry();

}  // namespace canopy
