// Mock Fabric — an in-memory stand-in for React Native's Fabric host.
//
// It implements the exact JSI surface external/native.js drives (__fabric_*),
// building a real (in-memory) native view tree and recording every mutation so the
// harness can assert the §8 pass criteria:
//   • the rendered tree is made of real native views (RCTView/RCTText…), not a WebView
//   • a tap produces a SINGLE targeted updateProps on the label (no createView, no
//     re-mount of the subtree)
//
// On a device, these same calls cross JSI into C++ and become createView/updateView/
// insertChild on actual platform views (see host/shared/cpp/CanopyFabric.cpp). The
// shapes are identical; only the backing store differs.

'use strict';

function createMockFabric() {
    const views = new Map();        // handle -> { tag, props, children: [handles], parent }
    const log = [];                 // ordered mutation record
    // AND-8 call-path counters: how many prop mutations took the JSON updateProps path vs the
    // single-scalar fast path. bench.js asserts a pure-text-update loop drives scalarProps>0 and
    // jsonProps==0 (the marshalling tax was actually eliminated, not just relabelled).
    const counts = { jsonProps: 0, scalarProps: 0 };
    let nextHandle = 1;
    let rootHandle = null;
    let frameQueue = [];

    function view(h) { return views.get(h); }

    const fabric = {
        __fabric_createView(tag, props) {
            const h = nextHandle++;
            views.set(h, { handle: h, tag, props: Object.assign({}, props || {}), children: [], parent: null });
            log.push({ op: 'createView', handle: h, tag, props: Object.assign({}, props || {}) });
            return h;
        },

        __fabric_updateProps(handle, props) {
            const v = view(handle);
            if (!v) throw new Error('updateProps on unknown handle ' + handle);
            for (const k in props) {
                if (props[k] === undefined) delete v.props[k];
                else v.props[k] = props[k];
            }
            counts.jsonProps++;
            log.push({ op: 'updateProps', handle, tag: v.tag, props: Object.assign({}, props) });
        },

        // The AND-8 single-scalar fast path (text/value/opacity). On a device this skips the
        // JSON.stringify/parse + host-side JSONObject decode that __fabric_updateProps pays; here
        // it mutates the same backing store and records a targeted op. CRITICAL: it logs under
        // op:'updateProps' so run.js / run-lazy.js's "exactly ONE updateProps after tap" assertion
        // stays meaningful (one scalar mutation = one targeted prop update). `value` is always a
        // string at this boundary (numeric opacity is stringified in the walker); opacity nests
        // under props.style so findByTestID/style reads mirror the real applyStyle host behaviour.
        __fabric_updatePropScalar(handle, key, value) {
            const v = view(handle);
            if (!v) throw new Error('updatePropScalar on unknown handle ' + handle);
            if (key === 'opacity') {
                if (!v.props.style) v.props.style = {};
                v.props.style.opacity = value;
            } else {
                v.props[key] = value;
            }
            counts.scalarProps++;
            const props = {}; props[key] = value;
            log.push({ op: 'updateProps', handle, tag: v.tag, props, scalar: true });
        },

        __fabric_insertChild(parent, child, index) {
            const p = view(parent), c = view(child);
            if (!p || !c) throw new Error('insertChild with unknown handle');
            // detach from any current parent (insert can be used as a move)
            if (c.parent != null) {
                const old = view(c.parent);
                const at = old.children.indexOf(child);
                if (at >= 0) old.children.splice(at, 1);
            }
            const existing = p.children.indexOf(child);
            if (existing >= 0) p.children.splice(existing, 1);
            const i = index < 0 || index > p.children.length ? p.children.length : index;
            p.children.splice(i, 0, child);
            c.parent = parent;
            log.push({ op: 'insertChild', parent, child, index: i, tag: c.tag });
        },

        __fabric_removeChild(parent, child /*, index */) {
            const p = view(parent), c = view(child);
            if (!p) throw new Error('removeChild on unknown parent ' + parent);
            const at = p.children.indexOf(child);
            if (at >= 0) p.children.splice(at, 1);
            if (c) c.parent = null;
            log.push({ op: 'removeChild', parent, child, tag: c ? c.tag : '?' });
        },

        __fabric_setRoot(handle) {
            if (!views.has(handle)) {
                views.set(handle, { handle, tag: 'RCTRootView', props: {}, children: [], parent: null });
            }
            rootHandle = handle;
            log.push({ op: 'setRoot', handle });
        },

        __fabric_setEvents(handle, names) {
            const v = view(handle);
            if (v) v.events = names.slice();
            log.push({ op: 'setEvents', handle, names: names.slice() });
        },

        // The imperative-command seam (AND-3 / IOS-8). Mirrors the real host (CanopyHost.java's
        // command()): it runs the op and returns the result ASYNC via the SAME event path press
        // uses — __canopy_dispatchEvent(handle, "__commandResult", result). Like the real Android
        // echo, the result reflects {name, args} back. The async hop is modelled as a queued frame
        // so the harness flushes it deterministically (the device hops it via the JS-thread Looper).
        __fabric_command(handle, name, argsJson) {
            log.push({ op: 'command', handle, name, args: argsJson });
            frameQueue.push(() => {
                const dispatch = globalThis.__canopy_dispatchEvent;
                if (!dispatch) return;
                dispatch(handle, '__commandResult', { name, args: argsJson });
            });
        },

        // Coalesced vsync: native.js posts frames here; the harness flushes them
        // deterministically (modelling the UI thread waking on the next vsync).
        __fabric_requestFrame(cb) { frameQueue.push(cb); },
    };

    // ---- harness-side controls (not part of the JSI surface) ----------------

    const control = {
        fabric,
        get log() { return log; },
        get rootHandle() { return rootHandle; },
        // AND-8 call-path counters (see `counts` above). Live reference so callers see updates.
        get counts() { return counts; },
        resetCounts() { counts.jsonProps = 0; counts.scalarProps = 0; },

        // run pending vsync frames until quiescent (bounded to avoid runaway loops)
        flushFrames() {
            let guard = 0;
            while (frameQueue.length && guard++ < 1000) {
                const q = frameQueue; frameQueue = [];
                for (const cb of q) cb();
            }
        },

        clearLog() { log.length = 0; },

        // find the first view whose props.testID === id
        findByTestID(id) {
            for (const v of views.values()) if (v.props && v.props.testID === id) return v;
            return null;
        },

        // find every view of a given tag
        findByTag(tag) {
            const out = [];
            for (const v of views.values()) if (v.tag === tag) out.push(v);
            return out;
        },

        // simulate a native gesture: the host would call the JS dispatcher installed
        // by Native's installEventDispatcher; we call it the same way.
        emit(handle, eventName, payload) {
            const dispatch = globalThis.__canopy_dispatchEvent;
            if (!dispatch) throw new Error('event dispatcher not installed');
            dispatch(handle, eventName, payload || {});
        },

        // pretty-print the view tree (for the harness report)
        renderTree(handle, depth) {
            handle = handle == null ? rootHandle : handle;
            depth = depth || 0;
            const v = view(handle);
            if (!v) return '';
            const pad = '  '.repeat(depth);
            const text = v.props && v.props.text !== undefined ? ` "${v.props.text}"` : '';
            const tid = v.props && v.props.testID ? ` #${v.props.testID}` : '';
            let s = `${pad}${v.tag}${tid}${text}\n`;
            for (const ch of v.children) s += control.renderTree(ch, depth + 1);
            return s;
        },
    };

    return control;
}

module.exports = { createMockFabric };
