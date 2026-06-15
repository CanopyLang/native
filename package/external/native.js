// Canopy Native FFI — the THIRD walker.
//
// Imported from Native.can via:
//   foreign import javascript "external/native.js" as NativeFFI
//
// Canopy already renders the *same* VirtualDom node data three ways:
//   • virtual-dom.js  → real DOM nodes (browser patcher)
//   • ssr.js          → HTML strings (server walker)
//   • THIS FILE       → React-Native Fabric mutations (native walker)
//
// The conceptual leap (see docs/architecture.md §"the third walker"): this is
// "ssr.js, but instead of emitting strings it emits Fabric create/update/insert/
// remove calls over JSI". It keeps a parallel `nNode` tree — exactly analogous to
// virtual-dom.js's `tNode` tree — where each node stores a Fabric *view handle*
// (`__handle`) instead of a DOM node (`__domNode`).
//
// HARD CONSTRAINT (the elm-native-ui survival rule, docs/architecture.md §3):
// this file binds ONLY to (a) Canopy's *public* VirtualDom node data shape and
// (b) a small, host-provided JSI surface (`__fabric_*`). It touches no compiler
// kernel internals and no React-Native private headers.
//
// HOST SURFACE (installed as globals on the Hermes runtime by the RN host, or by
// the Node test harness in harness/mock-fabric.js):
//   __fabric_createView(tag, props)        -> handle      create a native view
//   __fabric_updateProps(handle, props)    -> void        patch props on a view
//   __fabric_insertChild(parent, child, i) -> void        mount child at index i
//   __fabric_removeChild(parent, child, i) -> void        unmount child at index i
//   __fabric_setRoot(handle)               -> void        attach subtree to surface
//   __fabric_requestFrame(cb)              -> void   (opt) schedule cb on next vsync
//   __fabric_setEvents(handle, eventNames) -> void   (opt) tell host which native
//                                                          events to emit for a view
// The host calls back into JS on a native event via the dispatcher returned by
// Native.__eventDispatcher() (wired by the host once at boot).
//
// All of `core/runtime.js` (the TEA loop + Cmd/Sub scheduler) runs UNCHANGED on
// Hermes; the only host global it needs is setTimeout (in _Process_sleep), trivially
// shimmed. This file does not duplicate any of that — it only swaps the render seam.


// ============================================================================
// VNODE TAGS  (identical to ssr.js / virtual-dom.js — the renderer-agnostic data)
// ============================================================================

var __2_TEXT = 0, __2_NODE = 1, __2_KEYED_NODE = 2;
var __2_CUSTOM = 3, __2_TAGGER = 4, __2_THUNK = 5, __2_BLOCK = 6;

// Native events the host delegates (mirrors virtual-dom.js's DELEGATABLE list, but
// for the RN gesture/text surface). Everything here is a plain prop flag the host
// reads; the walker never assumes a DOM event model.
var _Native_KNOWN_EVENTS = {
    'press': true, 'longPress': true, 'pressIn': true, 'pressOut': true,
    'change': true, 'changeText': true, 'submitEditing': true,
    'focus': true, 'blur': true, 'scroll': true, 'layout': true
};


// ============================================================================
// HOST BINDING — resolve the __fabric_* surface lazily so this file loads fine
// even before the host installs it (e.g. when bundled but not yet booted).
// ============================================================================

function _Native_host() {
    // `scope` is the same global the runtime exports `Elm` onto. On Hermes the host
    // installs __fabric_* there; in Node the harness sets them on globalThis.
    var g = (typeof globalThis !== 'undefined') ? globalThis
          : (typeof global !== 'undefined') ? global
          : (typeof self !== 'undefined') ? self : this;
    return g;
}

function _Native_createView(tag, props) {
    return _Native_host().__fabric_createView(tag, props);
}
function _Native_updateProps(handle, props) {
    return _Native_host().__fabric_updateProps(handle, props);
}
// AND-8 single-scalar fast path: a single string-valued key (text/value/opacity) crosses the JSI
// seam as (handle, key, value) — NO object allocation here, NO JSON.stringify/parse + host-side
// JSONObject decode. `value` MUST be a string (callers stringify a numeric opacity). A host that
// predates the seam simply lacks __fabric_updatePropScalar, so we feature-detect and fall back to
// the JSON updateProps path — mirroring the __fabric_setEvents guard above, so an old host still
// renders correctly (just without the marshalling win).
function _Native_updatePropScalar(handle, key, value) {
    var h = _Native_host();
    if (h.__fabric_updatePropScalar) { h.__fabric_updatePropScalar(handle, key, value); }
    else { var p = {}; p[key] = value; _Native_updateProps(handle, p); }
}
function _Native_insertChild(parent, child, index) {
    return _Native_host().__fabric_insertChild(parent, child, index);
}
function _Native_removeChild(parent, child, index) {
    return _Native_host().__fabric_removeChild(parent, child, index);
}
function _Native_setRoot(handle) {
    return _Native_host().__fabric_setRoot(handle);
}
function _Native_setEvents(handle, names) {
    var h = _Native_host();
    if (h.__fabric_setEvents) { h.__fabric_setEvents(handle, names); }
}

// Imperative command seam (AND-3 / the iOS __fabric_callMethod reconciled to ONE seam).
// For ops a declarative prop cannot express — focus/blur an input, measure a frame, scroll
// to an offset — the walker calls __fabric_command(handle, name, argsJson). The op runs ASYNC
// on the host; its result comes back through the SAME event path a gesture uses: the host emits
// (handle, "__commandResult", result) into __canopy_dispatchEvent, which routes to the registered
// callback. The host global is optional (a host that predates the seam simply lacks
// __fabric_command), so guard like setEvents does.
//
// AND-4 callId routing: a single handle can have MULTIPLE imperative ops in flight at once (e.g.
// a `measure` is genuinely async — the host defers it to post()/onLayout — and the app can fire a
// second `measure` before the first lands). A per-handle "__commandResult" callback would let the
// second clobber the first's. So each command carries a monotonic `__callId` (spliced into args);
// the host echoes it back in the result, and the dispatcher routes the result to the per-callId
// one-shot callback. Backward-compat with AND-3's echo host/mock (which does NOT understand
// __callId): we ALSO keep the per-handle "__commandResult" callback as a fallback for a result
// that arrives without a recognised __callId, so a pre-AND-4 host still round-trips.
var _Native_nextCallId = 1;
var _Native_pendingCommands = Object.create(null); // callId -> one-shot onResult callback

function _Native_command(handle, name, args, onResult) {
    var h = _Native_host();
    var callId = _Native_nextCallId++;
    if (typeof onResult === 'function') {
        _Native_pendingCommands[callId] = onResult;
        // Fallback for an AND-3 echo host that does not thread __callId back: route a __callId-less
        // result through the per-handle one-shot, exactly as AND-3 did. Wrap it so that, whichever
        // path delivers, the per-callId pending entry is purged — so a pre-AND-4 host (whose results
        // never carry a top-level __callId, so _Native_dispatchCommandResult never clears them) does
        // not leak entries into _Native_pendingCommands.
        var byHandle = _Native_eventRegistry[handle]
            || (_Native_eventRegistry[handle] = Object.create(null));
        byHandle['__commandResult'] = function (result) {
            delete _Native_pendingCommands[callId];
            onResult(result);
        };
    }
    // Splice __callId into the outgoing args so the host can echo it on the async result. We copy
    // the caller's args (never mutate their object) and stamp __callId; an absent/object arg starts
    // from {}.
    var outArgs = {};
    if (args != null && typeof args === 'object') {
        for (var k in args) { outArgs[k] = args[k]; }
    }
    outArgs.__callId = callId;
    if (h.__fabric_command) { h.__fabric_command(handle, name, outArgs); }
}

// The host emits (handle, "__commandResult", result) where result carries the echoed __callId.
// Route it to the matching per-callId one-shot (deleting it so a handle can be reused without a
// stale fan-out), falling back to the per-handle "__commandResult" callback when no __callId is
// recognised (an AND-3 echo host). Returns true when it consumed the result, so the generic event
// dispatcher can skip the per-handle path it already drove. Reachable only via _Native_dispatchEvent.
function _Native_dispatchCommandResult(handle, payload) {
    var p = (payload == null) ? {} : payload;
    var callId = p.__callId;
    if (callId != null && _Native_pendingCommands[callId]) {
        var cb = _Native_pendingCommands[callId];
        delete _Native_pendingCommands[callId];
        cb(p);
        return true;
    }
    return false; // no recognised __callId — let the generic per-handle dispatch handle it
}


// ============================================================================
// EVENT DISPATCH — the host calls this when a native gesture/text event fires.
//
// Each rendered view that carries handlers registers its callbacks in
// `_Native_eventRegistry[handle][eventName]`. The host emits
// (handle, eventName, payloadJson) and we decode → route to sendToApp, mirroring
// virtual-dom.js's `_VirtualDom_makeCallback`.
// ============================================================================

var _Native_eventRegistry = Object.create(null);
var _Native_nextHandleId = 0; // only used by the harness fallback; real host owns ids

function _Native_dispatchEvent(handle, eventName, payload) {
    // AND-4: an imperative-command result routes by its echoed __callId first, so concurrent ops on
    // ONE handle each reach their own one-shot callback. Only on no recognised __callId do we fall
    // through to the generic per-handle path (an AND-3 echo host that doesn't thread __callId back).
    if (eventName === '__commandResult' && _Native_dispatchCommandResult(handle, payload)) { return; }
    var byHandle = _Native_eventRegistry[handle];
    if (!byHandle) { return; }
    var callback = byHandle[eventName];
    if (!callback) { return; }
    callback(payload == null ? {} : payload);
}

// Mirror of _VirtualDom_makeCallback: decode the event payload with the handler's
// JSON decoder, extract the message per handler tag, route to the app.
function _Native_makeCallback(eventNode, handler) {
    function callback(payload) {
        var result = _Json_runHelp(callback.__handler.a, payload);
        if (!_Native_isOk(result)) { return; }

        var tag = _Native_toHandlerInt(callback.__handler);
        var value = result.a;
        // 0 = Normal, 1 = MayStopPropagation, 2 = MayPreventDefault, 3 = Custom
        var message = !tag ? value : tag < 3 ? value.a : value.message;
        var stopPropagation = tag == 1 ? value.b : tag == 3 && value.stopPropagation;
        callback.__eventNode(message, stopPropagation);
    }
    callback.__handler = handler;
    callback.__eventNode = eventNode;
    return callback;
}

function _Native_isOk(result) {
    // Result Ok is { $: 'Ok' | 0, a: value }; Err is { $: 'Err' | 1, ... }
    return result.$ === 0 || result.$ === 'Ok';
}

function _Native_toHandlerInt(handler) {
    switch (handler.$) {
        case 'Normal': return 0;
        case 'MayStopPropagation': return 1;
        case 'MayPreventDefault': return 2;
        case 'Custom': return 3;
        default: return handler.$; // prod mode: already an int 0..3
    }
}


// ============================================================================
// FACTS → FABRIC PROPS
//
// Reuses the SAME organized-facts object virtual-dom.js / ssr.js read:
//   facts.a__1_STYLE  → { cssKey: value }      flatten into the props.style object
//   facts.a__1_ATTR   → { key: value }         passed through as props
//   facts.a__1_EVENT  → { eventName: Handler } registered + announced to host
//   facts.<plainKey>  → value                  direct props (e.g. text, value)
//
// Yoga (RN's layout engine) consumes flexbox style keys directly, so Canopy style
// facts line up 1:1 — we do not implement layout.
// ============================================================================

function _Native_factsToProps(facts, handle, eventNode) {
    var props = {};

    var styles = facts['a__1_STYLE'];
    if (styles) {
        var style = {};
        for (var sk in styles) { style[sk] = styles[sk]; }
        props.style = style;
    }

    var attrs = facts['a__1_ATTR'];
    if (attrs) {
        for (var ak in attrs) {
            if (attrs[ak] !== undefined) { props[ak] = attrs[ak]; }
        }
    }

    // Plain props (everything that is not a fact bucket): text, value, etc.
    for (var key in facts) {
        switch (key) {
            case 'a__1_STYLE': case 'a__1_EVENT':
            case 'a__1_ATTR': case 'a__1_ATTR_NS': continue;
        }
        props[key] = facts[key];
    }

    // Events: register callbacks for this handle and tell the host which native
    // events to surface. The event names themselves go out as a `__events` prop so
    // a host that doesn't implement __fabric_setEvents still learns about them.
    var events = facts['a__1_EVENT'];
    if (events && handle != null) {
        var names = [];
        var byHandle = _Native_eventRegistry[handle] || (_Native_eventRegistry[handle] = Object.create(null));
        for (var ev in events) {
            byHandle[ev] = _Native_makeCallback(eventNode, events[ev]);
            if (_Native_KNOWN_EVENTS[ev] || true) { names.push(ev); }
        }
        if (names.length) {
            props.__events = names;
            _Native_setEvents(handle, names);
        }
    }

    return props;
}


// ============================================================================
// RENDER  (mirror of _VirtualDom_render) — vnode → Fabric views + parallel nNode.
//
// nNode shape (analogous to virtual-dom.js tNode { __domNode, __kids }):
//   { __handle, __kids: [nNode], __text?, __tagger?, __eventNode? }
// ============================================================================

function _Native_render(vNode, eventNode) {
    switch (vNode.$) {
        case __2_THUNK:
            return _Native_render(_Native_forceThunk(vNode), eventNode);

        case __2_BLOCK:
            return _Native_render(_Native_forceThunk(vNode), eventNode);

        case __2_TAGGER:
            return _Native_renderTagger(vNode, eventNode);

        case __2_TEXT:
            // A bare text node becomes a RawText leaf carrying { text }. In practice
            // most text arrives as the single child of a Text node and is hoisted
            // into a `text` prop below (the textContent fast-path).
            var th = _Native_createView('RCTRawText', { text: vNode.__text });
            return { __handle: th, __kids: [], __text: vNode.__text };

        case __2_NODE:
            return _Native_renderElement(vNode, eventNode);

        case __2_KEYED_NODE:
            return _Native_renderKeyed(vNode, eventNode);

        case __2_CUSTOM:
            // Custom (host-component) nodes are out of scope for the wedge; render an
            // empty view so the tree stays well-formed.
            return { __handle: _Native_createView('RCTView', {}), __kids: [] };

        default:
            return { __handle: _Native_createView('RCTView', {}), __kids: [] };
    }
}

function _Native_renderTagger(vNode, eventNode) {
    var subNode = _Native_wrapEventNode(vNode.__tagger, eventNode);
    var nNode = _Native_render(vNode.__node, subNode);
    nNode.__tagger = vNode.__tagger;
    nNode.__eventNode = subNode;
    return nNode;
}

// Compose a tagger over the current eventNode so child messages get mapped, exactly
// like the browser walker's wrapEventNode. eventNode is (msg, isSync) => void.
function _Native_wrapEventNode(tagger, eventNode) {
    return function(msg, isSync) {
        eventNode(_Native_applyTagger(tagger, msg), isSync);
    };
}
function _Native_applyTagger(tagger, msg) {
    // tagger may be a single function or an array of functions (composed maps).
    if (typeof tagger === 'function') { return tagger(msg); }
    for (var i = tagger.length - 1; i >= 0; i--) { msg = tagger[i](msg); }
    return msg;
}

function _Native_renderElement(vNode, eventNode) {
    var kids = vNode.__kids;

    // textContent fast-path (mirror of virtual-dom.js): a node whose only child is
    // text carries the string as a `text` prop instead of a child view. This is what
    // makes a label update a single targeted updateProps — never a re-mount.
    if (kids.length === 1 && kids[0].$ === __2_TEXT) {
        var props = _Native_factsToPropsDeferred(vNode.__facts, eventNode);
        props.text = kids[0].__text;
        var handle = _Native_createView(vNode.__tag, props.__plain);
        _Native_finishProps(handle, props, eventNode, vNode.__facts);
        return { __handle: handle, __kids: [], __text: kids[0].__text };
    }

    // Create the view first (so we have a handle to register events against), then
    // apply facts, then render + insert children.
    var handle = _Native_createView(vNode.__tag, {});
    var props = _Native_factsToProps(vNode.__facts, handle, eventNode);
    _Native_updateProps(handle, props);

    var nKids = new Array(kids.length);
    for (var i = 0; i < kids.length; i++) {
        var kidN = _Native_render(kids[i], eventNode);
        nKids[i] = kidN;
        _Native_insertChild(handle, kidN.__handle, i);
    }
    return { __handle: handle, __kids: nKids };
}

// Two-phase prop application so a known handle exists before events are registered
// for the textContent fast-path. Returns { __plain } (create-time props) and stashes
// the rest for _Native_finishProps.
function _Native_factsToPropsDeferred(facts, eventNode) {
    var plain = {};
    var styles = facts['a__1_STYLE'];
    if (styles) {
        var style = {};
        for (var sk in styles) { style[sk] = styles[sk]; }
        plain.style = style;
    }
    var attrs = facts['a__1_ATTR'];
    if (attrs) { for (var ak in attrs) { if (attrs[ak] !== undefined) plain[ak] = attrs[ak]; } }
    for (var key in facts) {
        switch (key) {
            case 'a__1_STYLE': case 'a__1_EVENT':
            case 'a__1_ATTR': case 'a__1_ATTR_NS': continue;
        }
        plain[key] = facts[key];
    }
    return { __plain: plain };
}

function _Native_finishProps(handle, deferred, eventNode, facts) {
    var update = { text: deferred.text };
    var events = facts['a__1_EVENT'];
    if (events) {
        var names = [];
        var byHandle = _Native_eventRegistry[handle] || (_Native_eventRegistry[handle] = Object.create(null));
        for (var ev in events) {
            byHandle[ev] = _Native_makeCallback(eventNode, events[ev]);
            names.push(ev);
        }
        if (names.length) { update.__events = names; _Native_setEvents(handle, names); }
    }
    _Native_updateProps(handle, update);
}

function _Native_renderKeyed(vNode, eventNode) {
    var kids = vNode.__kids;
    var handle = _Native_createView(vNode.__tag, {});
    var props = _Native_factsToProps(vNode.__facts, handle, eventNode);
    _Native_updateProps(handle, props);

    var nKids = new Array(kids.length);
    for (var i = 0; i < kids.length; i++) {
        var kidN = _Native_render(kids[i].b, eventNode); // keyed kids are { a:key, b:node }
        kidN.__key = kids[i].a;
        nKids[i] = kidN;
        _Native_insertChild(handle, kidN.__handle, i);
    }
    return { __handle: handle, __kids: nKids };
}

function _Native_forceThunk(vNode) {
    if (vNode.__node === undefined || vNode.__node === null) {
        var refs = vNode.__refs;
        var func = refs[0];
        // refs[1..] are the args; apply curried (mirror of _VirtualDom_forceThunk).
        var node = func;
        for (var i = 1; i < refs.length; i++) { node = node(refs[i]); }
        vNode.__node = node;
    }
    return vNode.__node;
}


// ============================================================================
// UPDATE  (mirror of _VirtualDom_updateTNode) — diff old/new vnode, mutate nNode in
// place, emit the minimal Fabric mutations. No patch objects, just like the source.
// ============================================================================

function _Native_updateTNode(nNode, x, y, eventNode) {
    if (x === y) { return nNode; } // reference-equality short-circuit (lazy/const reuse)

    var xType = x.$;
    var yType = y.$;

    // lazy/block memoization: if x and y are the SAME kind of thunk/block and every ref is
    // identical, the subtree is unchanged — reuse the already-built node and skip re-forcing +
    // re-diffing it entirely. This is the missing half of `lazy` (without it, a fresh thunk
    // object every render means lazy never short-circuits and re-diffs the whole subtree each
    // frame). Mirror of _VirtualDom_updateTNode's __2_THUNK/__2_BLOCK case (virtual-dom.js:2216).
    if ((xType === __2_THUNK || xType === __2_BLOCK) && xType === yType) {
        var xRefs = x.__refs, yRefs = y.__refs;
        var i = xRefs.length;
        var same = i === yRefs.length;
        while (same && i--) { same = xRefs[i] === yRefs[i]; }
        if (same) { y.__node = x.__node; return nNode; }
    }

    // Unwrap thunks/blocks/taggers to their underlying nodes for comparison.
    if (xType === __2_THUNK || xType === __2_BLOCK) { x = _Native_forceThunk(x); xType = x.$; }
    if (yType === __2_THUNK || yType === __2_BLOCK) { y = _Native_forceThunk(y); yType = y.$; }
    if (xType === __2_TAGGER && yType === __2_TAGGER) {
        return _Native_updateTNode(nNode, x.__node, y.__node, nNode.__eventNode || eventNode);
    }

    if (xType !== yType) {
        if (xType === __2_NODE && yType === __2_KEYED_NODE) {
            y = _Native_dekey(y); yType = __2_NODE;
        } else {
            return _Native_redraw(nNode, y, eventNode);
        }
    }

    switch (yType) {
        case __2_TEXT:
            if (x.__text !== y.__text) {
                // text is a single scalar prop → the AND-8 fast path (no object/JSON marshalling).
                _Native_updatePropScalar(nNode.__handle, 'text', y.__text);
                nNode.__text = y.__text;
            }
            return nNode;

        case __2_NODE: {
            if (x.__tag !== y.__tag || x.__namespace !== y.__namespace) {
                return _Native_redraw(nNode, y, eventNode);
            }
            // textContent fast-path on both sides → just diff the text prop.
            var xText = _Native_loneText(x);
            var yText = _Native_loneText(y);
            if (xText !== null || yText !== null) {
                if (x.__facts !== y.__facts) { _Native_diffApplyFacts(nNode, x.__facts, y.__facts, eventNode); }
                if (xText !== yText) {
                    // lone-text node: the visible text is a single scalar → AND-8 fast path.
                    _Native_updatePropScalar(nNode.__handle, 'text', yText);
                    nNode.__text = yText;
                }
                return nNode;
            }
            if (x.__facts !== y.__facts) { _Native_diffApplyFacts(nNode, x.__facts, y.__facts, eventNode); }
            _Native_updateKids(nNode, x.__kids, y.__kids, eventNode);
            return nNode;
        }

        case __2_KEYED_NODE: {
            if (x.__tag !== y.__tag || x.__namespace !== y.__namespace) {
                return _Native_redraw(nNode, y, eventNode);
            }
            if (x.__facts !== y.__facts) { _Native_diffApplyFacts(nNode, x.__facts, y.__facts, eventNode); }
            _Native_updateKeyedKids(nNode, x.__kids, y.__kids, eventNode);
            return nNode;
        }

        default:
            return _Native_redraw(nNode, y, eventNode);
    }
}

// A NODE whose sole child is text → its string, else null. Lets the diff treat such
// nodes as leaves carrying a `text` prop (matches the render fast-path).
function _Native_loneText(vNode) {
    var kids = vNode.__kids;
    return (kids.length === 1 && kids[0].$ === __2_TEXT) ? kids[0].__text : null;
}

function _Native_redraw(nNode, y, eventNode) {
    // Replace the subtree: build the new view and swap it under the same parent slot.
    // The caller (updateKids) handles re-parenting; here we just produce a fresh nNode
    // and copy the new handle into the old nNode so parent references stay valid.
    var fresh = _Native_render(y, eventNode);
    _Native_releaseEvents(nNode);
    nNode.__handle = fresh.__handle;
    nNode.__kids = fresh.__kids;
    nNode.__text = fresh.__text;
    nNode.__replaced = true; // signal to the parent that the handle changed
    return nNode;
}

function _Native_releaseEvents(nNode) {
    if (nNode.__handle != null && _Native_eventRegistry[nNode.__handle]) {
        delete _Native_eventRegistry[nNode.__handle];
    }
}

function _Native_dekey(keyedVNode) {
    var kids = keyedVNode.__kids;
    var plain = new Array(kids.length);
    for (var i = 0; i < kids.length; i++) { plain[i] = kids[i].b; }
    return { $: __2_NODE, __tag: keyedVNode.__tag, __facts: keyedVNode.__facts,
             __kids: plain, __namespace: keyedVNode.__namespace };
}


// ============================================================================
// FACTS DIFF  (mirror of _VirtualDom_diffFacts) — compute the changed-only delta and
// apply it as one updateProps, re-registering any changed event handlers.
// ============================================================================

function _Native_diffApplyFacts(nNode, xFacts, yFacts, eventNode) {
    var delta = {};
    var changed = false;

    // styles
    var styleDelta = _Native_diffSub(xFacts['a__1_STYLE'], yFacts['a__1_STYLE']);
    if (styleDelta) { delta.style = styleDelta; changed = true; }

    // attrs (flat passthrough props)
    var attrDelta = _Native_diffSub(xFacts['a__1_ATTR'], yFacts['a__1_ATTR']);
    if (attrDelta) { for (var ak in attrDelta) { delta[ak] = attrDelta[ak]; } changed = true; }

    // plain props — a removed plain prop (text/bitmapHandle/before|afterHandle/wipeFraction)
    // must be sent as null (undefined is dropped by JSON.stringify at the JSI boundary) so the
    // host can reset it on a reused leaf instead of keeping the stale value.
    var xPlain = _Native_plain(xFacts), yPlain = _Native_plain(yFacts);
    for (var k in yPlain) { if (xPlain[k] !== yPlain[k]) { delta[k] = yPlain[k]; changed = true; } }
    for (var k2 in xPlain) { if (!(k2 in yPlain)) { delta[k2] = null; changed = true; } }

    // events: re-register changed handlers, announce the new set if it changed
    var evDelta = _Native_diffEvents(nNode.__handle, xFacts['a__1_EVENT'], yFacts['a__1_EVENT'], eventNode);
    if (evDelta) { delta.__events = evDelta; changed = true; }

    if (!changed) { return; }

    // AND-8 single-scalar fast path. When the WHOLE frame's delta is exactly one non-null scalar
    // mutation, send it via __fabric_updatePropScalar (no object/JSON marshalling). Two shapes
    // qualify; anything else (multi-key delta, any null/removal, attrs, events, or a style change
    // touching more than opacity) keeps the JSON updateProps path — whose reset/null semantics this
    // fast path deliberately does NOT replicate.
    var scalar = _Native_soleScalarDelta(delta, styleDelta);
    if (scalar) {
        _Native_updatePropScalar(nNode.__handle, scalar.key, scalar.value);
        return;
    }

    _Native_updateProps(nNode.__handle, delta);
}

// If `delta` represents exactly one non-null scalar mutation eligible for the fast path, return
// { key, value } (value coerced to a string); else null. Two eligible shapes:
//   • a lone plain prop in {text, value} whose value is a non-null string/number, and no style/
//     attr/event change rode along (delta has that ONE key only);
//   • a style delta whose ONLY changed key is `opacity` with a non-null scalar value, and no plain/
//     attr/event change rode along (delta has only `style`). opacity is nested under style, applied
//     by the host's applyStyle, so it can only be detected here — never as a plain prop.
// Numbers (a numeric opacity) are stringified so the value crosses the seam as a plain string,
// matching the host's optString/parseFloat coercion.
function _Native_soleScalarDelta(delta, styleDelta) {
    var keys = Object.keys(delta);
    if (keys.length !== 1) { return null; }
    var only = keys[0];

    if (only === 'text' || only === 'value') {
        var v = delta[only];
        if (v == null) { return null; }                 // a removal stays on the JSON path
        var t = typeof v;
        if (t !== 'string' && t !== 'number') { return null; }
        return { key: only, value: String(v) };
    }

    if (only === 'style' && styleDelta) {
        var sKeys = Object.keys(styleDelta);
        if (sKeys.length !== 1 || sKeys[0] !== 'opacity') { return null; }
        var ov = styleDelta.opacity;
        if (ov == null) { return null; }                 // an opacity removal stays on the JSON path
        var ot = typeof ov;
        if (ot !== 'string' && ot !== 'number') { return null; }
        return { key: 'opacity', value: String(ov) };
    }

    return null;
}

function _Native_diffSub(x, y) {
    x = x || {}; y = y || {};
    var delta = null;
    for (var k in y) { if (x[k] !== y[k]) { (delta || (delta = {}))[k] = y[k]; } }
    // A key present in the old facts but gone from the new must be RESET on the host, not
    // left at its stale value (a reused view carrying a prior screen's flex/width/bg). Encode
    // the removal as null — it survives JSON.stringify (undefined would be dropped), and the
    // host treats null as "reset this property to its default".
    for (var k2 in x) { if (!(k2 in y)) { (delta || (delta = {}))[k2] = null; } }
    return delta;
}

function _Native_plain(facts) {
    var out = {};
    for (var key in facts) {
        switch (key) {
            case 'a__1_STYLE': case 'a__1_EVENT':
            case 'a__1_ATTR': case 'a__1_ATTR_NS': continue;
        }
        out[key] = facts[key];
    }
    return out;
}

// Mirror of _VirtualDom_applyEvents' update logic: a handler rebuilt each render
// with the SAME kind (`$` tag) is updated IN PLACE on the existing callback — no
// churn, no host round-trip. We only return a names array (triggering an `__events`
// prop update) when the *set* of event names actually changes (a name added/removed),
// because that is the only thing the host needs to re-learn. A handler-tag change on
// an existing name re-registers the callback but does not change which events the
// host emits, so it needs no prop update either.
function _Native_diffEvents(handle, xEv, yEv, eventNode) {
    xEv = xEv || {}; yEv = yEv || {};
    var byHandle = _Native_eventRegistry[handle] || (_Native_eventRegistry[handle] = Object.create(null));
    var nameSetChanged = false;
    var names = [];
    for (var ev in yEv) {
        names.push(ev);
        var old = byHandle[ev];
        if (old && old.__handler.$ === yEv[ev].$) {
            old.__handler = yEv[ev];
            old.__eventNode = eventNode;
        } else {
            byHandle[ev] = _Native_makeCallback(eventNode, yEv[ev]);
            if (!old) { nameSetChanged = true; }
        }
    }
    for (var ev2 in byHandle) {
        if (!(ev2 in yEv)) { delete byHandle[ev2]; nameSetChanged = true; }
    }
    return nameSetChanged ? names : null;
}


// ============================================================================
// CHILDREN RECONCILIATION  (mirror of _VirtualDom_updateTNodeKids) — unkeyed.
// ============================================================================

function _Native_updateKids(nNode, xKids, yKids, eventNode) {
    var parent = nNode.__handle;
    var nKids = nNode.__kids;
    var xLen = xKids.length, yLen = yKids.length;

    var minLen = xLen < yLen ? xLen : yLen;
    for (var i = 0; i < minLen; i++) {
        var before = nKids[i].__handle;
        var updated = _Native_updateTNode(nKids[i], xKids[i], yKids[i], eventNode);
        if (updated.__replaced) {
            // handle changed under us: swap the child view in the parent
            _Native_removeChild(parent, before, i);
            _Native_insertChild(parent, updated.__handle, i);
            updated.__replaced = false;
        }
        nKids[i] = updated;
    }

    // remove surplus old children (reverse order keeps indices valid)
    for (var r = xLen - 1; r >= yLen; r--) {
        _Native_removeChild(parent, nKids[r].__handle, r);
        _Native_releaseEvents(nKids[r]);
    }
    if (xLen > yLen) { nKids.length = yLen; }

    // append new children
    for (var a = xLen; a < yLen; a++) {
        var kidN = _Native_render(yKids[a], eventNode);
        nKids[a] = kidN;
        _Native_insertChild(parent, kidN.__handle, a);
    }
}


// ============================================================================
// LONGEST INCREASING SUBSEQUENCE  (verbatim port of _VirtualDom_lisIndices).
// Given each new child's PRIOR index among the parent's current children (-1 for a
// fresh node with no prior position), returns a Set of new-positions whose nodes are
// already in relative order and therefore must NOT move. O(n log n), patience-sort
// tails + parent backtracking. This is what makes a keyed reorder move-minimal.
// ============================================================================

function _Native_lisIndices(arr) {
    var n = arr.length;
    var tails = [];
    var tailIndices = [];
    var parent = new Int32Array(n).fill(-1);
    for (var i = 0; i < n; i++) {
        var val = arr[i];
        if (val < 0) { continue; }
        var lo = 0, hi = tails.length;
        while (lo < hi) {
            var mid = (lo + hi) >>> 1;
            tails[mid] < val ? (lo = mid + 1) : (hi = mid);
        }
        tails[lo] = val;
        tailIndices[lo] = i;
        parent[i] = lo > 0 ? tailIndices[lo - 1] : -1;
    }
    var result = new Set();
    var idx = tailIndices.length > 0 ? tailIndices[tailIndices.length - 1] : -1;
    while (idx >= 0) {
        result.add(idx);
        idx = parent[idx];
    }
    return result;
}


// ============================================================================
// KEYED CHILDREN RECONCILIATION  (mirror of _VirtualDom_updateTNodeKeyedKids).
// Map keys → existing nNodes, update matches, recycle orphans, then reorder with the
// LIS move-minimization pass: keep the longest already-in-order run fixed and emit a
// single insertChild only for the nodes that actually move (plus fresh nodes).
//
// REORDER — anchor-relative, mirroring the web walker's direction but for a host whose
// insertChild is REMOVE-then-insert-AT-INDEX (Android/iOS Fabric, and the harness mock).
// The web walker uses insertBefore(node, anchorDomNode), an O(1) anchor reference, and
// processes RIGHT-to-LEFT so the anchor is already final. This host has no anchor handle,
// only a numeric index, and its insertChild detaches the child first — so a naïve "insert
// newN[d] at index d, left-to-right" is WRONG: removing a mover from its current slot
// shifts the as-yet-unplaced LIS survivors, so a later index lands the node in the wrong
// place (e.g. rotate-2 of [r0..r4] produced [r2,r3,r0,r4,r1] instead of [r2,r3,r4,r0,r1]).
//
// The correct, index-faithful equivalent is a TWO-PHASE pass that never lets a floating
// (about-to-move) node disturb the index of a node we have not placed yet:
//   phase 1 — DETACH every non-LIS node that is currently parented (a survivor that moves,
//             or the OLD handle of a node whose type changed under us, __replaced). After
//             phase 1 the host holds EXACTLY the LIS-kept survivors, in final relative order.
//   phase 2 — RE-INSERT every non-LIS node in FINAL (left-to-right) order, each at the index
//             = how many already-settled nodes (LIS-kept + movers re-inserted so far) have a
//             SMALLER final position. That rank is read in O(log n) from a Fenwick/BIT keyed
//             on final position, so a full reverse (|LIS|==1) costs N-1 inserts in O(n log n)
//             — the move-minimal count the scaling assertion pins. LIS nodes never move.
// Verified by harness/run-stress.js (rotations/reverse/swaps + 500k mixed insert/delete/
// reorder fuzz cases) — host child order now equals the new key order in every case.
//
// HANDLE BOOKKEEPING (the no-leak invariant). handleToOld must be built from the OLD child
// handles BEFORE the match/recycle pass runs, because recycling an orphan onto a
// type-changed new child calls _Native_updateTNode → _Native_redraw, which MUTATES that
// nNode's __handle in place (mints a fresh native view). Read after the fact, the map would
// key on the new handle and the OLD view would never be detached → a created-but-unparented
// leak. We also honor __replaced in this keyed path exactly as _Native_updateKids does for
// the unkeyed path: a node whose handle changed has its OLD handle removed (phase 1) and its
// NEW handle inserted (phase 2, since its oldIndex is forced to -1 = "not in the host").
// ============================================================================

function _Native_updateKeyedKids(nNode, xKids, yKids, eventNode) {
    var parent = nNode.__handle;
    var oldN = nNode.__kids;

    // BUG (b) LEAK fix — build the old-handle → old-index map FIRST, off the PRE-update handles.
    // Recycling/diffing below can call _Native_redraw, which mutates an nNode's __handle in place;
    // reading the map afterwards would key on the mutated handle and leak the detached old view.
    var handleToOld = Object.create(null);
    for (var t = 0; t < oldN.length; t++) { handleToOld[oldN[t].__handle] = t; }

    var oldMap = Object.create(null);
    for (var i = 0; i < xKids.length; i++) {
        oldMap[xKids[i].a] = { vnode: xKids[i].b, nNode: oldN[i], used: false };
    }

    // oldHandle[q] = the native handle newN[q] occupied in the parent BEFORE this frame (or
    // undefined if it is brand new). Captured per match/recycle from the entry's PRE-redraw
    // handle, so a __replaced node's stale view can still be detached even though its nNode's
    // __handle now points at the fresh view.
    var newN = new Array(yKids.length);
    var oldHandle = new Array(yKids.length);
    var unmatched = [];
    for (var j = 0; j < yKids.length; j++) {
        var entry = oldMap[yKids[j].a];
        if (entry) {
            var prevHandle = entry.nNode.__handle; // before any redraw mutates it
            var updated = _Native_updateTNode(entry.nNode, entry.vnode, yKids[j].b, eventNode);
            updated.__key = yKids[j].a;
            entry.used = true;
            newN[j] = updated;
            oldHandle[j] = prevHandle;
        } else {
            unmatched.push(j);
        }
    }

    // recycle orphans (old keys gone in new) for the unmatched new positions
    var orphans = [];
    for (var o = 0; o < xKids.length; o++) {
        var e = oldMap[xKids[o].a];
        if (!e.used) { orphans.push(e); }
    }
    var oi = 0;
    for (var u = 0; u < unmatched.length; u++) {
        var pos = unmatched[u];
        if (oi < orphans.length) {
            var orphan = orphans[oi++];
            var orphanPrev = orphan.nNode.__handle; // before redraw mutates it
            var up = _Native_updateTNode(orphan.nNode, orphan.vnode, yKids[pos].b, eventNode);
            up.__key = yKids[pos].a;
            newN[pos] = up;
            oldHandle[pos] = orphanPrev;
        } else {
            var fresh = _Native_render(yKids[pos].b, eventNode);
            fresh.__key = yKids[pos].a;
            newN[pos] = fresh;
            oldHandle[pos] = undefined; // brand-new view, not yet parented
        }
    }

    // remove any orphans we didn't reuse
    for (; oi < orphans.length; oi++) {
        // its handle is still under parent; find + detach by current handle
        _Native_removeChild(parent, orphans[oi].nNode.__handle, -1);
        _Native_releaseEvents(orphans[oi].nNode);
    }

    // Each new child's PRIOR index among the parent's current children is its old __kids index,
    // looked up via the handle it held BEFORE this frame. A node whose handle CHANGED under us
    // (__replaced — a type change minted a fresh view) is treated as NOT in the host: its old
    // view is detached in phase 1 and its new view inserted in phase 2, exactly like a fresh node.
    var oldIndices = new Array(newN.length);
    for (var q = 0; q < newN.length; q++) {
        var prior = (oldHandle[q] === undefined) ? undefined : handleToOld[oldHandle[q]];
        oldIndices[q] = (prior === undefined || newN[q].__replaced) ? -1 : prior;
    }
    var keep = _Native_lisIndices(oldIndices);

    // BUG (a) ORDER + (b) LEAK — anchor-relative two-phase reorder (see header comment).
    // Phase 1: detach every non-LIS node that is currently parented. For a surviving mover that
    // is its old view (oldIndices>=0) we remove its current handle. For a __replaced node we
    // remove its OLD (now-stale) handle so the replaced view never leaks. After this the parent
    // holds exactly the LIS-kept survivors in final relative order.
    for (var p1 = 0; p1 < newN.length; p1++) {
        if (keep.has(p1)) { continue; }
        if (oldIndices[p1] >= 0) {
            _Native_removeChild(parent, newN[p1].__handle, oldIndices[p1]);
        } else if (newN[p1].__replaced && oldHandle[p1] !== undefined) {
            _Native_removeChild(parent, oldHandle[p1], -1);
        }
        newN[p1].__replaced = false; // its new handle is (re)inserted in phase 2
    }
    // Phase 2: re-insert each non-LIS node in FINAL order at its move-minimal index = the number
    // of already-settled nodes (LIS-kept + movers placed so far) whose final position is smaller.
    // settled[] is a Fenwick tree keyed on final position; LIS-kept nodes are settled from the
    // start, each re-inserted mover becomes settled. O(log n) per query → O(n log n) total.
    var settled = _Native_makeBit(newN.length);
    for (var s = 0; s < newN.length; s++) { if (keep.has(s)) { _Native_bitAdd(settled, s, 1); } }
    for (var d = 0; d < newN.length; d++) {
        if (keep.has(d)) { continue; }
        var index = _Native_bitSum(settled, d - 1);
        _Native_insertChild(parent, newN[d].__handle, index);
        _Native_bitAdd(settled, d, 1);
    }
    nNode.__kids = newN;
}

// Fenwick / binary-indexed tree over positions 0..n-1 (1-based internally). Supports point-add
// and prefix-sum in O(log n). Used by the keyed reorder to read, in final-position order, how many
// already-placed children sit to the left of an insertion slot — the move-minimal insert index.
function _Native_makeBit(n) { return new Int32Array(n + 1); }
function _Native_bitAdd(t, i, v) { for (i += 1; i < t.length; i += i & -i) { t[i] += v; } }
function _Native_bitSum(t, i) {
    var s = 0;
    for (i += 1; i > 0; i -= i & -i) { s += t[i]; }
    return s;
}


// ============================================================================
// THE NATIVE ANIMATOR  (mirror of _Browser_makeAnimator) — coalesce model updates
// into frames. Uses the host's vsync post when available, else a microtask, else
// synchronous draw. Same 3-state machine as the browser animator.
// ============================================================================

var _NATIVE_NO_REQUEST = 0, _NATIVE_PENDING = 1, _NATIVE_EXTRA = 2;

function _Native_requestFrame(cb) {
    var h = _Native_host();
    if (h.__fabric_requestFrame) { h.__fabric_requestFrame(cb); }
    else if (typeof setTimeout !== 'undefined') { setTimeout(cb, 1000 / 60); }
    else { cb(); }
}

function _Native_makeAnimator(model, draw) {
    _Native_safeDraw(draw, model);
    var state = _NATIVE_NO_REQUEST;
    function updateIfNeeded() {
        state = state === _NATIVE_EXTRA
            ? _NATIVE_NO_REQUEST
            : (_Native_requestFrame(updateIfNeeded), _Native_safeDraw(draw, model), _NATIVE_EXTRA);
    }
    return function(nextModel, isSync) {
        model = nextModel;
        if (isSync) {
            _Native_safeDraw(draw, model);
            if (state === _NATIVE_PENDING) { state = _NATIVE_EXTRA; }
        } else {
            if (state === _NATIVE_NO_REQUEST) { _Native_requestFrame(updateIfNeeded); }
            state = _NATIVE_PENDING;
        }
    };
}

function _Native_safeDraw(draw, model) {
    try { draw(model); }
    catch (e) {
        var h = _Native_host();
        if (h.console && h.console.error) { h.console.error('Canopy native draw error', e); }
    }
}


// ============================================================================
// SOURCE-MAP SYMBOLICATION (DX M0).
//
// The dev bundle carries its aligned V3 source map as `__canopy_sourcemap` (a JSON string
// the build tool embeds; absent under --optimize). `__canopy_symbolicate(stack)` rewrites the
// `canopy.bundle.js:LINE:COL` frames in a Hermes error stack to `<Module>.can:line`, so the
// host's red-box (driven from guardJsCall) points at .can source instead of bundle offsets.
// Bare Hermes can't fetch the sibling .map, so the map travels in-bundle. Best-effort: any
// parse/lookup failure returns the input untouched — symbolication never masks the error.
// ============================================================================

var _Native_B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
var _Native_smIndex = null; // lazily built: { sources:[...], byLine:{ genLine -> {s:srcIdx,l:srcLine} } }

// Decode every Base64-VLQ field in one mapping segment into an array of signed ints.
function _Native_vlqDecode(seg) {
    var out = [], shift = 0, value = 0;
    for (var i = 0; i < seg.length; i++) {
        var d = _Native_B64.indexOf(seg.charAt(i));
        if (d < 0) continue;
        var cont = d & 32; d &= 31;
        value += d << shift;
        if (cont) { shift += 5; }
        else { var neg = value & 1; value >>>= 1; out.push(neg ? -value : value); shift = 0; value = 0; }
    }
    return out;
}

// Parse the embedded map into a generated-line → original-position index. srcIndex/srcLine
// VLQ fields are cumulative across the whole map (only genCol resets per line, which we
// ignore since the compiler emits column-0 line mappings).
function _Native_buildSmIndex() {
    var raw = _Native_host().__canopy_sourcemap;
    if (!raw) { return { sources: [], byLine: null }; }
    var map;
    try { map = (typeof raw === 'string') ? JSON.parse(raw) : raw; }
    catch (e) { return { sources: [], byLine: null }; }
    if (!map || typeof map.mappings !== 'string') { return { sources: [], byLine: null }; }
    var sources = map.sources || [];
    var byLine = {};
    var lines = map.mappings.split(';');
    var srcIdx = 0, srcLine = 0;
    for (var g = 0; g < lines.length; g++) {
        var segs = lines[g].split(',');
        var recorded = false;
        for (var k = 0; k < segs.length; k++) {
            if (!segs[k]) { continue; }
            var f = _Native_vlqDecode(segs[k]);
            if (f.length >= 4) { srcIdx += f[1]; srcLine += f[2]; }
            if (!recorded) { byLine[g] = { s: srcIdx, l: srcLine }; recorded = true; }
        }
    }
    return { sources: sources, byLine: byLine };
}

// @canopy-type a -> a
// @name symbolicate
function _Native_symbolicate(stack) {
    if (typeof stack !== 'string' || stack.length === 0) { return stack; }
    if (_Native_smIndex === null) { _Native_smIndex = _Native_buildSmIndex(); }
    var idx = _Native_smIndex;
    if (!idx || !idx.byLine) { return stack; }
    return stack.replace(/canopy\.bundle\.js:(\d+):(\d+)/g, function (whole, lineStr) {
        var genLine = (parseInt(lineStr, 10) | 0) - 1; // Hermes frames are 1-based; map is 0-based.
        var m = idx.byLine[genLine];
        for (var g = genLine - 1; g >= 0 && !m; g--) { m = idx.byLine[g]; } // nearest preceding mapping
        if (!m) { return whole; }
        var src = idx.sources[m.s] || 'canopy.bundle.js';
        return src + ':' + (m.l + 1); // 1-based original line
    });
}


// ============================================================================
// ENTRY POINT  (mirror of browser.js `element`) — the seam.
//
// Native.element { init, view, update, subscriptions } : Program flags model msg
//
// Swaps exactly two things vs. the browser seam:
//   • the mount: args['node'] is the Fabric ROOT handle (host-provided), not a DOM
//     element; there is no initial DOM to virtualize, so we start from an empty tree.
//   • the patcher: _VirtualDom_update → _Native_update (this walker).
// `view(model)`, `init`, `update`, `subscriptions`, and all of core/ are unchanged.
// ============================================================================

/**
 * Native element program — the native analog of Browser.element. The real type is
 * pinned by Native.element's Canopy signature; here it is fully polymorphic, exactly
 * as browser.js annotates its own `element`.
 * @canopy-type a -> b -> c -> d -> e
 * @name element
 */
var element = F4(function(init, view, update, subscriptions) {
    return F3(function(flagDecoder, debugMetadata, args) {
        // DEV-2 reload seam — opt the DEV-3 runtime state seam in BEFORE _Platform_initialize
        // runs, but ONLY in a debug bundle. _Platform_initialize reads globalThis._Platform_devSeam
        // at boot to decide whether to publish _Platform_live/_Platform_shutdown (the closure handles
        // __canopy_captureState/__canopy_teardown/__canopy_remount need for state-preserving reload).
        // __canopy_debug is the compiler's dev flag (true in dev, false under --optimize), so an
        // optimized production bundle never sets the flag → the seam stays fully inert. Setting it
        // here (not at module load) guarantees the ordering: the flag is on the global before the
        // _Platform_initialize call below, which is where DEV-3's _Platform_devSeam() is checked.
        _Native_installDevSeam();
        return _Platform_initialize(
            flagDecoder,
            args,
            init,
            update,
            subscriptions,
            function(sendToApp, initialModel) {
                // Self-install the native event dispatcher so the host need only emit
                // (handle, eventName, payload); also keeps _Native_dispatchEvent
                // reachable so the compiler does not tree-shake the event path.
                _Native_host().__canopy_dispatchEvent = _Native_dispatchEvent;
                // Expose the source-map symbolicator to the host's red-box (also keeps it
                // reachable so the compiler does not tree-shake the symbolication path).
                _Native_host().__canopy_symbolicate = _Native_symbolicate;
                // Stamp the frozen public extension ABI version (CanopyAbi.h / Escape-hatch M0):
                // a host can refuse a bundle whose ABI != its own.
                _Native_host().__canopy_abi_version = 1;
                // DEV-2: publish the reload seam (__canopy_captureState / __canopy_teardown /
                // __canopy_remount) so a debug host (DEV-4's JNI reload, the iOS dev loop) can
                // tear down + re-mount onto the SAME root without a fresh process. Idempotent; a
                // re-boot after reload re-installs against the new program's mount state.
                _Native_installReloadSeam();

                var rootHandle = (args && args['node'] != null)
                    ? args['node']
                    : _Native_createView('RCTRootView', {});
                _Native_setRoot(rootHandle);

                var rootN = { __handle: rootHandle, __kids: [] };
                var currNode = null;

                // DEV-2: lift the per-program walker state to a module-level mount record so the
                // reload seam can reach the SAME root handle + nNode tree after the program's own
                // closure is gone. `draw` writes currNode here each frame so a teardown can release
                // exactly the views this program mounted, and a remount re-renders from a clean tree.
                var mount = { rootHandle: rootHandle, rootN: rootN, currNode: null, rootTag: (args && args['node'] != null) ? args['node'] : null, flags: (args && args['flags']) };
                _Native_mount = mount;

                return _Native_makeAnimator(initialModel, function(model) {
                    var nextNode = view(model);
                    _Native_update(rootN, currNode, nextNode, sendToApp);
                    currNode = nextNode;
                    mount.currNode = currNode;
                });
            }
        );
    });
});

// The patcher entry the animator calls each frame. Renders on the first frame
// (currNode === null), diffs thereafter. Mirrors _VirtualDom_update's role.
function _Native_update(rootN, oldVNode, newVNode, sendToApp) {
    if (oldVNode === null) {
        var n = _Native_render(newVNode, sendToApp);
        rootN.__kids = [n];
        _Native_insertChild(rootN.__handle, n.__handle, 0);
        return;
    }
    var before = rootN.__kids[0].__handle;
    var updated = _Native_updateTNode(rootN.__kids[0], oldVNode, newVNode, sendToApp);
    if (updated.__replaced) {
        _Native_removeChild(rootN.__handle, before, 0);
        _Native_insertChild(rootN.__handle, updated.__handle, 0);
        updated.__replaced = false;
    }
    rootN.__kids[0] = updated;
}

// The host wires this once at boot: it returns the function the native side calls
// with (handle, eventName, payload) when a gesture/text event fires.
// @canopy-type () -> ()
// @name installEventDispatcher
function installEventDispatcher(_v) {
    _Native_host().__canopy_dispatchEvent = _Native_dispatchEvent;
    return _Utils_Tuple0;
}


// ============================================================================
// THE DEV-2 RELOAD SEAM — state-preserving in-process reload.
//
// Today a reload on a device is "force-stop + restart the whole process": multi-
// second, total state loss. DEV-2 makes the WALKER side of a state-preserving reload
// possible without a fresh process. The host (DEV-4's JNI reload(bundleJs), the iOS
// dev loop) drives the three phases below over ONE Hermes runtime, reusing the SAME
// Fabric root:
//
//   1. captureState()  — read the live TEA model (so it survives the new bundle eval)
//   2. teardown()      — stop the running Subs (via DEV-3's _Platform_shutdown so a
//                        reload does not double-subscribe) and release THIS program's
//                        native view subtree under the cached root, leaving a clean root
//   3. <host evaluates the new bundle, then calls __canopy_boot(rootTag, flags) again —
//      which re-runs `element` → _Platform_initialize → publishes a FRESH _Platform_live
//      and re-installs this seam against the new program's mount record>
//   4. remount(state)  — restore the captured model into the freshly-booted program via
//                        the new _Platform_live.setModel, so the user lands back where
//                        they were (the whole point vs. a cold restart)
//
// This file owns ONLY the JS half (the walker teardown + the DEV-3 seam handshake). The
// host half — evaluateJavaScript(newBundle) reusing the runtime — is DEV-4 (Android JNI)
// / the iOS dev loop, and is NOT in this file. The seam consumes the public DEV-3 globals
// (_Platform_live / _Platform_shutdown / _Platform_devSeam) only; it touches no compiler
// kernel internals, exactly like the rest of native.js.
//
// All of this is DEBUG-ONLY: _Native_installDevSeam sets _Platform_devSeam only when the
// compiler's __canopy_debug flag is on (false under --optimize), so the DEV-3 seam never
// even publishes _Platform_live in a production bundle, and these functions become inert
// no-ops there (captureState returns null, teardown/remount short-circuit).
// ============================================================================

// Module-level mount record for the live program (DEV-2). Lifted out of `element`'s
// per-program closure so the reload seam can reach the SAME root handle + nNode tree
// after the program's own closure is unreachable. `{ rootHandle, rootN, currNode,
// rootTag, flags }` or null when nothing is mounted.
var _Native_mount = null;

// True when the bundle was compiled in debug mode (the compiler emits __canopy_debug =
// true in dev, false under --optimize). Resolved defensively: a bundle that predates the
// flag, or this file loaded standalone in the test harness, simply has no __canopy_debug
// in scope → treat as NON-debug so we never flip the seam on by accident.
function _Native_isDebug() {
    try { return (typeof __canopy_debug !== 'undefined') && !!__canopy_debug; }
    catch (e) { return false; }
}

// Opt the DEV-3 runtime state seam in — BEFORE _Platform_initialize runs — but only in a
// debug bundle. _Platform_initialize reads globalThis._Platform_devSeam at boot to decide
// whether to publish _Platform_live; setting it here guarantees the ordering. In a release
// bundle (__canopy_debug === false) we leave the flag untouched, so DEV-3 stays inert and
// no model/effect-manager handles are ever exposed in production.
function _Native_installDevSeam() {
    if (!_Native_isDebug()) { return; }
    var g = _Native_host();
    if (g) { g._Platform_devSeam = true; }
}

// Publish the reload-seam entry points on the host global. Installed at boot from
// `element`; idempotent (a re-boot after reload just rebinds the same functions). Only
// reachable from a booted program, so a never-booted bundle exposes nothing.
function _Native_installReloadSeam() {
    var g = _Native_host();
    if (!g) { return; }
    g.__canopy_captureState = _Native_captureState;
    g.__canopy_teardown = _Native_teardown;
    g.__canopy_remount = _Native_remount;
}

// PHASE 1 — capture the live model so it survives the new-bundle evaluation. Reads the
// DEV-3 _Platform_live handle (published only when the dev seam is enabled). Returns an
// opaque carrier { model } the host threads back into remount(), or null when there is no
// live program / the seam is disabled (a release bundle). The carrier is intentionally an
// object, not the bare model, so a model whose value is itself null/0/false still round-
// trips through a truthiness-free `state != null` check.
// @canopy-type () -> a
// @name captureState
function _Native_captureState() {
    var g = _Native_host();
    var live = g && g._Platform_live;
    if (!live || typeof live.getModel !== 'function') { return null; }
    return { model: live.getModel() };
}

// PHASE 2 — tear the live program down WITHOUT killing the process. Two halves:
//   (a) runtime: stop every effect manager's receive-loop via DEV-3's _Platform_shutdown
//       so the running Subs do not keep firing into a torn-down view tree (and a reload
//       does not double-subscribe once the new program subscribes). _Platform_shutdown is
//       idempotent and also clears the published _Platform_live handle.
//   (b) walker: release the native views THIS program mounted under the cached root, so
//       the new program re-mounts onto a CLEAN root (no stale subtree, no leaked handles).
// After teardown the root handle itself is preserved (the host reuses it for the re-boot),
// but the mount record is dropped so the seam never re-touches a torn-down tree. Returns
// true when it tore an active program down, false when there was nothing live (idempotent).
// @canopy-type () -> Bool
// @name teardown
function _Native_teardown() {
    var g = _Native_host();

    // (a) stop Subs + clear the DEV-3 live handle. Guarded: a release bundle / a bundle
    // booted without the dev seam has no _Platform_shutdown, so just skip that half.
    if (g && typeof g._Platform_shutdown === 'function') { g._Platform_shutdown(); }

    var mount = _Native_mount;
    if (!mount) { return false; }

    // (b) detach + release this program's mounted subtree under the cached root. We remove
    // the single root child (the walker mounts exactly one node under the root — see
    // _Native_update) and recursively drop every event-registry entry it owned, so no stale
    // gesture callback survives into the reloaded program.
    var rootN = mount.rootN;
    if (rootN && rootN.__kids && rootN.__kids.length) {
        for (var i = rootN.__kids.length - 1; i >= 0; i--) {
            var kid = rootN.__kids[i];
            _Native_removeChild(rootN.__handle, kid.__handle, i);
            _Native_releaseTree(kid);
        }
        rootN.__kids = [];
    }

    // Drop the mount record so a stray frame / a double teardown cannot re-touch the torn
    // tree. The new program installs its own mount record on re-boot.
    _Native_mount = null;
    return true;
}

// Recursively release the event-registry entries an nNode subtree owns. Mirrors the
// per-node _Native_releaseEvents the diff already uses on redraw/remove, but walks the
// whole subtree so a torn-down program leaves NO live callbacks pointing at the old runtime.
function _Native_releaseTree(nNode) {
    if (!nNode) { return; }
    if (nNode.__handle != null && _Native_eventRegistry[nNode.__handle]) {
        delete _Native_eventRegistry[nNode.__handle];
    }
    var kids = nNode.__kids;
    if (kids) { for (var i = 0; i < kids.length; i++) { _Native_releaseTree(kids[i]); } }
}

// PHASE 4 — after the host has evaluated the new bundle and re-booted (__canopy_boot →
// element → _Platform_initialize publishes a FRESH _Platform_live and re-installs this
// seam), restore the captured model into the freshly-booted program. `state` is the carrier
// captureState() returned; restoring via the NEW _Platform_live.setModel re-renders the new
// program's view at the old model, landing the user back where they were. A null carrier (no
// captured state, or a release bundle) is a no-op: the new program just keeps its init model.
// Returns true when it restored a model, false otherwise.
// @canopy-type a -> Bool
// @name remount
function _Native_remount(state) {
    if (state == null) { return false; }
    var g = _Native_host();
    var live = g && g._Platform_live;
    if (!live || typeof live.setModel !== 'function') { return false; }
    live.setModel(state.model);
    return true;
}


// ============================================================================
// TEST SUPPORT — drives the REAL walker (_Native_render / _Native_updateTNode)
// against an in-memory mock Fabric, so `canopy test` can assert the §8 properties
// per component with no device. These functions are reachable ONLY from the
// Native.Testing module; a production app that never imports it tree-shakes this
// whole section out (proven: the same happens to the event dispatcher).
// ============================================================================

var _test_views = null;   // handle -> { tag, props, children:[handle] }
var _test_log = null;     // [{ op, ... }]
var _test_next = 1;

function _test_install() {
    _test_views = Object.create(null);
    _test_log = [];
    _test_next = 1;
    var g = _Native_host();
    g.__fabric_createView = function (tag, props) {
        var h = _test_next++;
        _test_views[h] = { tag: tag, props: _test_clone(props), children: [] };
        _test_log.push({ op: 'createView', handle: h, tag: tag });
        return h;
    };
    g.__fabric_updateProps = function (h, props) {
        var v = _test_views[h];
        for (var k in props) { if (props[k] === undefined) delete v.props[k]; else v.props[k] = props[k]; }
        _test_log.push({ op: 'updateProps', handle: h, props: _test_clone(props) });
    };
    // AND-8 fast path. A single scalar mutation is still ONE targeted prop update, so log it under
    // op:'updateProps' with the {key:value} shape — keeping testUpdateCountForUpdate / textAfterUpdate
    // (which count op==='updateProps' and read .props.text) byte-identical to the JSON path. opacity
    // mutates props.style.opacity so testStyleValue reflects it like applyStyle would on the host.
    g.__fabric_updatePropScalar = function (h, key, value) {
        var v = _test_views[h];
        if (key === 'opacity') {
            if (!v.props.style) v.props.style = {};
            v.props.style.opacity = value;
        } else {
            v.props[key] = value;
        }
        var p = {}; p[key] = value;
        _test_log.push({ op: 'updateProps', handle: h, props: p });
    };
    g.__fabric_insertChild = function (p, c, i) {
        var kids = _test_views[p].children;
        var at = kids.indexOf(c); if (at >= 0) kids.splice(at, 1);
        kids.splice(i < 0 || i > kids.length ? kids.length : i, 0, c);
        _test_log.push({ op: 'insertChild', parent: p, child: c });
    };
    g.__fabric_removeChild = function (p, c) {
        var kids = _test_views[p].children; var at = kids.indexOf(c);
        if (at >= 0) kids.splice(at, 1);
        _test_log.push({ op: 'removeChild', parent: p, child: c });
    };
    g.__fabric_setRoot = function () {};
    g.__fabric_setEvents = function () {};
    _Native_eventRegistry = Object.create(null);
}

function _test_clone(o) { var r = {}; for (var k in o) r[k] = o[k]; return r; }

function _test_render(vNode) {
    _test_install();
    return _Native_render(vNode, function () {});
}

// Concatenate all text reachable from a rendered node (text props + descendants).
function _test_textOf(handle) {
    var v = _test_views[handle];
    var s = (v.props && v.props.text != null) ? String(v.props.text) : '';
    for (var i = 0; i < v.children.length; i++) { s += _test_textOf(v.children[i]); }
    return s;
}

/**
 * Render a Native node and return the root view's Fabric component tag.
 * @canopy-type VirtualDom.Node msg -> String
 * @name testRootTag
 */
function testRootTag(vNode) {
    var n = _test_render(vNode);
    return _test_views[n.__handle].tag;
}

/**
 * Render a Native node and return all text it renders (label fast-path + descendants).
 * @canopy-type VirtualDom.Node msg -> String
 * @name testRootText
 */
function testRootText(vNode) {
    var n = _test_render(vNode);
    return _test_textOf(n.__handle);
}

/**
 * Render a Native node and return the Fabric tags of the root's direct children.
 * @canopy-type VirtualDom.Node msg -> List String
 * @name testChildTags
 */
function testChildTags(vNode) {
    var n = _test_render(vNode);
    var kids = _test_views[n.__handle].children;
    var arr = [];
    for (var i = 0; i < kids.length; i++) { arr.push(_test_views[kids[i]].tag); }
    return _List_fromArray(arr);
}

/**
 * Render `oldNode`, diff to `newNode`, and return how many NEW views were created
 * during the update (0 = no re-mount — the §8 criterion).
 * @canopy-type VirtualDom.Node msg -> VirtualDom.Node msg -> Int
 * @name testCreateCountForUpdate
 */
var testCreateCountForUpdate = F2(function (oldNode, newNode) {
    var n = _test_render(oldNode);
    _test_log = [];
    _Native_updateTNode(n, oldNode, newNode, function () {});
    return _test_log.filter(function (m) { return m.op === 'createView'; }).length;
});

/**
 * Render `oldNode`, diff to `newNode`, and return how many updateProps were emitted.
 * @canopy-type VirtualDom.Node msg -> VirtualDom.Node msg -> Int
 * @name testUpdateCountForUpdate
 */
var testUpdateCountForUpdate = F2(function (oldNode, newNode) {
    var n = _test_render(oldNode);
    _test_log = [];
    _Native_updateTNode(n, oldNode, newNode, function () {});
    return _test_log.filter(function (m) { return m.op === 'updateProps'; }).length;
});

/**
 * Render `oldNode`, diff to `newNode`, and return the text the tree shows afterwards.
 * @canopy-type VirtualDom.Node msg -> VirtualDom.Node msg -> String
 * @name testTextAfterUpdate
 */
var testTextAfterUpdate = F2(function (oldNode, newNode) {
    var n = _test_render(oldNode);
    _Native_updateTNode(n, oldNode, newNode, function () {});
    return _test_textOf(n.__handle);
});

/**
 * Render a node and return the value of one Fabric style prop on the root view (or the
 * empty string if absent). Lets canopy/css → native style mapping be asserted.
 * @canopy-type String -> VirtualDom.Node msg -> String
 * @name testStyleValue
 */
var testStyleValue = F2(function (key, vNode) {
    var n = _test_render(vNode);
    var props = _test_views[n.__handle].props;
    var style = props && props.style;
    return style && style[key] != null ? String(style[key]) : '';
});


// ============================================================================
// COMMONJS EXPORT — only for the Node test harness (harness/). In a real Canopy
// bundle on Hermes/browser, `module` is undefined, so this is skipped entirely and
// the file behaves as an ordinary inlined FFI module.
// ============================================================================

if (typeof module !== 'undefined' && module.exports) {
    module.exports = {
        // entry + patcher
        element: element,
        _Native_update: _Native_update,
        // walker internals (exposed so the harness can drive + assert on them)
        _Native_render: _Native_render,
        _Native_updateTNode: _Native_updateTNode,
        _Native_makeAnimator: _Native_makeAnimator,
        _Native_dispatchEvent: _Native_dispatchEvent,
        _Native_command: _Native_command,
        _Native_dispatchCommandResult: _Native_dispatchCommandResult,
        _Native_pendingCommands: _Native_pendingCommands,
        _Native_symbolicate: _Native_symbolicate,
        _Native_eventRegistry: _Native_eventRegistry,
        _Native_factsToProps: _Native_factsToProps,
        _Native_updatePropScalar: _Native_updatePropScalar,
        installEventDispatcher: installEventDispatcher,
        // DEV-2 reload seam (exposed so the harness can drive the walker half directly)
        _Native_captureState: _Native_captureState,
        _Native_teardown: _Native_teardown,
        _Native_remount: _Native_remount,
        _Native_installDevSeam: _Native_installDevSeam,
        _Native_installReloadSeam: _Native_installReloadSeam,
        // tags
        tags: { TEXT: __2_TEXT, NODE: __2_NODE, KEYED_NODE: __2_KEYED_NODE,
                CUSTOM: __2_CUSTOM, TAGGER: __2_TAGGER, THUNK: __2_THUNK, BLOCK: __2_BLOCK }
    };
}
