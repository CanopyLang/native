// CanopyAbi.h — THE frozen public extension ABI (Phase 4, Escape-hatch M0).
//
// Third-party native components + modules bind against THIS surface and nothing else. It is
// versioned (CANOPY_ABI_VERSION) and deliberately narrow so the host's internal renderer can
// churn without breaking the ecosystem. The version is what an OTA bundle's runtimeVersion
// (canopy.manifest.json, Phase 4 OTA M0) gates against: a bundle built for ABI N must not boot on
// a host speaking ABI != N. Platform-neutral — Android (Java host) and iOS (ObjC++ host) both
// honor it; this header is compiled into both shared-C++ builds.
//
// THE FROZEN JS SURFACE (installed on the host global; consumed by package/external/native.js):
//   Render seam — host implements, the walker calls:
//     __fabric_createView(tag, propsJson)            -> handle
//     __fabric_updateProps(handle, propsJson)
//     __fabric_insertChild(parent, child, index)
//     __fabric_removeChild(parent, child, index)
//     __fabric_setRoot(handle)
//     __fabric_setEvents(handle, namesJson)
//     __fabric_requestFrame(callback)
//   Effect ABI — host implements, the walker calls:
//     __canopy_call(module, method, argsJson, callId) -> int   (>=0 routed, -1 ModuleNotFound)
//     __canopy_cancel(callId)
//   Effect ABI — the walker installs, the host calls:
//     __canopy_boot(rootTag, flagsJson)
//     __canopy_resolve(callId, errJson, resultJson)
//     __canopy_dispatchEvent(handle, name, payloadJson)
//   Stamp — the walker installs:
//     __canopy_abi_version : number   (== CANOPY_ABI_VERSION)
//
// (The dev-only __canopy_sourcemap / __canopy_symbolicate are NOT part of the frozen contract.)
//
// SURVIVAL RULE: adding a NEW function or an OPTIONAL trailing argument is a MINOR change
// (backward compatible — old bundles keep working). REMOVING or RETYPING anything is a MAJOR
// change: bump CANOPY_ABI_VERSION and move every host + the bundles' runtimeVersion in lockstep.
// See docs/extension-abi.md.

#pragma once

#include <string>

#include "CanopyFabric.h"   // canopy::Handle — the view-handle currency
#include "CanopyModules.h"  // canopy::NativeModule — the frozen native-module contract (unchanged)

namespace canopy {

// The frozen ABI version. A bundle manifest's runtimeVersion binds to this integer.
constexpr int CANOPY_ABI_VERSION = 1;

// An opaque, platform-owned native view (Android: a global-ref jobject View; iOS: a UIView*). A
// factory casts it to its concrete type; the host core never inspects it.
using CanopyViewRef = void*;

// CanopyViewFactory — the contract a third-party NATIVE COMPONENT implements so its view class
// mounts for an unknown tag WITHOUT editing the host's makeView switch (Escape-hatch M1/M2). The
// host's makeView default-case consults a registry of these before falling to a plain container;
// built-in tags keep the fast in-switch path.
//
// reset() is MANDATORY: the walker diffs a dropped prop by null-encoding its key, so a recycled
// view must restore that key to its default — otherwise a prior screen's state leaks onto reuse.
class CanopyViewFactory {
 public:
  virtual ~CanopyViewFactory() = default;

  // The tag this factory owns (e.g. "BlurView"), matched against the vnode tag.
  virtual std::string tag() const = 0;

  // Create the native view for a fresh handle; returns the opaque platform view.
  virtual CanopyViewRef create(Handle handle) = 0;

  // Apply a JSON prop bag (the same shape built-ins receive in applyProps).
  virtual void applyProps(CanopyViewRef view, const std::string& propsJson) = 0;

  // Reset prop `key` to its default on a recycled view (MANDATORY — see above).
  virtual void reset(CanopyViewRef view, const std::string& key) = 0;

  // A custom-measured leaf (no Canopy children, sizes itself) returns true; the renderer then
  // routes it through the leaf-measure seam instead of laying out children.
  virtual bool isLeaf() const { return false; }
};

}  // namespace canopy
