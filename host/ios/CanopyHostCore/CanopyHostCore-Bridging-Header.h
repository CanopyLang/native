// CanopyHostCore-Bridging-Header.h — Swift <-> ObjC++ interop (Author A, SHARED CONTRACT §2.4).
//
// This is the SINGLE bridging header for the whole core. It exposes to Swift exactly the ObjC
// interfaces the Swift capability modules + app shell need. Author A owns this file; any author
// who adds a NEW ObjC header that Swift must see requests A append the `#import` line here (one
// owner => no merge conflicts on the bridging header, §2.4).
//
// IMPORTANT: only pure-ObjC(++) headers belong here — headers that include <jsi/jsi.h>, Yoga, or
// raw C++ (std::function, templates) must NOT be imported into Swift. The C++ ABI is reached from
// Swift ONLY through the thin ObjC bridge classes below (CanopyNativeModuleBridge, the
// CanopyModule protocol), never by importing the portable C++ headers directly. That keeps Swift
// off the Hermes/JSI ABI entirely (Risk #1) — Swift speaks JSON strings + the CanopyComplete
// block; the .mm bridge does the jsi marshalling.
//
// Each #import below is gated on file existence at integration time: the per-area authors
// (B/E) create these headers. Until a header lands, comment its line — the build still links
// (the Swift side that needs it simply isn't compiled yet).

#ifndef CanopyHostCore_Bridging_Header_h
#define CanopyHostCore_Bridging_Header_h

// --- Author E: the C1 ObjC<->C++ bridge surface the Swift capability modules adopt/use ---
// CanopyModule.h is Swift-SAFE: a pure-ObjC @protocol (no jsi/Yoga/raw-C++), so Swift modules
// adopt <CanopyModule> directly. CanopyNativeModule.h's +registerModule:inRegistry: takes a
// `canopy::ModuleRegistry*` (a C++ type) so it is NOT Swift-safe and is intentionally OMITTED —
// registration is done from ObjC++ (CanopyModuleHost.mm), not Swift. Likewise the
// CanopyModuleSupport helpers (CanopyResolve/CanopyReject) are pure-ObjC and Swift-safe.
#import "Bridge/CanopyModule.h"
// #import "Bridge/CanopyModuleSupport.h"   // <- add once Author E lands it (pure-ObjC helpers)

// --- Author B: the boot view controller (pure UIViewController surface — Swift-safe). The
//     SceneDelegate instantiates CanopyHostViewController() and the AppShell capability calls
//     -setHostStatusBarStyle: on it (§3.6). ---
#import "Boot/CanopyHostViewController.h"

// --- DEV-12: the dev-loop WS client (Swift-safe — its header is pure Foundation/NSURLSession, the
//     ObjC++/JSI marshalling is confined to the .mm). The Swift CanopyDevBootstrap (debug-only) calls
//     +startWithDevHost: from SceneDelegate. The whole client is compiled out of a release build. ---
#import "DevLoop/CanopyDevClient.h"

// DO NOT import here (they pull in <jsi/jsi.h> / Yoga / raw C++ and would drag the Hermes ABI
// into Swift — Risk #1):
//   • Boot/CanopyModuleHost.h          (uses facebook::jsi::Runtime*, canopy::ModuleRegistry)
//   • Bridge/CanopyNativeModule.h      (+registerModule:inRegistry: takes canopy::ModuleRegistry*)
//   • Bridge/CanopyBlobRegistryHost.h  (declares namespace canopy { ... } C++ symbols)
// These are reached from ObjC++ (.mm) only. Swift speaks JSON strings + the CanopyComplete block.

#endif /* CanopyHostCore_Bridging_Header_h */
