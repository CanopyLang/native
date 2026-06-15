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

}  // namespace

void installCanopyFabric(Runtime& runtime, std::shared_ptr<CanopyHost> host) {
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
