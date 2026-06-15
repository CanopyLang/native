// CanopyBlobRegistryHost.h — the single globalBlobRegistry() decl + UIImage<->Blob bridge (§6.3).
//
// OWNERSHIP NOTE: the SHARED CONTRACT assigns CanopyBlobRegistryHost.{h,mm} to Author E. This
// header reproduces the §6.3 declarations EXACTLY so the capability modules compile against the
// fixed contract in isolation; it declares (does not define) the symbols, so there is no link-time
// conflict with E's authoritative CanopyBlobRegistryHost.mm — that ONE translation unit provides
// the single globalBlobRegistry() definition and the two UIImage bridge functions. The renderer
// (C), Core ML / RestoreEngine (F), and the Image/Album/Share/Photos capabilities (E) all link
// this one symbol so every handle agrees (contract Risk #8: verify single-definition at link).

#pragma once

#import <UIKit/UIKit.h>

#include "CanopyBlobs.h"

namespace canopy {

// THE single process-wide BlobRegistry (defined once, in CanopyBlobRegistryHost.mm). Android's
// equivalent lives in CanopyJni.cpp:173. RestoreEngineModule.cpp / CanopyImage.cpp only
// forward-declare it; this is the iOS definition site.
BlobRegistry& globalBlobRegistry();

// Put a UIImage into globalBlobRegistry() as a tight-stride straight-alpha RGBA8 "rgba8" Blob,
// returning a fresh handle (refcount 1). The blob's width/height are the image's PIXEL size
// (size * scale). Used by the renderer (CanopyBitmap), Image/Photos decode, and composite output.
// NOTE: BlobHandle and the Fabric Handle are both int32_t (§6.1); the §6.3 contract spells these
// with `Handle` — identical underlying type. We use BlobHandle to avoid pulling in CanopyFabric.h.
BlobHandle blobPutUIImage(UIImage* img);

// Build a UIImage from the "rgba8" Blob named by `handle` (nil if the handle is absent or not an
// rgba8 blob). Used by Album/Share/encode consumers and the CanopyBitmap renderer.
UIImage* blobGetUIImage(BlobHandle handle);

}  // namespace canopy
