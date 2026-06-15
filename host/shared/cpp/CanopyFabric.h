// CanopyFabric.h — the portable C++ JSI surface for canopy/native.
//
// This installs the __fabric_* host functions that external/native.js calls, and an
// event path back into JS. It is deliberately split into two layers:
//
//   • CanopyFabric (this file)  — portable JSI glue: marshals jsi::Value <-> a small
//                                 CanopyHost interface. No platform headers, no React
//                                 component headers. Same on iOS and Android.
//   • CanopyHost   (abstract)   — the per-platform mount implementation that actually
//                                 creates/updates/inserts native views via React
//                                 Native's New-Architecture Fabric mounting API. iOS
//                                 implements it in CanopyHostFabric.mm; Android in
//                                 CanopyHostFabric.cpp.
//
// This is the elm-native-ui survival rule in code (architecture.md §3): JS binds only
// to the stable __fabric_* surface; everything version-sensitive lives behind
// CanopyHost on the native side, isolated to one file per platform.

#pragma once

#include <jsi/jsi.h>
#include <memory>
#include <string>

namespace canopy {

// A native view handle. Opaque to JS (an integer), meaningful to the host.
using Handle = int32_t;

// The per-platform mount surface. Each method maps 1:1 to a __fabric_* call and must
// be implemented against the platform's Fabric mounting layer.
class CanopyHost {
 public:
  virtual ~CanopyHost() = default;

  // Create a native view for a Fabric component name (e.g. "RCTView", "RCTText").
  // `propsJson` is a JSON object of initial props. Returns a fresh handle.
  virtual Handle createView(const std::string& fabricComponentName,
                            const std::string& propsJson) = 0;

  // Apply a partial props update (only changed keys; a key set to null is a removal).
  virtual void updateProps(Handle view, const std::string& propsJson) = 0;

  // Mount `child` under `parent` at `index` (also used to reorder an existing child).
  virtual void insertChild(Handle parent, Handle child, int index) = 0;

  // Unmount `child` from `parent`.
  virtual void removeChild(Handle parent, Handle child, int index) = 0;

  // Attach `view` as the content of the root surface.
  virtual void setRoot(Handle view) = 0;

  // Declare which native events `view` should emit back into JS (e.g. {"press"}).
  virtual void setEvents(Handle view, const std::string& eventNamesJson) = 0;

  // Schedule `cb` on the next UI vsync (the native animator tick).
  virtual void requestFrame(std::function<void()> cb) = 0;
};

// Installs the __fabric_* globals + the event dispatcher bridge onto `runtime`, backed
// by `host`. Call once, right after creating the Hermes runtime and before evaluating
// the Canopy bundle. After the bundle is evaluated, call canopyBoot().
void installCanopyFabric(facebook::jsi::Runtime& runtime, std::shared_ptr<CanopyHost> host);

// Deliver a native event into JS: invokes globalThis.__canopy_dispatchEvent(handle,
// eventName, payload). The host calls this when a gesture/text event fires.
void canopyEmitEvent(facebook::jsi::Runtime& runtime, Handle view,
                     const std::string& eventName, const std::string& payloadJson);

// Run the compiled program against the root surface: calls globalThis.__canopy_boot(
// rootTag, flags). Call once after the bundle has been evaluated.
void canopyBoot(facebook::jsi::Runtime& runtime, Handle rootTag, const std::string& flagsJson);

}  // namespace canopy
