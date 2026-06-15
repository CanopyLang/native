// CanopyHostFabric.h — the iOS Fabric host (Author C, the Renderer).
//
// Declares the two cross-author symbols the SHARED CONTRACT fixes in §6.1/§6.2 — the binding
// interface the Boot layer (CanopyHostCore/Boot/) includes and links against. The production
// implementation lives in CanopyHostFabric.mm (this TU's UIView+Yoga host: makeView, applyProps/
// applyStyle, the Yoga-driven CanopyContainerView, scroll/modal content roots, the colour parser,
// the CADisplayLink animation driver, gestures/text/switch/before-after event wiring).
//
//   §6.1  using CanopyEmitFn = std::function<void(Handle, const std::string&, const std::string&)>;
//   §6.2  std::shared_ptr<CanopyHost> CanopyHostMake(UIView* surface, CanopyEmitFn emit);
//
// The host has NO jsi::Runtime* member (contract §5.1/§6.9): every interactive surface emits
// through the injected CanopyEmitFn; only Boot's makeEmitClosure binds that closure to
// canopy::canopyEmitEvent on the held runtime. This is what closes the "event gap" without the
// renderer ever touching Hermes.

#pragma once

#import <UIKit/UIKit.h>

#include <functional>
#include <memory>
#include <string>

#include "../../../shared/cpp/CanopyFabric.h"  // canopy::CanopyHost, Handle, installCanopyFabric,
                                                // canopyEmitEvent, canopyBoot (portable)

namespace canopy {

// The emit closure injected into the host at construction (contract §5.1, §6.1). The host emits
// every interactive event (press/pan/tap/text/switch/scroll/refresh/before-after/anim edges)
// through this, never touching jsi::Runtime. Author B builds it (makeEmitClosure) from the held
// runtime and hands it to CanopyHostMake.
//   (handle, eventName, payloadJson) — payloadJson is "{}" when empty.
#ifndef CANOPY_EMITFN_DEFINED
#define CANOPY_EMITFN_DEFINED
using CanopyEmitFn = std::function<void(Handle, const std::string& /*name*/,
                                        const std::string& /*payloadJson*/)>;
#endif

// Construct the iOS Fabric host bound to `surface`, emitting interactive events through `emit`
// (contract §5.1, §6.2). Defined in CanopyHostFabric.mm. The Boot layer calls this once at
// startup, between the runtime factory (canopy::makeRuntime(), RNV-4) and installCanopyFabric().
std::shared_ptr<CanopyHost> CanopyHostMake(UIView* surface, CanopyEmitFn emit);

}  // namespace canopy
