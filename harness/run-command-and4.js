#!/usr/bin/env node
// run-command-and4.js — device-free proof of the AND-4 imperative ops (focus/blur, measure,
// scrollTo/scrollToIndex) over the AND-3 __fabric_command seam.
//
// AND-3 froze the seam (walker → __fabric_command → host → async __commandResult). AND-4 lands the
// concrete ops on the Java host AND upgrades the walker to route results by an echoed __callId, so a
// SINGLE handle can have several ops in flight at once (a `measure` is genuinely async — the host
// defers it to post()/onLayout — and the app may fire a second before the first lands).
//
// This harness drives the REAL walker (_Native_command / _Native_dispatchEvent /
// _Native_dispatchCommandResult from package/external/native.js) against an AND-4-FAITHFUL mock host
// that mirrors CanopyHost.java's new command() dispatch: it reads the __callId out of the args,
// computes the op's result (focus→{ok}, measure→{x,y,width,height,pageX,pageY}, scroll→{ok}), and
// hops {__callId, ...result} back through __canopy_dispatchEvent(handle,"__commandResult",…) on a
// queued frame (the device hops it via the JS-thread Looper). Asserts:
//
//   A. each op fires exactly one __fabric_command carrying a UNIQUE __callId
//   B. the async result round-trips to the RIGHT per-callId callback (out-of-order completion safe)
//   C. CONCURRENT measures on ONE handle don't clobber each other (the AND-4 callId win over AND-3)
//   D. measure returns the frame contract; scrollToIndex out-of-range returns ok:false
//   E. the seam stays OPTIONAL (a host without __fabric_command does not throw)
//
// Device-gated remainder (emulator, CanopyFixtureUiTest): the real requestFocus()+IME, the
// getLocationInWindow window coords, and smoothScrollTo on a live NestedScrollView.

'use strict';

require('./mini-runtime'); // F2..F9, _Platform_initialize, etc.
const native = require('../package/external/native.js');

// ---- tiny assertion harness ------------------------------------------------
let passed = 0, failed = 0; const fails = [];
function check(name, cond, detail) {
    if (cond) { passed++; console.log(`  \x1b[32m✓\x1b[0m ${name}`); }
    else { failed++; fails.push(name); console.log(`  \x1b[31m✗\x1b[0m ${name}${detail ? '  — ' + detail : ''}`); }
}
function section(t) { console.log(`\n\x1b[1m${t}\x1b[0m`); }

// ============================================================================
// AND-4-faithful mock host — mirrors CanopyHost.java's command() dispatch shape.
// Each view carries a synthetic frame so measure/scroll return deterministic values.
// ============================================================================
function createAnd4Host() {
    const views = new Map();
    const log = [];
    let next = 1;
    let frameQueue = [];

    function emitResult(handle, callId, bodyObj) {
        // The host always echoes __callId; the rest is the op result. Hopped on the next frame.
        frameQueue.push(() => {
            const dispatch = globalThis.__canopy_dispatchEvent;
            if (!dispatch) return;
            dispatch(handle, '__commandResult', Object.assign({ __callId: callId }, bodyObj));
        });
    }

    const fabric = {
        __fabric_createView(tag, props) {
            const h = next++;
            views.set(h, { handle: h, tag, props: Object.assign({}, props || {}), children: [],
                           frame: { x: 0, y: 0, w: 0, h: 0, pageX: 0, pageY: 0 } });
            return h;
        },
        __fabric_updateProps() {},
        __fabric_insertChild(p, c) { const pv = views.get(p); if (pv) pv.children.push(c); },
        __fabric_removeChild() {},
        __fabric_setRoot() {},
        __fabric_setEvents() {},
        __fabric_requestFrame(cb) { frameQueue.push(cb); },

        // The AND-4 command dispatch: read __callId from args, run the op, echo {__callId,...result}.
        __fabric_command(handle, name, args) {
            const a = args || {};
            const callId = a.__callId != null ? a.__callId : null;
            log.push({ op: 'command', handle, name, callId, args: a });
            const v = views.get(handle);
            if (!v) { emitResult(handle, callId, { ok: false, error: 'unknown handle' }); return; }
            switch (name) {
                case 'focus': case 'blur':
                    emitResult(handle, callId, { ok: true });
                    break;
                case 'measure': {
                    const f = v.frame;
                    emitResult(handle, callId,
                        { x: f.x, y: f.y, width: f.w, height: f.h, pageX: f.pageX, pageY: f.pageY });
                    break;
                }
                case 'scrollTo':
                    emitResult(handle, callId, { ok: true });
                    break;
                case 'scrollToIndex': {
                    const idx = a.index | 0;
                    const inRange = idx >= 0 && idx < v.children.length;
                    emitResult(handle, callId, { ok: inRange });
                    break;
                }
                default:
                    emitResult(handle, callId, { name, args: a });
            }
        },
    };

    return {
        fabric,
        get log() { return log; },
        clearLog() { log.length = 0; },
        setFrame(h, fr) { const v = views.get(h); if (v) Object.assign(v.frame, fr); },
        flushFrames() {
            let guard = 0;
            while (frameQueue.length && guard++ < 1000) {
                const q = frameQueue; frameQueue = [];
                for (const cb of q) cb();
            }
        },
        // Deliver queued results in REVERSE (LIFO) order — models a slow op completing after a fast
        // one queued behind it, proving callId routing is order-independent.
        flushFramesLifo() {
            let guard = 0;
            while (frameQueue.length && guard++ < 1000) {
                const q = frameQueue; frameQueue = [];
                for (let i = q.length - 1; i >= 0; i--) q[i]();
            }
        },
    };
}

// ---- wire the mock host into the global JSI surface ------------------------
const mock = createAnd4Host();
Object.assign(globalThis, mock.fabric);
native.installEventDispatcher(globalThis._Utils_Tuple0);

const input = globalThis.__fabric_createView('RCTSinglelineTextInputView', {});
const scroll = globalThis.__fabric_createView('RCTScrollView', {});
const content = globalThis.__fabric_createView('RCTScrollContent', {});
globalThis.__fabric_insertChild(scroll, content, 0);
for (let i = 0; i < 5; i++) {
    globalThis.__fabric_insertChild(scroll, globalThis.__fabric_createView('RCTView', {}), i);
}

// =========================================================================
section('A. Each op fires ONE __fabric_command carrying a UNIQUE __callId');
mock.clearLog();
native._Native_command(input, 'focus', { select: true }, function () {});
native._Native_command(input, 'blur', {}, function () {});
const cmds = mock.log.filter(m => m.op === 'command');
check('two commands reached the host', cmds.length === 2, `${cmds.length}`);
check('the args carry a numeric __callId', cmds.every(c => typeof c.args.__callId === 'number'),
    JSON.stringify(cmds.map(c => c.args.__callId)));
check('the two __callIds are distinct', cmds.length === 2 && cmds[0].callId !== cmds[1].callId,
    cmds.length === 2 ? `${cmds[0].callId} vs ${cmds[1].callId}` : '');
check('op names threaded through (focus, blur)',
    cmds.length === 2 && cmds[0].name === 'focus' && cmds[1].name === 'blur');

// =========================================================================
section('B. The async result round-trips to the RIGHT per-callId callback');
let focusRes = null, blurRes = null;
native._Native_command(input, 'focus', {}, r => { focusRes = r; });
native._Native_command(input, 'blur', {}, r => { blurRes = r; });
check('neither callback fired synchronously', focusRes === null && blurRes === null);
mock.flushFrames();
check('focus callback got its own ok result', focusRes && focusRes.ok === true, JSON.stringify(focusRes));
check('blur callback got its own ok result', blurRes && blurRes.ok === true, JSON.stringify(blurRes));

// =========================================================================
section('C. CONCURRENT measures on ONE handle do NOT clobber (the AND-4 callId win)');
// Fire TWO measures on the same handle before flushing. Under AND-3's per-handle one-shot the
// second would overwrite the first's callback; AND-4's __callId routing keeps them separate.
mock.setFrame(input, { x: 4, y: 8, w: 100, h: 40, pageX: 12, pageY: 200 });
let m1 = null, m2 = null;
native._Native_command(input, 'measure', {}, r => { m1 = r; });
native._Native_command(input, 'measure', {}, r => { m2 = r; });
mock.flushFrames();
check('BOTH concurrent measure callbacks fired', m1 !== null && m2 !== null,
    `m1=${JSON.stringify(m1)} m2=${JSON.stringify(m2)}`);
check('the first measure callback was NOT clobbered by the second', m1 && m1.width === 100);

// out-of-order completion: a slow op A finishing AFTER a fast op B still reaches A's callback.
section('C2. Out-of-order completion still routes to the correct callback');
// Build a host whose frames flush LIFO to force B-before-A delivery.
const lifo = createAnd4Host();
Object.assign(globalThis, lifo.fabric);
native.installEventDispatcher(globalThis._Utils_Tuple0);
const v = globalThis.__fabric_createView('RCTView', {});
let a = null, b = null;
native._Native_command(v, 'measure', { tag: 'A' }, r => { a = Object.assign({ tag: 'A' }, r); });
native._Native_command(v, 'measure', { tag: 'B' }, r => { b = Object.assign({ tag: 'B' }, r); });
// flush in REVERSE so B's result is dispatched before A's, yet each still reaches its own callback
lifo.flushFramesLifo();
check('callback A received A’s result', a && a.tag === 'A');
check('callback B received B’s result', b && b.tag === 'B');
// restore the primary host surface for the remaining sections
Object.assign(globalThis, mock.fabric);
native.installEventDispatcher(globalThis._Utils_Tuple0);

// =========================================================================
section('D. measure returns the frame contract; scrollToIndex range-checks');
mock.setFrame(input, { x: 4, y: 8, w: 100, h: 40, pageX: 12, pageY: 200 });
let frame = null;
native._Native_command(input, 'measure', {}, r => { frame = r; });
mock.flushFrames();
check('measure result has the RN measure fields',
    frame && ['x', 'y', 'width', 'height', 'pageX', 'pageY'].every(k => k in frame),
    JSON.stringify(frame));
check('pageY is the non-zero window offset', frame && frame.pageY === 200, JSON.stringify(frame));

let inRange = null, outRange = null;
native._Native_command(scroll, 'scrollToIndex', { index: 2 }, r => { inRange = r; });
native._Native_command(scroll, 'scrollToIndex', { index: 999 }, r => { outRange = r; });
mock.flushFrames();
check('scrollToIndex(2) on a 5-child scroller → ok:true', inRange && inRange.ok === true, JSON.stringify(inRange));
check('scrollToIndex(999) out of range → ok:false', outRange && outRange.ok === false, JSON.stringify(outRange));

let scrolled = null;
native._Native_command(scroll, 'scrollTo', { x: 0, y: 120 }, r => { scrolled = r; });
mock.flushFrames();
check('scrollTo(y:120) → ok:true', scrolled && scrolled.ok === true, JSON.stringify(scrolled));

// =========================================================================
section('E. The seam stays OPTIONAL (a host without __fabric_command does not throw)');
const saved = globalThis.__fabric_command;
delete globalThis.__fabric_command;
let threw = false;
try { native._Native_command(input, 'focus', {}, function () {}); }
catch (e) { threw = true; }
check('no throw when the host lacks __fabric_command', !threw);
globalThis.__fabric_command = saved;

// the pending-callback registry must not leak entries after every result is delivered.
section('F. No callback leak: every delivered result clears its pending entry');
const before = Object.keys(native._Native_pendingCommands).length;
let n = 0;
native._Native_command(input, 'focus', {}, () => { n++; });
native._Native_command(input, 'blur', {}, () => { n++; });
mock.flushFrames();
const after = Object.keys(native._Native_pendingCommands).length;
check('both results delivered', n === 2, `${n}`);
check('no pending entries leaked after delivery', after === before, `before=${before} after=${after}`);

// ---------------------------------------------------------------------------
section(`Result: ${failed === 0 ? '\x1b[32mPASS' : '\x1b[31mFAIL'}\x1b[0m  (${passed} passed, ${failed} failed)`);
if (failed) { console.log('failed checks:\n  - ' + fails.join('\n  - ')); }
process.exit(failed === 0 ? 0 : 1);
