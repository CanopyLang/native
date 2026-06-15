// Mock native-module host — an in-memory stand-in for the C++ ModuleRegistry +
// worker-thread dispatcher that backs external/native-module.js's __canopy_* ABI.
//
// It implements the exact JSI surface native-module.js drives:
//   __canopy_call(module, method, argsJson, callId) -> 0 accepted / -1 not found
//   __canopy_cancel(callId)                          -> void
// and models the ONE thing that makes the ABI non-trivial: the worker-thread → JS-thread
// hop. A real module runs work off the JS thread and, when done, calls ctx.complete()
// from that worker; the C++ ModuleRegistry marshals the completion back onto the JS
// thread (postToJs) before invoking globalThis.__canopy_resolve. We model that hop with
// an explicit `jsQueue` the harness drains via flushJs() — so a test can observe the
// genuinely-async gap (the Cmd is "pending" until the hop runs), exactly as on a device.
//
// On hardware these same calls cross JSI into host/shared/cpp/CanopyModules.cpp; the
// registered NativeModule does the real work (ORT/Core ML/StoreKit/…) and ctx.complete
// becomes canopyResolveCall over postToJs. The shapes are identical; only the backend
// and the thread are real.

'use strict';

function createMockNativeModules() {
    const modules = Object.create(null);   // name -> { method: (argsValue, ctx) => void }
    const inflight = new Map();             // callId -> { cancelled }
    const jsQueue = [];                     // deferred completions (the worker -> JS hop)
    let log = [];

    // Register a mock native module. `methods[method](argsValue, ctx)` runs the call;
    // ctx.complete(errJson, resultJson) is the thread-safe sink (errJson "" = success;
    // call it repeatedly for a stream, with a final {"$done":true} marker).
    function registerModule(name, methods) { modules[name] = methods; }

    const abi = {
        __canopy_call(moduleName, method, argsJson, callId) {
            const id = String(callId);
            log.push({ op: 'call', module: moduleName, method, argsJson, callId: id });
            const mod = modules[moduleName];
            if (!mod || typeof mod[method] !== 'function') { return -1; } // (module,method) not found
            const rec = { cancelled: false };
            inflight.set(id, rec);
            const ctx = {
                module: moduleName, method, callId: id,
                argsValue: safeParse(argsJson),
                // Thread-safe completion sink. Models the worker thread calling complete();
                // we hop onto the "JS thread" by deferring into jsQueue (drained by flushJs).
                complete(errJson, resultJson) {
                    jsQueue.push(() => {
                        if (rec.cancelled) { return; }          // cancel race: drop silently
                        const resolve = globalThis.__canopy_resolve;
                        if (resolve) { resolve(id, errJson || '', resultJson == null ? '' : resultJson); }
                    });
                }
            };
            try {
                mod[method](ctx.argsValue, ctx);
            } catch (e) {
                ctx.complete(JSON.stringify({ code: 'rejected', message: String((e && e.message) || e) }), '');
            }
            return 0;
        },

        __canopy_cancel(callId) {
            const id = String(callId);
            log.push({ op: 'cancel', callId: id });
            const rec = inflight.get(id);
            if (rec) { rec.cancelled = true; }
        }
    };

    const control = {
        abi,
        registerModule,
        get log() { return log; },
        clearLog() { log = []; },
        // how many worker completions are waiting to hop onto the JS thread
        get pendingJs() { return jsQueue.length; },
        // drain the worker -> JS-thread hop (run all queued completions)
        flushJs() {
            const q = jsQueue.splice(0, jsQueue.length);
            for (const fn of q) { fn(); }
        }
    };
    return control;
}

function safeParse(json) {
    if (json == null || json === '') { return null; }
    try { return JSON.parse(json); } catch (e) { return json; }
}

module.exports = { createMockNativeModules };
