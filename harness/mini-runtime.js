// Mini-runtime — a faithful TEST DOUBLE for the slice of core/runtime.js that the
// feasibility research already proved portable (the TEA loop + scheduler are
// browser-free and run unmodified on Hermes). It exists ONLY so the harness can run
// the REAL external/native.js walker + the REAL `element` seam in plain Node, with
// no compiler and no device.
//
// In a shipped app these globals come VERBATIM from the compiled Canopy bundle
// (core/runtime.js inlined), NOT from this file. Everything here mirrors the exact
// shapes native.js depends on:
//   • F2..F9 / A2..A9  currying ABI
//   • _Utils_Tuple0    the () value
//   • _List_Nil/Cons   cons-cell lists ({ a: head, b: tail })
//   • _Platform_initialize(flagDecoder, args, init, update, subscriptions, stepperBuilder)
//   • _Json_runHelp / a tiny Json.Decode interpreter (succeed/field/map/string/int/bool)
//
// We install them on globalThis so `require('../package/external/native.js')` finds
// them, exactly as it would find the inlined runtime in a real bundle.

'use strict';

const g = globalThis;

// ---- currying ABI (verbatim shape from the Canopy runtime) -----------------
function curry(arity, fn) {
    return function curried(...args) {
        return args.length >= arity ? fn(...args) : (...more) => curried(...args, ...more);
    };
}
g.F2 = fn => curry(2, fn);
g.F3 = fn => curry(3, fn);
g.F4 = fn => curry(4, fn);
g.F5 = fn => curry(5, fn);
g.F6 = fn => curry(6, fn);
g.F7 = fn => curry(7, fn);
g.F8 = fn => curry(8, fn);
g.F9 = fn => curry(9, fn);
g.A2 = (f, a, b) => f(a)(b);
g.A3 = (f, a, b, c) => f(a)(b)(c);
g.A4 = (f, a, b, c, d) => f(a)(b)(c)(d);
g.A5 = (f, a, b, c, d, e) => f(a)(b)(c)(d)(e);

// ---- the () value ----------------------------------------------------------
g._Utils_Tuple0 = { $: '#0' };

// ---- cons-cell lists -------------------------------------------------------
g._List_Nil = { $: '[]' };
g._List_Cons = F2((head, tail) => ({ $: '::', a: head, b: tail }));
g._List_fromArray = arr => {
    let out = g._List_Nil;
    for (let i = arr.length - 1; i >= 0; i--) out = { $: '::', a: arr[i], b: out };
    return out;
};

// ---- a tiny Json.Decode interpreter ---------------------------------------
// Decoders are plain tagged objects produced by counter-view.js's Json shim; this
// runs one against a payload, returning Ok/Err in the runtime's {$,a} shape.
function ok(v) { return { $: 0, a: v }; }
function err(m) { return { $: 1, a: m }; }
g._Json_runHelp = function _Json_runHelp(decoder, payload) {
    switch (decoder.tag) {
        case 'succeed': return ok(decoder.value);
        case 'fail':    return err(decoder.message);
        case 'string':  return typeof payload === 'string' ? ok(payload) : err('expected string');
        case 'int':     return Number.isInteger(payload) ? ok(payload) : err('expected int');
        case 'bool':    return typeof payload === 'boolean' ? ok(payload) : err('expected bool');
        case 'field': {
            if (payload == null || !(decoder.key in payload)) return err('missing field ' + decoder.key);
            return _Json_runHelp(decoder.decoder, payload[decoder.key]);
        }
        case 'map': {
            const r = _Json_runHelp(decoder.decoder, payload);
            return r.$ === 0 ? ok(decoder.fn(r.a)) : r;
        }
        default: return err('unknown decoder');
    }
};
g._Json_wrap = x => x;
g._Json_unwrap = x => x;
g._Json_run = F2((decoder, value) => g._Json_runHelp(decoder, value));

// ---- _Platform_initialize --------------------------------------------------
// Mirror of core/runtime.js:954-974 (see workflow map). Effects (Cmd/Sub) are not
// exercised by the wedge POC, so we accept and ignore the bags — the research's
// Phase 3 wires real native effect backends.
g._Platform_initialize = function _Platform_initialize(flagDecoder, args, init, update, subscriptions, stepperBuilder) {
    const initPair = init(args && args.flags !== undefined ? args.flags : undefined);
    let model = initPair.a;
    const stepper = stepperBuilder(sendToApp, model);

    function sendToApp(msg, viewMetadata) {
        const pair = update(msg)(model);
        model = pair.a;
        stepper(model, viewMetadata);
        // pair.b is the Cmd bag; subscriptions(model) is the Sub bag — ignored here.
    }

    return {};
};

module.exports = { g };
