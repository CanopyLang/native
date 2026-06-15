// CanopyBlobs.cpp — the opaque binary-handle registry. Portable, no platform headers.

#include "CanopyBlobs.h"

namespace canopy {

BlobHandle BlobRegistry::put(Blob blob) {
  std::lock_guard<std::mutex> g(mu_);
  BlobHandle h = next_++;
  Entry e;
  e.blob = std::make_shared<Blob>(std::move(blob));
  e.refs = 1;
  table_.emplace(h, std::move(e));
  return h;
}

std::shared_ptr<Blob> BlobRegistry::get(BlobHandle handle) {
  std::lock_guard<std::mutex> g(mu_);
  auto it = table_.find(handle);
  return it == table_.end() ? nullptr : it->second.blob;
}

void BlobRegistry::retain(BlobHandle handle) {
  std::lock_guard<std::mutex> g(mu_);
  auto it = table_.find(handle);
  if (it != table_.end()) { it->second.refs += 1; }
}

void BlobRegistry::release(BlobHandle handle) {
  std::lock_guard<std::mutex> g(mu_);
  auto it = table_.find(handle);
  if (it == table_.end()) { return; }
  if (--it->second.refs <= 0) { table_.erase(it); }  // frees the native bytes
}

size_t BlobRegistry::liveCount() {
  std::lock_guard<std::mutex> g(mu_);
  return table_.size();
}

}  // namespace canopy
