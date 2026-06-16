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
#include <cstdint>
#include <functional>
#include <memory>
#include <string>

namespace canopy {

// A native view handle. Opaque to JS (an integer), meaningful to the host.
using Handle = int32_t;

// Minimal JSON string-literal escaper (quotes + control/backslash/quote escapes). Used ONLY by
// the defaulted updatePropScalar fallback below to reconstruct a {key:value} object for an
// un-overridden host. A host that overrides updatePropScalar never calls this. Inline so the
// header stays self-contained (no new .cpp dependency for the additive seam).
inline std::string jsonStringEscape(const std::string& s) {
  std::string out;
  out.reserve(s.size() + 2);
  out.push_back('"');
  for (char c : s) {
    switch (c) {
      case '"':  out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        if (static_cast<unsigned char>(c) < 0x20) {
          static const char* kHex = "0123456789abcdef";
          out += "\\u00";
          out.push_back(kHex[(c >> 4) & 0xF]);
          out.push_back(kHex[c & 0xF]);
        } else {
          out.push_back(c);
        }
    }
  }
  out.push_back('"');
  return out;
}

// The per-platform mount surface. Each method maps 1:1 to a __fabric_* call and must
// be implemented against the platform's Fabric mounting layer.
class CanopyHost {
 public:
  virtual ~CanopyHost() = default;

  // Create a native view for a Fabric component name (e.g. "RCTView", "RCTText").
  // `propsJson` is a JSON object of initial props. Returns a fresh handle.
  virtual Handle createView(const std::string& fabricComponentName,
                            const std::string& propsJson) = 0;

  // RND-7 batch variant: create a view at a JS-CHOSEN handle. The batched protocol allocates
  // handles on the JS side (the walker cannot block on a host return when collapsing a whole
  // frame into one __fabric_applyBatch), so this maps the host's view into ITS table under the
  // walker's `handle` and returns it. `handle` is drawn from a high base the host advertises
  // (__fabric_batchHandleBase) so it never collides with a host-minted boot-time handle.
  //
  // Defaulted (NOT pure-virtual) so this is a strictly ADDITIVE, MINOR ABI change: a host that
  // predates batching still compiles AND a batched bundle on such a host simply never reaches this
  // (the walker only batches when the host advertises __fabric_applyBatch). The default forwards to
  // the 2-arg createView and IGNORES the requested handle — correct ONLY for a host whose handle
  // space happens to match; a real batching host MUST override this to honour `handle` (see
  // CanopyHost.java::createViewWithHandle). CANOPY_ABI_VERSION is deliberately NOT bumped.
  virtual Handle createView(const std::string& fabricComponentName,
                            const std::string& propsJson, Handle handle) {
    (void)handle;
    return createView(fabricComponentName, propsJson);
  }

  // Apply a partial props update (only changed keys; a key set to null is a removal).
  virtual void updateProps(Handle view, const std::string& propsJson) = 0;

  // Fast-path for the dominant per-frame SCALAR mutations (text/value/opacity): apply ONE
  // string-valued key to `view` WITHOUT a JSON object round-trip. The walker
  // (external/native.js) routes a single-scalar diff here; everything else (object/style/event
  // props, removals/nulls, multi-key deltas) stays on the JSON updateProps path. `value` is
  // always a plain string — a number (e.g. opacity) is stringified at the JS boundary, mirroring
  // how the existing Java host coerces everything through optString/parseFloat.
  //
  // Defaulted (NOT pure-virtual) to a JSON-shaped fallback so this is a strictly ADDITIVE, MINOR
  // ABI change: a host that predates the fast path still compiles AND behaves identically — it
  // simply reconstructs the {key:value} object and reuses updateProps. CANOPY_ABI_VERSION is
  // deliberately NOT bumped (CanopyAbi.h survival rule). A host that wants the win overrides this
  // to skip the JSONObject allocation entirely (see CanopyHost.java::updatePropScalar).
  virtual void updatePropScalar(Handle view, const std::string& key, const std::string& value) {
    updateProps(view, std::string("{") + jsonStringEscape(key) + ":" + jsonStringEscape(value) + "}");
  }

  // Mount `child` under `parent` at `index` (also used to reorder an existing child).
  virtual void insertChild(Handle parent, Handle child, int index) = 0;

  // Unmount `child` from `parent`.
  virtual void removeChild(Handle parent, Handle child, int index) = 0;

  // Attach `view` as the content of the root surface.
  virtual void setRoot(Handle view) = 0;

  // Declare which native events `view` should emit back into JS (e.g. {"press"}).
  virtual void setEvents(Handle view, const std::string& eventNamesJson) = 0;

  // Run an imperative command against `view`. This is the ONE imperative-command seam — IOS-8's
  // proposed __fabric_callMethod is RECONCILED INTO THIS, not added alongside it: there is exactly
  // one global (__fabric_command) and one host virtual (command()) shared by BOTH platforms. `name`
  // is the operation (e.g. "focus"/"blur"/"measure"/"scrollTo"/"scrollToIndex"); `argsJson` is a
  // JSON object of arguments (it carries a `__callId` the walker splices in so concurrent ops on one
  // handle each route to their own one-shot). The command runs asynchronously: its result is NOT
  // returned here — the host delivers it back into JS via canopyEmitEvent(view, "__commandResult",
  // resultJson), echoing that __callId. AND-3 wired the seam end-to-end with a trivial echo; AND-4
  // (Android) and IOS-8 (iOS) implement the real focus/blur/measure/scrollTo/scrollToIndex ops in
  // each platform's CanopyHost override.
  //
  // Defaulted to a no-op (not pure-virtual) so this is a strictly ADDITIVE, MINOR ABI change: an
  // existing host that predates the seam still compiles unchanged. CANOPY_ABI_VERSION is
  // deliberately NOT bumped.
  virtual void command(Handle view, const std::string& name, const std::string& argsJson) {
    (void)view; (void)name; (void)argsJson;
  }

  // Schedule `cb` on the next UI vsync (the native animator tick).
  virtual void requestFrame(std::function<void()> cb) = 0;
};

// RND-8 — the off-UI-thread batch sink. A BatchSink, when installed, INTERCEPTS the whole frame's
// flat binary batch (the RND-7 Stage-B ArrayBuffer) at __fabric_applyBatch and hands the host a COPY
// of the bytes, instead of replaying them inline on the calling (JS) thread. This is the seam that
// lets the JS/Hermes runtime live on a DEDICATED thread (RND-8): the walker builds the frame's
// mutation buffer on the JS thread, the sink ships that one buffer to the UI thread, and the host
// replays it there (where android.view writes are legal) via canopyApplyBinaryBatch below.
//
// `data`/`len` are valid ONLY for the duration of the call — the sink MUST copy them (the underlying
// jsi::ArrayBuffer is owned by the JS thread and may be GC'd the instant applyBatch returns). The sink
// returns true when it TOOK ownership of the frame (the host will replay it on the UI thread); false
// to fall through to the default inline replay (so a host can decline per-frame, e.g. before its UI
// Looper exists). A null sink (the default — single-thread hosts, iOS, the mock) keeps the inline
// replay BYTE-FOR-BYTE unchanged: this is a strictly additive seam behind a feature flag.
//
// Only the BINARY (Stage B) form is marshalled; a Stage-A JSON-array batch still replays inline
// (binary is the default the Android host advertises, and a flat byte buffer is the only form that is
// cheap + safe to copy across the thread boundary — a jsi::Array cannot leave the JS thread).
using BatchSink = std::function<bool(const uint8_t* data, size_t len)>;

// Replay a flat binary (Stage B) batch against `host`. This is the SAME decoder __fabric_applyBatch
// uses inline; exposed so the RND-8 host can call it on the UI thread after the sink shipped the bytes
// there. Pure marshalling — every op maps 1:1 to a CanopyHost method (createView/updateProps/…), so
// the UI-thread replay is identical to the inline one. Throws a jsi::JSError (caught by the host's
// guard) on a truncated/garbage buffer, never an OOB read.
void canopyApplyBinaryBatch(facebook::jsi::Runtime& runtime, CanopyHost& host,
                            const uint8_t* data, size_t len);

// Installs the __fabric_* globals + the event dispatcher bridge onto `runtime`, backed
// by `host`. Call once, right after creating the Hermes runtime and before evaluating
// the Canopy bundle. After the bundle is evaluated, call canopyBoot().
//
// `sink` (RND-8, optional/default-null): when non-null, __fabric_applyBatch routes each frame's
// BINARY batch through it (off-UI-thread marshalling) instead of replaying inline. Pass null (the
// default) for the single-thread JS==UI host, iOS, and the test mock — the inline path is unchanged.
void installCanopyFabric(facebook::jsi::Runtime& runtime, std::shared_ptr<CanopyHost> host,
                         BatchSink sink = nullptr);

// Deliver a native event into JS: invokes globalThis.__canopy_dispatchEvent(handle,
// eventName, payload). The host calls this when a gesture/text event fires.
void canopyEmitEvent(facebook::jsi::Runtime& runtime, Handle view,
                     const std::string& eventName, const std::string& payloadJson);

// Run the compiled program against the root surface: calls globalThis.__canopy_boot(
// rootTag, flags). Call once after the bundle has been evaluated.
void canopyBoot(facebook::jsi::Runtime& runtime, Handle rootTag, const std::string& flagsJson);

}  // namespace canopy
