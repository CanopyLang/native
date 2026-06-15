// Canopy Native-Module FFI — the ONE place the __canopy_* native-call ABI is touched.
//
// Imported from Native.Module.can via:
//   foreign import javascript "external/native-module.js" as NM
//
// This is the effect-system counterpart to external/native.js (the render walker).
// native.js swaps the *render* seam (VirtualDom -> Fabric); THIS file swaps the
// *effect* seam: a Canopy Cmd/Sub that, on a browser, would reach a Web API
// (XMLHttpRequest, localStorage), instead reaches a JSI **host function** the C++
// host installs. The Canopy effect-manager pattern (Http/Storage) is UNCHANGED — only
// the source of the async callback differs (a JSI host completion vs. an XHR event).
//
// THE ABI (one generic dispatcher, never one global per method — see plan C1 §"Canonical
// native-module ABI"):
//   __canopy_call(module, method, argsJson, callId) -> 0 accepted / -1 not found   JS->host
//   __canopy_cancel(callId)                          -> void                         JS->host
//   __canopy_resolve(callId, errJson, resultJson)    -> void   (host CALLS this)     host->JS
//
// We SELF-INSTALL __canopy_resolve here at module load, exactly as native.js:729
// self-installs __canopy_dispatchEvent. The host never installs it; the host *calls*
// it on the JS thread (after a worker->JS-thread hop) to deliver a Cmd completion or a
// streamed Sub event, keyed by the ephemeral callId.
//
// Marshalling discipline (identical to __fabric_*): JSON strings + ints. Args go out as
// one argsJson string; results come back as one resultJson string and are decoded by the
// CALLER's Json.Decode.Decoder in JS. Bulk binary (decoded bitmaps, model tensors, picked
// bytes) NEVER crosses as JSON — it stays native and crosses as an opaque integer handle
// (a BlobRegistry token); see host/shared/cpp/CanopyBlobs.h. This file deals only in the
// JSON/int control plane.


// ============================================================================
// HOST BINDING — resolve the global scope the same way native.js does, so this file
// loads fine before the host installs the dispatcher (bundled-but-not-yet-booted).
// ============================================================================

function _NM_host() {
    var g = (typeof globalThis !== 'undefined') ? globalThis
          : (typeof global !== 'undefined') ? global
          : (typeof self !== 'undefined') ? self : this;
    return g;
}


// ============================================================================
// PENDING-CALL TABLE + the self-installed resolve global.
//
// Each call mints a process-unique callId. The host routes the completion/event/cancel
// back by that id. _NM_pending[callId] holds the one-shot { resolve, reject } or the
// streaming { resolve } sink. The host calls __canopy_resolve(callId, errJson, resultJson)
// on the JS thread; "" / null errJson means success.
// ============================================================================

var _NM_nextId = 1;
var _NM_pending = Object.create(null);   // callId -> { resolve, reject }

function _NM_install() {
    var host = _NM_host();
    if (host.__canopy_resolve) { return; }            // idempotent: install exactly once
    host.__canopy_resolve = function (callId, errJson, resultJson) {
        var p = _NM_pending[String(callId)];
        if (!p) { return; }                       // already cancelled / unknown / completed
        if (errJson != null && errJson !== '') {
            // Terminal error: drop the pending row and reject.
            delete _NM_pending[String(callId)];
            p.reject(_NM_parse(errJson));
        } else if (p.streaming) {
            // Streaming event: keep the row alive; deliver each event. A terminal marker
            // ({"$done":true}) tells the sink to tear down.
            p.resolve(resultJson == null ? '' : resultJson);
        } else {
            // One-shot success: drop the row and resolve.
            delete _NM_pending[String(callId)];
            p.resolve(resultJson == null ? '' : resultJson);
        }
    };
}
// NOTE: __canopy_resolve is self-installed LAZILY from call/callStreaming/cancel below,
// NOT from a bare top-level statement. The compiler's FFI inlining keeps only the
// declarations reachable from the bound foreign names, and drops bare top-level
// expression statements — so a top-level `_NM_install()` would never run. Installing
// from the bound entry points guarantees __canopy_resolve exists before any completion
// can arrive (the host only ever calls it in response to a call we initiated). This
// mirrors how native.js self-installs __canopy_dispatchEvent inside its `element` boot.

function _NM_parse(json) {
    if (json == null || json === '') { return null; }
    try { return JSON.parse(json); } catch (e) { return { code: 'rejected', message: String(json) }; }
}

// Build a Native.Module.Error custom-type value from a native { code, message } payload.
// Prod uses integer tags by declaration order (ModuleNotFound=0, Rejected=1, Decode=2,
// Cancelled=3); dev uses the constructor name. Mirrors http.js's __canopy_debug pattern.
function _NM_error(err) {
    if (!err) { return { $: _NM_dbg() ? 'Rejected' : 1, a: 'unknown' }; }
    if (err.code === 'cancelled') { return { $: _NM_dbg() ? 'Cancelled' : 3 }; }
    if (err.code === 'module_not_found') { return { $: _NM_dbg() ? 'ModuleNotFound' : 0, a: (err.message || '') }; }
    return { $: _NM_dbg() ? 'Rejected' : 1, a: (err.code || '') + ':' + (err.message || '') };
}
function _NM_moduleNotFound(moduleName) { return { $: _NM_dbg() ? 'ModuleNotFound' : 0, a: moduleName }; }
function _NM_decodeError(detail) { return { $: _NM_dbg() ? 'Decode' : 2, a: detail }; }

function _NM_dbg() {
    return (typeof __canopy_debug !== 'undefined') && __canopy_debug;
}


// ============================================================================
// call — the one-shot async Cmd path. Marshals args, invokes __canopy_call, resolves
// the Task with the decoded result (or fails). Returns a kill fn -> __canopy_cancel.
// Modeled byte-for-byte on storage.js / http.js's _Scheduler_binding shape.
// ============================================================================

/**
 * One-shot native-module call as a Task. The host runs the work (often on a worker
 * thread) and hops the completion back onto the JS thread via __canopy_resolve.
 * @canopy-type a -> b -> c -> d -> e
 * @name call
 */
var call = F4(function (moduleName, method, argsJson, decoder) {
    _NM_install();
    return _Scheduler_binding(function (callback) {
        var callId = String(_NM_nextId++);
        _NM_pending[callId] = {
            streaming: false,
            resolve: function (resultJson) {
                var parsed;
                try { parsed = JSON.parse(resultJson === '' ? 'null' : resultJson); }
                catch (e) { callback(_Scheduler_fail(_NM_decodeError('result was not JSON'))); return; }
                var res = _Json_runHelp(decoder, parsed);   // plain 2-arg kernel fn (see native.js)
                if (_Result_isOk(res)) { callback(_Scheduler_succeed(res.a)); }
                else { callback(_Scheduler_fail(_NM_decodeError('result did not match decoder'))); }
            },
            reject: function (err) { callback(_Scheduler_fail(_NM_error(err))); }
        };
        // __canopy_call returns synchronously: 0 accepted, -1 (module, method) not found.
        var host = _NM_host();
        var rc = host.__canopy_call
            ? host.__canopy_call(moduleName, method, argsJson, callId)
            : -1;
        if (rc === -1) {
            delete _NM_pending[callId];
            callback(_Scheduler_fail(_NM_moduleNotFound(moduleName)));
            return;
        }
        // kill fn: drop the pending row and tell the host to cancel the in-flight job.
        return function () {
            if (_NM_pending[callId]) { delete _NM_pending[callId]; }
            if (host.__canopy_cancel) { host.__canopy_cancel(callId); }
        };
    });
});


// ============================================================================
// callStreaming — the Sub / progress path. Spawns a long-lived listener keyed by callId;
// each native emit -> the manager's sendToSelf task. Returns the Process.Id so the
// manager can Process.kill it. Mirrors http.js's _Http_track + storage.js's `on`.
// ============================================================================

/**
 * Streaming native-module subscription. `toSelf` maps each decoded event value to a
 * Task (the manager's Platform.sendToSelf). Each native emit re-spawns that task.
 * @canopy-type a -> b -> c -> d -> e
 * @name callStreaming
 */
var callStreaming = F4(function (moduleName, method, argsJson, toSelf) {
    _NM_install();
    return _Scheduler_spawn(_Scheduler_binding(function (callback) {
        var callId = String(_NM_nextId++);
        _NM_pending[callId] = {
            streaming: true,
            resolve: function (eventJson) {
                var parsed;
                try { parsed = JSON.parse(eventJson === '' ? 'null' : eventJson); }
                catch (e) { return; }
                // A terminal marker tears the listener down.
                if (parsed && parsed.$done) { delete _NM_pending[callId]; return; }
                _Scheduler_rawSpawn(toSelf(parsed));
            },
            reject: function () { delete _NM_pending[callId]; }
        };
        var host = _NM_host();
        if (host.__canopy_call) { host.__canopy_call(moduleName, method, argsJson, callId); }
        callback(_Scheduler_succeed(callId));
        return function () {
            if (_NM_pending[callId]) { delete _NM_pending[callId]; }
            if (host.__canopy_cancel) { host.__canopy_cancel(callId); }
        };
    }));
});


// ============================================================================
// cancel — explicit cancellation by callId (the kill fn already calls __canopy_cancel;
// this is the public Task form for capability packages that track ids themselves).
// ============================================================================

/**
 * Cancel an in-flight call by its callId. Best-effort: a job that already completed
 * still resolves and the JS side drops it (see __canopy_resolve's `if (!p) return`).
 * @canopy-type a -> b
 * @name cancel
 */
var cancel = function (callId) {
    _NM_install();
    return _Scheduler_binding(function (callback) {
        var host = _NM_host();
        if (_NM_pending[String(callId)]) { delete _NM_pending[String(callId)]; }
        if (host.__canopy_cancel) { host.__canopy_cancel(String(callId)); }
        callback(_Scheduler_succeed(_Utils_Tuple0));
        return function () {};
    });
};


// ============================================================================
// COMMONJS EXPORT — only for the Node test harness (harness/mock-native-modules.js).
// On Hermes/browser `module` is undefined, so this is skipped and the file behaves as
// an ordinary inlined FFI module (same guard as native.js:926).
// ============================================================================

if (typeof module !== 'undefined' && module.exports) {
    module.exports = {
        call: call,
        callStreaming: callStreaming,
        cancel: cancel,
        _NM_install: _NM_install,
        _NM_pending: _NM_pending
    };
}
