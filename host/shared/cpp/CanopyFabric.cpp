// CanopyFabric.cpp — JSI installer. Portable across iOS & Android (no platform headers).
//
// Bridges the __fabric_* JS surface (external/native.js) to the CanopyHost mount
// interface. This is the only place jsi::Value is marshalled; the host deals in plain
// strings/ints, so the version-sensitive Fabric API stays behind CanopyHost.

#include "CanopyFabric.h"

// NOTE: marshalling here is via the runtime's own JSON.stringify/parse (see jsonStringify/
// jsonParse below), so no folly::dynamic bridge is needed. (Previously this included
// <jsi/JSIDynamic.h>, which pulls in folly/dynamic.h — an unused, heavyweight dependency.)

using namespace facebook::jsi;

namespace canopy {

namespace {

// --- small jsi helpers ------------------------------------------------------

std::string jsonStringify(Runtime& rt, const Value& v) {
  if (v.isUndefined() || v.isNull()) return "{}";
  auto json = rt.global().getPropertyAsObject(rt, "JSON");
  auto stringify = json.getPropertyAsFunction(rt, "stringify");
  auto out = stringify.call(rt, v);
  return out.isString() ? out.getString(rt).utf8(rt) : "{}";
}

Value jsonParse(Runtime& rt, const std::string& s) {
  auto json = rt.global().getPropertyAsObject(rt, "JSON");
  auto parse = json.getPropertyAsFunction(rt, "parse");
  return parse.call(rt, String::createFromUtf8(rt, s.empty() ? "{}" : s));
}

int asInt(Runtime& /*rt*/, const Value& v) { return v.isNumber() ? (int)v.getNumber() : -1; }

// install one host function as a global named `name`
void installFn(Runtime& rt, const char* name, unsigned argc,
               HostFunctionType fn) {
  auto f = Function::createFromHostFunction(rt, PropNameID::forAscii(rt, name), argc, std::move(fn));
  rt.global().setProperty(rt, name, f);
}

// --- RND-7 batched mutation protocol ---------------------------------------
//
// The walker (external/native.js) collects a frame's mutations and hands the host ONE
// __fabric_applyBatch call instead of N per-mutation calls. This is where that ONE call is
// decoded and replayed against the SAME CanopyHost methods the per-mutation path drives — so the
// host (Android Java / iOS ObjC++) needs NO new method: applyBatch is pure marshalling, exactly
// like the per-mutation installFns. Two wire forms, both handled here:
//
//   Stage B (binary, default): a flat little-endian ArrayBuffer. 1 opcode byte, then the op's
//     fields — i32 ints (4 bytes LE) and uint32-length-prefixed UTF-8 strings. NO per-mutation
//     JSON.parse crosses the seam; only the rare object/event prop carries its JSON string, which
//     the host's own decoder already expected. This is the RND-7 win: the dominant per-frame
//     mutations (scalars + structure) cost a memcpy, not a parse.
//   Stage A (fallback): a JS Array of [opcode, ...args] (one JSON round-trip for the whole frame).
//     Kept so a host/runtime without zero-copy ArrayBuffer access still gets the per-call collapse.
//
// Opcodes MUST match _NB_* in external/native.js.
enum BatchOp {
  kCreate = 1, kUpdate = 2, kScalar = 3, kInsert = 4,
  kRemove = 5, kSetRoot = 6, kSetEvents = 7,
};

// A bounds-checked cursor over the flat batch bytes. Every read validates remaining length and
// throws a JSError on truncation, so a malformed buffer becomes a red-box, never an OOB read.
struct BatchReader {
  Runtime& rt;
  const uint8_t* p;
  size_t n;
  size_t i = 0;
  BatchReader(Runtime& r, const uint8_t* d, size_t len) : rt(r), p(d), n(len) {}

  bool done() const { return i >= n; }
  void need(size_t k, const char* what) {
    if (i + k > n) { throw JSError(rt, std::string("applyBatch: truncated ") + what); }
  }
  uint8_t u8(const char* what) { need(1, what); return p[i++]; }
  int32_t i32(const char* what) {
    need(4, what);
    int32_t v = (int32_t)((uint32_t)p[i] | ((uint32_t)p[i + 1] << 8) |
                          ((uint32_t)p[i + 2] << 16) | ((uint32_t)p[i + 3] << 24));
    i += 4; return v;
  }
  std::string str(const char* what) {
    need(4, what);
    uint32_t len = (uint32_t)p[i] | ((uint32_t)p[i + 1] << 8) |
                   ((uint32_t)p[i + 2] << 16) | ((uint32_t)p[i + 3] << 24);
    i += 4;
    need(len, what);
    std::string s(reinterpret_cast<const char*>(p + i), len);
    i += len; return s;
  }
};

// Replay the binary batch (Stage B). Each op maps 1:1 to the per-mutation host call.
void applyBinaryBatch(Runtime& rt, CanopyHost& host, const uint8_t* data, size_t len) {
  BatchReader r(rt, data, len);
  while (!r.done()) {
    uint8_t op = r.u8("opcode");
    switch (op) {
      case kCreate: { int32_t h = r.i32("create.handle"); std::string tag = r.str("create.tag");
        std::string props = r.str("create.props"); host.createView(tag, props, h); break; }
      case kUpdate: { int32_t h = r.i32("update.handle"); std::string props = r.str("update.props");
        host.updateProps(h, props); break; }
      case kScalar: { int32_t h = r.i32("scalar.handle"); std::string key = r.str("scalar.key");
        std::string val = r.str("scalar.value"); host.updatePropScalar(h, key, val); break; }
      case kInsert: { int32_t pa = r.i32("insert.parent"); int32_t c = r.i32("insert.child");
        int32_t idx = r.i32("insert.index"); host.insertChild(pa, c, idx); break; }
      case kRemove: { int32_t pa = r.i32("remove.parent"); int32_t c = r.i32("remove.child");
        int32_t idx = r.i32("remove.index"); host.removeChild(pa, c, idx); break; }
      case kSetRoot: { int32_t h = r.i32("setRoot.handle"); host.setRoot(h); break; }
      case kSetEvents: { int32_t h = r.i32("setEvents.handle"); std::string names = r.str("setEvents.names");
        host.setEvents(h, names); break; }
      default: throw JSError(rt, "applyBatch: unknown opcode " + std::to_string((int)op));
    }
  }
}

// Replay the Stage-A JSON-array fallback. `arr` is [ [opcode, ...args], ... ] where ints arrive as
// JS numbers and props/tag/names/key/value as JS strings (the walker stringified prop bags once).
void applyJsonBatch(Runtime& rt, CanopyHost& host, const Array& arr) {
  auto numAt = [&](const Array& op, size_t k) -> int {
    Value v = op.getValueAtIndex(rt, k); return v.isNumber() ? (int)v.getNumber() : -1;
  };
  auto strAt = [&](const Array& op, size_t k) -> std::string {
    Value v = op.getValueAtIndex(rt, k); return v.isString() ? v.getString(rt).utf8(rt) : std::string();
  };
  size_t count = arr.size(rt);
  for (size_t i = 0; i < count; i++) {
    Value ev = arr.getValueAtIndex(rt, i);
    if (!ev.isObject() || !ev.getObject(rt).isArray(rt)) continue;
    Array op = ev.getObject(rt).getArray(rt);
    int code = numAt(op, 0);
    switch (code) {
      case kCreate:    host.createView(strAt(op, 2), strAt(op, 3), numAt(op, 1)); break;
      case kUpdate:    host.updateProps(numAt(op, 1), strAt(op, 2)); break;
      case kScalar:    host.updatePropScalar(numAt(op, 1), strAt(op, 2), strAt(op, 3)); break;
      case kInsert:    host.insertChild(numAt(op, 1), numAt(op, 2), numAt(op, 3)); break;
      case kRemove:    host.removeChild(numAt(op, 1), numAt(op, 2), numAt(op, 3)); break;
      case kSetRoot:   host.setRoot(numAt(op, 1)); break;
      case kSetEvents: host.setEvents(numAt(op, 1), strAt(op, 2)); break;
      default: break;
    }
  }
}

}  // namespace

// RND-8 — the UI-thread replay entry. The off-UI-thread host ships the frame's flat binary batch to
// the UI thread (via its BatchSink) and calls THIS there to replay it against the host. It is the
// exact decoder the inline path uses (applyBinaryBatch above), just reached from the UI thread instead
// of inline on the JS thread — so the two paths are behaviourally identical.
void canopyApplyBinaryBatch(Runtime& runtime, CanopyHost& host, const uint8_t* data, size_t len) {
  applyBinaryBatch(runtime, host, data, len);
}

void installCanopyFabric(Runtime& runtime, std::shared_ptr<CanopyHost> host, BatchSink sink) {
  // __fabric_createView(tag, props) -> handle
  installFn(runtime, "__fabric_createView", 2,
    [host](Runtime& rt, const Value&, const Value* a, size_t n) -> Value {
      auto tag = a[0].getString(rt).utf8(rt);
      auto props = n > 1 ? jsonStringify(rt, a[1]) : "{}";
      return Value(host->createView(tag, props));
    });

  // __fabric_updateProps(handle, props)
  installFn(runtime, "__fabric_updateProps", 2,
    [host](Runtime& rt, const Value&, const Value* a, size_t) -> Value {
      host->updateProps(asInt(rt, a[0]), jsonStringify(rt, a[1]));
      return Value::undefined();
    });

  // __fabric_updatePropScalar(handle, key, value) — the AND-8 single-scalar fast path. The
  // walker routes the dominant per-frame mutations (a label's text, an input's value, a view's
  // opacity) here so they skip BOTH the JS-side object allocation AND the JSON.stringify/parse +
  // host-side JSONObject decode that __fabric_updateProps pays. NO jsonStringify: a[1]/a[2] cross
  // as plain jsi strings (the JS boundary already stringified a numeric opacity). Everything
  // else — object/style/event props, removals (null), multi-key deltas — stays on updateProps.
  installFn(runtime, "__fabric_updatePropScalar", 3,
    [host](Runtime& rt, const Value&, const Value* a, size_t n) -> Value {
      auto key = (n > 1 && a[1].isString()) ? a[1].getString(rt).utf8(rt) : std::string();
      auto value = (n > 2 && a[2].isString()) ? a[2].getString(rt).utf8(rt) : std::string();
      host->updatePropScalar(asInt(rt, a[0]), key, value);
      return Value::undefined();
    });

  // __fabric_insertChild(parent, child, index)
  installFn(runtime, "__fabric_insertChild", 3,
    [host](Runtime& rt, const Value&, const Value* a, size_t) -> Value {
      host->insertChild(asInt(rt, a[0]), asInt(rt, a[1]), asInt(rt, a[2]));
      return Value::undefined();
    });

  // __fabric_removeChild(parent, child, index)
  installFn(runtime, "__fabric_removeChild", 3,
    [host](Runtime& rt, const Value&, const Value* a, size_t) -> Value {
      host->removeChild(asInt(rt, a[0]), asInt(rt, a[1]), asInt(rt, a[2]));
      return Value::undefined();
    });

  // __fabric_setRoot(handle)
  installFn(runtime, "__fabric_setRoot", 1,
    [host](Runtime& rt, const Value&, const Value* a, size_t) -> Value {
      host->setRoot(asInt(rt, a[0]));
      return Value::undefined();
    });

  // __fabric_setEvents(handle, [names])
  installFn(runtime, "__fabric_setEvents", 2,
    [host](Runtime& rt, const Value&, const Value* a, size_t) -> Value {
      host->setEvents(asInt(rt, a[0]), jsonStringify(rt, a[1]));
      return Value::undefined();
    });

  // __fabric_command(handle, name, argsJson) — the imperative-op seam (AND-3 / IOS-8).
  // `handle` is the target view, `name` a plain JS string op, `argsJson` an arbitrary value
  // marshalled to JSON. The command runs ASYNC: nothing is returned here; the host emits its
  // result back into JS via canopyEmitEvent(handle, "__commandResult", resultJson). This
  // mirrors setEvents' shape (int handle + marshalled payload) and keeps the version-sensitive
  // op logic behind CanopyHost, exactly like every other __fabric_* call.
  installFn(runtime, "__fabric_command", 3,
    [host](Runtime& rt, const Value&, const Value* a, size_t n) -> Value {
      auto name = (n > 1 && a[1].isString()) ? a[1].getString(rt).utf8(rt) : std::string();
      auto args = n > 2 ? jsonStringify(rt, a[2]) : "{}";
      host->command(asInt(rt, a[0]), name, args);
      return Value::undefined();
    });

  // __fabric_requestFrame(cb)
  installFn(runtime, "__fabric_requestFrame", 1,
    [host](Runtime& rt, const Value&, const Value* a, size_t) -> Value {
      auto cb = std::make_shared<Function>(a[0].getObject(rt).getFunction(rt));
      // Hop back onto the JS thread when the host's vsync fires; the host owns the
      // dispatch (Looper on Android, CADisplayLink/RunLoop on iOS).
      host->requestFrame([cb, &rt]() { cb->call(rt); });
      return Value::undefined();
    });

  // RND-7 — __fabric_applyBatch(blob): apply a WHOLE frame's mutations in ONE host call. `blob` is
  // either an ArrayBuffer (Stage B, the default — zero-copy flat binary, no per-mutation JSON.parse)
  // or, as a fallback, a JS Array of [opcode, ...args] (Stage A). The walker chooses the binary form
  // when we advertise __fabric_batchBinary below. Decoding replays each op against the SAME CanopyHost
  // methods the per-mutation path drives, so the platform host needs no new method.
  installFn(runtime, "__fabric_applyBatch", 1,
    [host, sink](Runtime& rt, const Value&, const Value* a, size_t n) -> Value {
      if (n < 1 || !a[0].isObject()) return Value::undefined();
      Object o = a[0].getObject(rt);
      if (o.isArrayBuffer(rt)) {
        ArrayBuffer ab = o.getArrayBuffer(rt);
        // RND-8: when a BatchSink is installed (the off-UI-thread Android host), hand the frame's
        // flat binary buffer to the sink — which COPIES the bytes and ships them to the UI thread for
        // replay — instead of mutating android.view inline on this (JS) thread. The sink returns true
        // when it took the frame; false (e.g. its UI Looper isn't ready) falls through to inline
        // replay, so a frame is never silently dropped. A null sink (single-thread/iOS/mock) always
        // replays inline, BYTE-FOR-BYTE unchanged.
        if (sink && sink(ab.data(rt), ab.size(rt))) {
          return Value::undefined();
        }
        applyBinaryBatch(rt, *host, ab.data(rt), ab.size(rt));
      } else if (o.isArray(rt)) {
        // Stage-A JSON arrays are not marshalled off-thread (a jsi::Array can't leave the JS thread);
        // they replay inline. The Android off-UI-thread host advertises BINARY, so this path is only
        // reached by a host/runtime without zero-copy ArrayBuffer access — already a slow fallback.
        applyJsonBatch(rt, *host, o.getArray(rt));
      }
      return Value::undefined();
    });

  // Advertise the batch protocol so the walker opts in (it feature-detects __fabric_applyBatch and
  // these stamps — a host without them keeps the per-mutation path). __fabric_batchBinary=true selects
  // Stage B (ArrayBuffer); __fabric_batchHandleBase is the high handle base the walker allocates from
  // (kept clear of the small host-minted boot-time root handle). The host's createView(_,_,handle)
  // override honours those JS-chosen handles.
  runtime.global().setProperty(runtime, "__fabric_batchBinary", Value(true));
  runtime.global().setProperty(runtime, "__fabric_batchHandleBase", Value((double)0x40000000));
}

void canopyEmitEvent(Runtime& runtime, Handle view, const std::string& eventName,
                     const std::string& payloadJson) {
  auto dispatch = runtime.global().getProperty(runtime, "__canopy_dispatchEvent");
  if (!dispatch.isObject() || !dispatch.getObject(runtime).isFunction(runtime)) return;
  dispatch.getObject(runtime).getFunction(runtime).call(
      runtime,
      Value(view),
      String::createFromUtf8(runtime, eventName),
      jsonParse(runtime, payloadJson));
}

void canopyBoot(Runtime& runtime, Handle rootTag, const std::string& flagsJson) {
  auto boot = runtime.global().getProperty(runtime, "__canopy_boot");
  if (!boot.isObject() || !boot.getObject(runtime).isFunction(runtime)) {
    throw JSError(runtime, "canopy: __canopy_boot not found — was the bundle evaluated?");
  }
  boot.getObject(runtime).getFunction(runtime).call(
      runtime, Value(rootTag), jsonParse(runtime, flagsJson));
}

}  // namespace canopy
