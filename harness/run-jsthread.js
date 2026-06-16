// run-jsthread.js — RND-8 off-UI-thread marshalling: the device-free equivalence + decorrelation gate.
//
// RND-8 moves the JS/Hermes runtime onto a DEDICATED thread; a frame's view writes are marshalled to
// the UI thread as ONE flat binary batch per frame (the device path: __fabric_applyBatch's BatchSink →
// CanopyHostJni.applyBatchOnUi → main Looper → native runUiBatch → canopyApplyBinaryBatch replays it).
// The seam is OPT-IN behind a flag (debug.canopy.jsthread / CANOPY_JS_THREAD), built ON TOP of RND-7's
// binary batch — the whole frame is already ONE flat byte buffer, the only form cheap+safe to copy
// across the thread boundary.
//
// This harness drives the REAL `element` + animator stack (the same boot run-batch.js uses) against
// the mock Fabric in off-UI-thread mode — where __fabric_applyBatch COPIES each frame's binary buffer
// into a UI-side queue instead of replaying inline, and drainUiBatches() models the UI thread waking
// to replay them — and proves:
//
//   A. THE JS THREAD MAKES ZERO DIRECT VIEW WRITES. With the buffers parked (not yet drained), the
//      host view tree is EMPTY: the walker never touched android.view on the JS thread. The only thing
//      that crossed the seam is opaque bytes.
//   B. EQUIVALENCE. After the UI thread drains, the final view tree (tags/parentage/props/text) and the
//      replayed per-op mutation log are BYTE-IDENTICAL to the inline (single-thread) binary path —
//      through boot AND a sequence of taps. Off-UI-thread is a faithful drop-in, not a re-encoding.
//   C. DECORRELATION (the RND-8 verification criterion: "frame drops decorrelate from stream rate").
//      A burst of frames can be PRODUCED on the JS thread while the UI thread is busy/quiescent — the
//      buffers queue up (pendingUiBatches grows), JS never blocks — and a single later drain applies
//      them all to the identical final tree. The JS frame rate is independent of the UI drain rate.
//   D. ONE CROSS-THREAD MESSAGE PER FRAME. Each non-empty frame ships EXACTLY ONE buffer to the UI
//      thread (RND-7 collapsed the frame to one batch); a no-op frame ships ZERO. The cheapest possible
//      coupling — which is what lets the UI thread keep up regardless of JS-thread stream rate.
//
// Run: node harness/run-jsthread.js   (exit 0 = pass; wired into scripts/ci-test.sh)

'use strict';

require('./mini-runtime');
const native = require('../package/external/native.js');
const { createMockFabric } = require('./mock-fabric');
const { app } = require('./counter-view');

let passed = 0, failed = 0;
const fails = [];
function check(name, cond, detail) {
    if (cond) { passed++; console.log(`  \x1b[32m✓\x1b[0m ${name}`); }
    else { failed++; fails.push(name); console.log(`  \x1b[31m✗\x1b[0m ${name}${detail ? '  — ' + detail : ''}`); }
}
function section(t) { console.log(`\n\x1b[1m${t}\x1b[0m`); }

// Clear ANY batch globals a previous mode left on globalThis, then install this mock's surface (same
// discipline as run-batch.js — the walker re-resolves its batch mode from these globals each draw).
function installMock(mock) {
    delete globalThis.__fabric_applyBatch;
    delete globalThis.__fabric_batchBinary;
    delete globalThis.__fabric_batchHandleBase;
    Object.assign(globalThis, mock.fabric);
    native.installEventDispatcher(globalThis._Utils_Tuple0);
}

// Boot the counter program (host-owned root, like run.js / run-batch.js). Returns the program's
// sendToApp-driving handles AFTER a drain so the caller can read the live tree + drive taps.
function boot(mock) {
    installMock(mock);
    const flagDecoder = { tag: 'succeed', value: undefined };
    const programBuilder = native.element(app.init)(app.view)(app.update)(app.subscriptions);
    programBuilder(flagDecoder)(null)({ flags: undefined });
    return mock;
}

// A stable, handle-independent fingerprint of the live view tree (same as run-batch.js) so trees can be
// compared ACROSS modes despite differing absolute handle integers.
function treeFP(mock, handle) {
    const v = readView(mock, handle);
    if (!v) return '∅';
    const props = {};
    for (const k of Object.keys(v.props).sort()) { if (k === 'handle') continue; props[k] = v.props[k]; }
    const kids = v.children.map((c) => treeFP(mock, c)).join('');
    return `<${v.tag} ${JSON.stringify(props)}>${kids}</${v.tag}>`;
}
function readView(mock, handle) {
    for (const tag of ['RCTRootView', 'RCTView', 'RCTText', 'RCTRawText']) {
        for (const v of mock.findByTag(tag)) if (v.handle === handle) return v;
    }
    return null;
}
function labelText(mock) {
    const l = mock.findByTag('RCTText').find((v) => /^Count:/.test(v.props.text));
    return l ? l.props.text : null;
}
function canonLog(log) {
    const map = new Map(); let next = 0;
    const id = (h) => { if (!map.has(h)) map.set(h, next++); return map.get(h); };
    return log.map((m) => {
        switch (m.op) {
            case 'createView': return `C ${id(m.handle)} ${m.tag} ${JSON.stringify(m.props)}`;
            case 'updateProps': return `U ${id(m.handle)} ${JSON.stringify(m.props)}${m.scalar ? ' /s' : ''}`;
            case 'insertChild': return `I ${id(m.parent)} ${id(m.child)} ${m.index}`;
            case 'removeChild': return `R ${id(m.parent)} ${id(m.child)}`;
            case 'setRoot': return `ROOT ${id(m.handle)}`;
            case 'setEvents': return `E ${id(m.handle)} ${JSON.stringify(m.names)}`;
            default: return m.op;
        }
    }).join('\n');
}

// ---------------------------------------------------------------------------
section('A. The JS thread makes ZERO direct view writes (buffers parked, not drained)');

const offui = boot(createMockFabric({ batch: 'binary', offUiThread: true }));
check('off-UI-thread mock advertises the binary batch seam', offui.batchMode === 'binary');
check('off-UI-thread mode is active', offui.offUiThread === true);

// After boot, the walker produced the WHOLE initial render as ONE binary batch — but in off-UI-thread
// mode that batch is a parked buffer, NOT replayed. So the host view tree is still EMPTY: nothing was
// mounted on the JS thread. This is the load-bearing RND-8 property — the JS thread never touched a view.
check('boot produced exactly ONE parked UI batch', offui.pendingUiBatches === 1,
    `pending=${offui.pendingUiBatches}`);
check('NO views exist before the UI drain (JS thread wrote nothing)',
    offui.findByTag('RCTRootView').length === 0 && offui.findByTag('RCTView').length === 0,
    `root=${offui.findByTag('RCTRootView').length} view=${offui.findByTag('RCTView').length}`);
check('the log is empty before the UI drain (no per-op host calls on the JS thread)',
    offui.log.length === 0, `log=${offui.log.length}`);

// Now the UI thread wakes and drains: the buffer replays and the tree materialises.
const drained = offui.drainUiBatches();
check('the UI drain replayed exactly ONE buffer', drained === 1, `drained=${drained}`);
check('after the drain the root + program tree exist', offui.findByTag('RCTRootView').length === 1,
    `root=${offui.findByTag('RCTRootView').length}`);
check('after the drain the label reads "Count: 0"', labelText(offui) === 'Count: 0', String(labelText(offui)));
check('no UI batches remain pending after the drain', offui.pendingUiBatches === 0,
    `pending=${offui.pendingUiBatches}`);

// ---------------------------------------------------------------------------
section('B. EQUIVALENCE — off-UI-thread (drained) is byte-identical to the inline binary path');

// Drive BOTH an inline-binary mock and an off-UI-thread mock through the SAME tap script. For the
// off-UI mock we drain after each frame's emit so the tree tracks (the device's UI thread wakes each
// vsync); the final tree + log must match the inline path exactly.
// A tap enqueues a vsync frame via the animator (__fabric_requestFrame); flushFrames() runs the draw
// (JS-thread frame production → ONE batch). Inline mode replays it immediately; off-UI mode parks the
// buffer until drainUiBatches() (the UI-thread replay).
function driveInline(mock) {
    boot(mock);
    const inc = mock.findByTestID('increment'), reset = mock.findByTestID('reset');
    const tap = (h) => { mock.emit(h, 'press', {}); mock.flushFrames(); };
    tap(inc.handle); tap(inc.handle); tap(inc.handle); tap(reset.handle); tap(inc.handle);
    return mock;
}
function driveOffUi(mock) {
    boot(mock);
    mock.drainUiBatches();                // materialise the boot tree so testIDs resolve (UI thread woke)
    const inc = mock.findByTestID('increment'), reset = mock.findByTestID('reset');
    // each tap → JS-thread frame (flushFrames) → UI-thread replay (drainUiBatches), modelling vsync.
    const tap = (h) => { mock.emit(h, 'press', {}); mock.flushFrames(); mock.drainUiBatches(); };
    tap(inc.handle); tap(inc.handle); tap(inc.handle); tap(reset.handle); tap(inc.handle);
    return mock;
}

const inline = driveInline(createMockFabric({ batch: 'binary' }));
const offui2 = driveOffUi(createMockFabric({ batch: 'binary', offUiThread: true }));

const fpInline = treeFP(inline, inline.rootHandle);
const fpOffui = treeFP(offui2, offui2.rootHandle);
check('inline vs off-UI-thread: identical final tree', fpInline === fpOffui,
    fpInline === fpOffui ? '' : `\n  inline: ${fpInline}\n  offui : ${fpOffui}`);
check('inline label reads "Count: 1"', labelText(inline) === 'Count: 1', String(labelText(inline)));
check('off-UI-thread label reads "Count: 1"', labelText(offui2) === 'Count: 1', String(labelText(offui2)));

const logInline = canonLog(inline.log);
const logOffui = canonLog(offui2.log);
check('inline vs off-UI-thread: identical replayed op log', logInline === logOffui,
    logInline === logOffui ? '' : '\n--- inline ---\n' + logInline + '\n--- offui ---\n' + logOffui);

// ---------------------------------------------------------------------------
section('C. DECORRELATION — JS frames produced while the UI thread is busy; one late drain applies all');

// The RND-8 win: a BURST of frames is produced on the JS thread with the UI thread NOT draining (busy
// or slow). The buffers queue; JS never blocks on a view write. A single later drain applies them all
// to the identical final tree — so the JS frame rate is independent of the UI drain rate.
const burst = createMockFabric({ batch: 'binary', offUiThread: true });
boot(burst);
burst.drainUiBatches();                   // boot tree up (testIDs resolve)
const incB = burst.findByTestID('increment');
burst.resetCounts();

// Fire 10 taps, each producing a JS-thread frame (flushFrames), WITHOUT draining between them —
// modelling a UI thread that is stalled (e.g. a slow frame) while a high-frequency stream keeps
// feeding the JS thread.
const N = 10;
for (let i = 0; i < N; i++) { burst.emit(incB.handle, 'press', {}); burst.flushFrames(); }
check(`${N} frames produced on the JS thread WITHOUT any UI drain`, burst.counts.uiBatchesQueued === N,
    `queued=${burst.counts.uiBatchesQueued}`);
check(`all ${N} frame buffers are pending (the JS thread did not block on the UI thread)`,
    burst.pendingUiBatches === N, `pending=${burst.pendingUiBatches}`);
check('NO buffer was drained yet (UI thread was busy)', burst.counts.uiBatchesDrained === 0,
    `drained=${burst.counts.uiBatchesDrained}`);

// The UI thread finally wakes once and drains the whole backlog. The tree lands on the correct final
// value (Count: 10) — the deferred frames were neither lost nor reordered.
const drainedBurst = burst.drainUiBatches();
check(`the single late drain applied all ${N} backlogged frames`, drainedBurst === N, `drained=${drainedBurst}`);
check('after the backlog drain the label reads "Count: 10"', labelText(burst) === 'Count: 10',
    String(labelText(burst)));
check('no buffers remain pending after the backlog drain', burst.pendingUiBatches === 0,
    `pending=${burst.pendingUiBatches}`);

// ---------------------------------------------------------------------------
section('D. ONE cross-thread message per frame; a no-op frame ships ZERO');

const single = createMockFabric({ batch: 'binary', offUiThread: true });
boot(single);
single.drainUiBatches();
const incS = single.findByTestID('increment');
single.resetCounts();

// One real tap → JS-thread frame → exactly ONE buffer shipped to the UI thread (RND-7 collapsed the
// frame to one batch).
single.emit(incS.handle, 'press', {}); single.flushFrames();
check('one tap ships EXACTLY one buffer to the UI thread', single.counts.uiBatchesQueued === 1,
    `queued=${single.counts.uiBatchesQueued}`);
single.drainUiBatches();

// A no-op (nothing changed) ships ZERO buffers — the RND-9 hard no-op-frame rule, preserved through the
// off-UI-thread seam: a quiescent app produces no cross-thread traffic at all. A bare flushFrames with
// nothing queued runs no draw, so no buffer is produced.
single.resetCounts();
single.flushFrames();   // model a vsync with no model change; the animator posts no draw → no buffer.
check('a no-op frame ships ZERO buffers to the UI thread', single.counts.uiBatchesQueued === 0,
    `queued=${single.counts.uiBatchesQueued}`);

// ---------------------------------------------------------------------------
section(`Result: ${failed === 0 ? '\x1b[32mPASS' : '\x1b[31mFAIL'}\x1b[0m  (${passed} passed, ${failed} failed)`);
if (failed) { console.log('failed checks:\n  - ' + fails.join('\n  - ')); process.exit(1); }
process.exit(0);
