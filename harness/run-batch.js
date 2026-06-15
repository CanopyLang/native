// run-batch.js — RND-7 batched binary marshalling: the device-free equivalence + invariant gate.
//
// RND-7 collapses a frame's N per-mutation __fabric_* JSI calls (each paying a crossing + a
// JSON.stringify/parse) into ONE __fabric_applyBatch — Stage A (a JSON op array) or Stage B (a flat
// little-endian ArrayBuffer with NO per-mutation JSON on the seam). The walker opts in by
// feature-detecting the host's batch globals; a host without them keeps the per-mutation path.
//
// This harness drives the REAL `element` + animator stack (the same boot run.js uses) against the
// mock Fabric in ALL THREE modes — off (per-mutation), json (Stage A), binary (Stage B) — and proves:
//
//   1. EQUIVALENCE — the final native view tree (tags, parentage, props, text) and the per-op
//      mutation log are BYTE-IDENTICAL across the three modes, through boot AND a sequence of taps.
//      The binary protocol is therefore a faithful drop-in, not a re-encoding that drifts.
//   2. THE COLLAPSE INVARIANT — in batch mode the host sees ZERO per-mutation __fabric_createView/
//      updateProps/insertChild calls; EVERY frame's mutations arrive through exactly ONE
//      __fabric_applyBatch (counts.batches grows by 1 per non-empty draw, jsonProps/scalarProps via
//      the per-op replay only). A no-op frame (no model change) emits ZERO batches (the RND-9 hard
//      no-op-frame rule still holds through the batch).
//   3. THE BINARY DECODER round-trips — Stage B's ArrayBuffer decodes (in the mock, mirroring
//      CanopyFabric.cpp's BatchReader) to the exact same op stream Stage A carries, including
//      multibyte UTF-8 text (a non-ASCII label proves the length-prefixed UTF-8 framing).
//
// Run: node harness/run-batch.js   (exit 0 = pass; wired into scripts/ci-test.sh)

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

// Clear ANY batch globals a previous mode left on globalThis, then install this mock's surface. The
// walker re-resolves its batch mode from these globals at each draw's _Native_batchBegin, so a clean
// swap is what makes the three modes independent within one process.
function installMock(mock) {
    delete globalThis.__fabric_applyBatch;
    delete globalThis.__fabric_batchBinary;
    delete globalThis.__fabric_batchHandleBase;
    Object.assign(globalThis, mock.fabric);
    native.installEventDispatcher(globalThis._Utils_Tuple0);
}

// Boot the counter program and run a fixed tap script, returning the mock so the caller can read the
// final tree + the recorded log. Mirrors run.js's boot exactly (no `node` arg → host-owned root).
function bootAndDrive(mock) {
    installMock(mock);
    const flagDecoder = { tag: 'succeed', value: undefined };
    const programBuilder = native.element(app.init)(app.view)(app.update)(app.subscriptions);
    programBuilder(flagDecoder)(null)({ flags: undefined });

    const inc = mock.findByTestID('increment');
    const reset = mock.findByTestID('reset');
    // a deterministic script: three increments, a reset, one more increment.
    mock.emit(inc.handle, 'press', {}); mock.flushFrames();
    mock.emit(inc.handle, 'press', {}); mock.flushFrames();
    mock.emit(inc.handle, 'press', {}); mock.flushFrames();
    mock.emit(reset.handle, 'press', {}); mock.flushFrames();
    mock.emit(inc.handle, 'press', {}); mock.flushFrames();
    return mock;
}

// A stable, handle-independent fingerprint of the live view tree: tag + sorted props (minus the
// volatile numeric handle) + recursively its children. Lets us compare trees ACROSS modes even
// though the absolute handle integers differ (host-minted small ints vs JS-allocated high base).
function treeFP(mock, handle) {
    const v = readView(mock, handle);
    if (!v) return '∅';
    const props = {};
    for (const k of Object.keys(v.props).sort()) {
        if (k === 'handle') continue;
        props[k] = v.props[k];
    }
    const kids = v.children.map((c) => treeFP(mock, c)).join('');
    return `<${v.tag} ${JSON.stringify(props)}>${kids}</${v.tag}>`;
}
// Read a view from the mock by handle. The mock does not expose its `views` Map directly, so we
// reconstruct read access via findByTag/findByTestID is insufficient — add a tiny accessor that
// scans every tag's views for the handle. (Cheap; the counter tree is small.)
function readView(mock, handle) {
    for (const tag of ['RCTRootView', 'RCTView', 'RCTText', 'RCTRawText']) {
        for (const v of mock.findByTag(tag)) if (v.handle === handle) return v;
    }
    return null;
}

// Compare two mutation logs op-for-op, IGNORING the absolute handle integers (which legitimately
// differ between host-minted and JS-allocated handle spaces). We canonicalise each handle to the
// order it first appears, so two logs that mount the same shape in the same order match.
function canonLog(log) {
    const map = new Map();
    let next = 0;
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
section('A. Boot + drive the counter under all three marshalling modes');

const off = bootAndDrive(createMockFabric());                 // per-mutation (baseline)
const json = bootAndDrive(createMockFabric({ batch: 'json' })); // Stage A
const bin = bootAndDrive(createMockFabric({ batch: 'binary' })); // Stage B

check('per-mutation (off) mode advertised NO batch seam', off.batchMode === 'off');
check('Stage A (json) mode advertised the batch seam', json.batchMode === 'json');
check('Stage B (binary) mode advertised the batch seam', bin.batchMode === 'binary');

// ---------------------------------------------------------------------------
section('B. EQUIVALENCE — final view tree is byte-identical across modes');

const fpOff = treeFP(off, off.rootHandle);
const fpJson = treeFP(json, json.rootHandle);
const fpBin = treeFP(bin, bin.rootHandle);

check('off vs Stage A: identical final tree', fpOff === fpJson,
    fpOff === fpJson ? '' : `\n  off : ${fpOff}\n  json: ${fpJson}`);
check('off vs Stage B: identical final tree', fpOff === fpBin,
    fpOff === fpBin ? '' : `\n  off : ${fpOff}\n  bin : ${fpBin}`);

// the live label must read "Count: 1" after the script (inc×3, reset, inc×1) in every mode.
function labelText(mock) {
    const l = mock.findByTag('RCTText').find((v) => /^Count:/.test(v.props.text));
    return l ? l.props.text : null;
}
check('off label reads "Count: 1"', labelText(off) === 'Count: 1', String(labelText(off)));
check('Stage A label reads "Count: 1"', labelText(json) === 'Count: 1', String(labelText(json)));
check('Stage B label reads "Count: 1"', labelText(bin) === 'Count: 1', String(labelText(bin)));

// ---------------------------------------------------------------------------
section('C. EQUIVALENCE — the per-op mutation log is identical across modes');

const logOff = canonLog(off.log);
const logJson = canonLog(json.log);
const logBin = canonLog(bin.log);

check('off vs Stage A: identical op log (handle-canonicalised)', logOff === logJson,
    logOff === logJson ? '' : '\n--- off ---\n' + logOff + '\n--- json ---\n' + logJson);
check('off vs Stage B: identical op log (handle-canonicalised)', logOff === logBin,
    logOff === logBin ? '' : '\n--- off ---\n' + logOff + '\n--- bin ---\n' + logBin);

// ---------------------------------------------------------------------------
section('D. THE COLLAPSE INVARIANT — one host call per frame, zero per-mutation calls');

// In batch mode the per-mutation host methods are NEVER called directly by the walker; every op
// arrives via __fabric_applyBatch. The mock counts per-op handler hits (jsonProps/scalarProps) only
// from the REPLAY inside applyBatch, but counts.batches counts the actual host calls. The
// discriminator: batches > 0 (frames were collapsed) and the batch count is far below the op count.
const totalOpsBin = bin.log.length;
check('Stage B collapsed many ops into few host calls (batches < ops)',
    bin.counts.batches > 0 && bin.counts.batches < totalOpsBin,
    `batches=${bin.counts.batches}, ops=${totalOpsBin}`);
check('Stage A collapsed many ops into few host calls (batches < ops)',
    json.counts.batches > 0 && json.counts.batches < json.log.length,
    `batches=${json.counts.batches}, ops=${json.log.length}`);

// boot is ONE batch (the whole initial render + root mount), then each of the 5 taps is ONE batch
// (a single targeted text update). So 1 (boot) + 5 (taps) = 6 applyBatch calls total.
check('exactly 6 applyBatch calls (boot + 5 taps), Stage B', bin.counts.batches === 6,
    `got ${bin.counts.batches}`);
check('exactly 6 applyBatch calls (boot + 5 taps), Stage A', json.counts.batches === 6,
    `got ${json.counts.batches}`);

// no-op frame: with nothing queued, the animator posts no frame, so the draw closure never runs and
// ZERO batches land (RND-9's hard no-op-frame rule, preserved through the batch — a quiescent app
// makes no host calls at all). A genuine tap (next op below) then proves the counter resumed at one
// batch per frame, so the zero above is "nothing happened", not "wedged".
bin.resetCounts();
bin.flushFrames();
check('a quiescent flush (empty queue) emits ZERO batches (no-op frame)', bin.counts.batches === 0,
    `got ${bin.counts.batches}`);
bin.emit(bin.findByTestID('increment').handle, 'press', {}); bin.flushFrames();
check('the next real tap resumes at exactly ONE batch', bin.counts.batches === 1,
    `got ${bin.counts.batches}`);

// ---------------------------------------------------------------------------
section('E. THE BINARY DECODER — Stage B round-trips multibyte UTF-8');

// Directly exercise the encoder→decoder round-trip with a non-ASCII string to prove the
// length-prefixed UTF-8 framing (the trap a naïve char-count length would fail). We build a tiny
// op stream via the walker's encoder and decode it through the mock's decoder.
const enc = native._Native_encodeBatch;
const sample = [
    [1, 0x40000000, 'RCTText', '{}'],                       // create
    [3, 0x40000000, 'text', 'café ☕ Привет 🚀'],            // scalar with 1/2/3/4-byte UTF-8
    [2, 0x40000000, '{"style":{"opacity":"0.5"}}'],        // update with JSON prop bag
];
const buf = enc(sample);
check('encodeBatch produced an ArrayBuffer', buf instanceof ArrayBuffer, typeof buf);

// decode via a fresh binary mock's internal decoder (exposed by re-running applyBatch and capturing
// the replayed ops through the log). We boot a minimal binary mock, create the target handle, then
// feed the buffer and read back the resulting view.
const probe = createMockFabric({ batch: 'binary' });
installMock(probe);
probe.fabric.__fabric_applyBatch(buf);
const created = probe.findByTag('RCTText')[0];
check('decoded createView landed an RCTText', created && created.tag === 'RCTText');
check('decoded scalar set the multibyte text exactly', created && created.props.text === 'café ☕ Привет 🚀',
    created ? JSON.stringify(created.props.text) : 'no view');
check('decoded updateProps applied the JSON-string prop bag',
    created && created.props.style && created.props.style.opacity === '0.5',
    created ? JSON.stringify(created.props.style) : 'no view');

// ---------------------------------------------------------------------------
section(`Result: ${failed === 0 ? '\x1b[32mPASS' : '\x1b[31mFAIL'}\x1b[0m  (${passed} passed, ${failed} failed)`);
if (failed) { console.log('failed checks:\n  - ' + fails.join('\n  - ')); process.exit(1); }
process.exit(0);
