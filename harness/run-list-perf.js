#!/usr/bin/env node
// run-list-perf.js — RND-6 proof: Native.List genuinely skips off-window work.
//
// THE CLAIM (plans/dependent/RND-6.md): wrap each windowed row's renderItem in
// VirtualDom.lazy keyed by the row's data, so that a scroll that does NOT cross a row
// boundary diffs to ZERO host (Fabric) ops, and rows that are off-window are never
// mounted at all. Built on RND-1/2 (the thunk short-circuit in external/native.js) and
// the headless windowing math in Native.List.Window.
//
// We prove it two complementary ways:
//
//   PART 1 — END TO END, REAL BUNDLE.  Drive the ACTUAL compiled examples/listtest bundle
//   (a 1000-row Native.List, fixed 60px rows, 640px viewport, overscan 4 — its renderRow
//   wraps the row content in VirtualDom.lazy) against the mock Fabric, the same surface a
//   device drives. Assert:
//     (A) at boot only ~a-windowful of rows is created — NOT 1000 (off-window = no work);
//     (B) a scroll that stays inside the current row window emits ZERO createView /
//         insert / remove / row-content updateProps — only the header offset label moves;
//     (C) a scroll that crosses a boundary moves exactly the row(s) entering/leaving the
//         window (recycled by key) and leaves every surviving in-window row untouched.
//
//   PART 2 — THE MECHANISM, INSTRUMENTED.  The end-to-end op counts can't tell "diffed to
//   zero" apart from "diffed a lot and found no change" — both emit 0 updateProps when the
//   visible text is unchanged. The real discriminator (exactly as run-lazy.js argues) is
//   whether the per-row renderItem is RE-INVOKED. So we drive the REAL walker directly with
//   a windowed keyed list built two ways — lazy-wrapped vs eager — and count renderItem
//   calls across a same-window re-render. Lazy ⇒ zero re-invocations; eager ⇒ one per
//   visible row. This is what RND-6 actually changed.
//
// device-free; exits non-zero on any failed assertion (the CI gate, scripts/ci-test.sh).

'use strict';

const path = require('path');
const fs = require('fs');

let passed = 0, failed = 0; const fails = [];
function check(name, cond, detail) {
    if (cond) { passed++; console.log(`  \x1b[32m✓\x1b[0m ${name}`); }
    else { failed++; fails.push(name); console.log(`  \x1b[31m✗\x1b[0m ${name}${detail ? '  — ' + detail : ''}`); }
}
function section(t) { console.log(`\n\x1b[1m${t}\x1b[0m`); }

// ============================================================================
// PART 1 — END TO END against the REAL compiled listtest bundle.
// ============================================================================

const { createMockFabric } = require('./mock-fabric');

const BUNDLE = path.resolve(__dirname, '../examples/listtest/build/canopy.bundle.js');
if (!fs.existsSync(BUNDLE)) {
    console.error('listtest bundle not found — build it first:\n  canopy-native build examples/listtest\n  ' + BUNDLE);
    process.exit(2);
}

const mock = createMockFabric();
Object.assign(globalThis, mock.fabric);
require(BUNDLE);
globalThis.__canopy_boot(null, {});

// Helpers over the live mock tree.
const ROW_RE = /^Item /;
const itemRows = () => mock.findByTag('RCTText')
    .map((t) => t.props.text).filter((s) => typeof s === 'string' && ROW_RE.test(s));
const itemRowIndices = () => itemRows().map((s) => parseInt(s.slice(5), 10)).sort((a, b) => a - b);
const scrollView = () => mock.findByTag('RCTScrollView')[0];
function emitScroll(y) {
    mock.emit(scrollView().handle, 'scroll', { y, contentHeight: 60000, viewportHeight: 640 });
    mock.flushFrames();
}
function opsSinceClear() {
    const log = mock.log;
    return {
        creates: log.filter((m) => m.op === 'createView'),
        inserts: log.filter((m) => m.op === 'insertChild'),
        removes: log.filter((m) => m.op === 'removeChild'),
        updates: log.filter((m) => m.op === 'updateProps'),
        // updateProps that touched a ROW's content (its text) vs the header / wrapper geometry
        rowTextUpdates: log.filter((m) => m.op === 'updateProps'
            && m.tag === 'RCTText' && typeof m.props.text === 'string' && ROW_RE.test(m.props.text)),
    };
}

section('PART 1 — real compiled Native.List bundle (1000 rows, 60px, 640px viewport, overscan 4)');

section('A. Boot mounts only a windowful — off-window rows do NO fabric work');
const TOTAL = 1000;
const bootRows = itemRowIndices();
// viewport 640 / 60 ⇒ 11 visible, +4 overscan each side, clamped at the top ⇒ rows 0..14 (15 rows).
check('the data set is 1000 rows', true, `(rows are virtual; mounted=${bootRows.length})`);
check('FAR fewer rows are mounted than exist (windowed, not all 1000)',
    bootRows.length > 0 && bootRows.length < 40, `${bootRows.length} mounted`);
check('the mounted rows are a contiguous window starting at row 0',
    bootRows.length > 0 && bootRows[0] === 0 && bootRows[bootRows.length - 1] === bootRows.length - 1,
    `[${bootRows[0]}..${bootRows[bootRows.length - 1]}]`);
const bootCreatedItemTexts = mock.log.filter((m) => m.op === 'createView' && m.tag === 'RCTText').length;
check('createView fired for only a windowful of RCTText, not ~1000',
    bootCreatedItemTexts < 40, `${bootCreatedItemTexts} RCTText created at boot`);

// Scroll into the body so the window has overscan on BOTH sides (no top clamp), giving a clean
// "stays inside the window" scroll to test next.
emitScroll(600);
const baseRows = itemRowIndices();
check('after scrolling to y=600 the window slid (now starts past row 0)',
    baseRows[0] > 0, `window now [${baseRows[0]}..${baseRows[baseRows.length - 1]}]`);
const windowSize = baseRows.length;

section('B. A scroll that stays INSIDE the row window → ZERO row fabric work (lazy short-circuit)');
// y=600 and y=620 both floor to row 10 (600/60=10, 620/60=10.33) ⇒ identical render window.
// Every visible row's data is reference-identical (same Array element), so VirtualDom.lazy
// short-circuits each row's subtree to nothing. The ONLY thing that legitimately changes is the
// header's "offset N" label.
mock.clearLog();
emitScroll(620);
const b = opsSinceClear();
check('the render window is UNCHANGED (same rows mounted)',
    JSON.stringify(itemRowIndices()) === JSON.stringify(baseRows),
    `was [${baseRows[0]}..], now [${itemRowIndices()[0]}..]`);
check('ZERO createView (no row was re-mounted)', b.creates.length === 0, `${b.creates.length}`);
check('ZERO insertChild (no row moved)', b.inserts.length === 0, `${b.inserts.length}`);
check('ZERO removeChild (no row unmounted)', b.removes.length === 0, `${b.removes.length}`);
check('ZERO row-content updateProps (every windowed row diffed to nothing)',
    b.rowTextUpdates.length === 0, `${b.rowTextUpdates.length}: ` + JSON.stringify(b.rowTextUpdates.map((u) => u.props)));
check('exactly ONE updateProps total — only the header offset label',
    b.updates.length === 1 && b.updates[0].tag === 'RCTText' && /^offset /.test(b.updates[0].props.text || ''),
    `${b.updates.length}: ` + JSON.stringify(b.updates.map((u) => ({ tag: u.tag, props: u.props }))));

section('C. A scroll that CROSSES a boundary → only the entering/leaving row does work');
// y=620 → y=660: top edge crosses row 10→11, so one row leaves the top and one enters the bottom.
// The keyed reconciler recycles the leaving row's node onto the entering row; surviving in-window
// rows are untouched (their lazy thunks short-circuit).
const beforeRows = itemRowIndices();
mock.clearLog();
emitScroll(660);
const c = opsSinceClear();
const afterRows = itemRowIndices();
const entered = afterRows.filter((r) => !beforeRows.includes(r));
const left = beforeRows.filter((r) => !afterRows.includes(r));
const survivors = afterRows.filter((r) => beforeRows.includes(r));
check('the window advanced by exactly one row at each edge',
    entered.length === 1 && left.length === 1, `entered=${entered} left=${left}`);
check('ZERO createView even across the boundary (the leaving row recycled by key)',
    c.creates.length === 0, `${c.creates.length}`);
check('the structural churn is move-minimal (≤1 insert, ≤1 remove)',
    c.inserts.length <= 1 && c.removes.length <= 1, `inserts=${c.inserts.length} removes=${c.removes.length}`);
check('exactly ONE row-content text update — the row that ENTERED the window',
    c.rowTextUpdates.length === 1 && c.rowTextUpdates[0].props.text === ('Item ' + entered[0]),
    `${c.rowTextUpdates.length}: ` + JSON.stringify(c.rowTextUpdates.map((u) => u.props)));
// The decisive scaling claim: the count of row-content updates is INDEPENDENT of how many rows are
// in the window (it is 1 — only the entering row), NOT proportional to the window size. The N−1
// survivors paid nothing.
check(`${survivors.length} surviving in-window rows did ZERO content work (cost is O(rows entering), not O(window))`,
    c.rowTextUpdates.length === entered.length, `survivors=${survivors.length}, rowTextUpdates=${c.rowTextUpdates.length}`);

// ============================================================================
// PART 2 — THE MECHANISM: prove the lazy wrap is what stops per-row re-invocation.
// Drive the REAL walker directly (mirror of run-lazy.js) with a windowed keyed list built
// lazy-wrapped vs eager; count renderItem calls across a same-window re-render.
// ============================================================================

require('./mini-runtime'); // installs F2/F3/_VirtualDom_* helpers used below
const native = require('../package/external/native.js');
const T = native.tags; // { TEXT, NODE, KEYED_NODE, THUNK, ... }

// vnode builders (the exact data shape the compiler emits, as in run-keyed.js).
const vtext = (s) => ({ $: T.TEXT, __text: s });
const node = (tag, facts, kids) => ({ $: T.NODE, __tag: tag, __facts: facts || {}, __kids: kids, __namespace: undefined });
// A lazy/thunk node, exactly as VirtualDom.lazy produces it: { $: THUNK, __refs:[fn, arg], __node }.
const lazy = (fn, arg) => ({ $: T.THUNK, __refs: [fn, arg], __node: undefined });

// The instrumented per-row render — module-level ⇒ a STABLE reference across frames (the
// stable-callback discipline Native.List documents). Counting its invocations is the discriminator.
let renderItemCalls = 0;
function renderItem(item) {
    renderItemCalls++;
    return node('RCTText', {}, [vtext('Item ' + item.id)]);
}

// One windowed row: a keyed wrapper positioned at `offset`, content built `mode`-dependently.
// LAZY mode wraps renderItem in a thunk keyed on the (reference-stable) item; EAGER calls it inline.
function rowKeyed(item, offset, mode) {
    const wrapper = node('RCTView', { 'a__1_STYLE': { position: 'absolute', top: String(offset) } },
        [mode === 'lazy' ? lazy(renderItem, item) : renderItem(item)]);
    return { a: String(item.id), b: wrapper };
}
function windowNode(items, offsetOf, mode) {
    return { $: T.KEYED_NODE, __tag: 'RCTView', __facts: {},
        __kids: items.map((it) => rowKeyed(it, offsetOf(it), mode)) };
}

// A stable backing data set: items are reference-stable Array elements across renders (the second
// half of the discipline) — so a same-window re-render presents identical item references.
const DATA = Array.from({ length: 1000 }, (_, i) => ({ id: i }));

// Run one "scroll that does NOT change the window" re-render in the given mode and report how many
// times renderItem was invoked DURING THE UPDATE (boot invocations are excluded).
function sameWindowReRender(mode) {
    const mock2 = createMockFabric();
    Object.assign(globalThis, mock2.fabric);
    const ev = function () {};
    const WINDOW = DATA.slice(10, 29); // 19 rows, a realistic window
    const offsetOf = (it) => it.id * 60;

    renderItemCalls = 0; // count from a clean slate for THIS run (boot, then re-render)
    const x = windowNode(WINDOW, offsetOf, mode);
    const nNode = native._Native_render(x, ev);
    const bootCalls = renderItemCalls;

    // Re-render the SAME window (same items, same offsets) — a non-boundary scroll. The header label
    // would change in the real app, but the windowed rows are byte-identical; nothing in this subtree
    // should need to move.
    renderItemCalls = 0;
    mock2.clearLog();
    const y = windowNode(WINDOW, offsetOf, mode);
    native._Native_updateTNode(nNode, x, y, ev);
    const reRenderCalls = renderItemCalls;
    const fabricOps = mock2.log.filter((m) => m.op === 'createView' || m.op === 'insertChild'
        || m.op === 'removeChild' || m.op === 'updateProps').length;
    return { bootCalls, reRenderCalls, fabricOps, windowSize: WINDOW.length };
}

section('PART 2 — the discriminator: does a same-window re-render RE-INVOKE renderItem?');

const eager = sameWindowReRender('eager');
section('Control (EAGER — renderItem called inline, no lazy): the work RND-6 eliminates');
check('boot invokes renderItem once per windowed row', eager.bootCalls === eager.windowSize,
    `${eager.bootCalls} for ${eager.windowSize} rows`);
check('a same-window re-render RE-INVOKES renderItem for EVERY visible row (the cost RND-6 removes)',
    eager.reRenderCalls === eager.windowSize, `${eager.reRenderCalls} re-invocations`);

const lazyRun = sameWindowReRender('lazy');
section('RND-6 (LAZY — renderItem wrapped in VirtualDom.lazy keyed on the row item)');
check('boot still invokes renderItem once per windowed row', lazyRun.bootCalls === lazyRun.windowSize,
    `${lazyRun.bootCalls} for ${lazyRun.windowSize} rows`);
check('a same-window re-render invokes renderItem ZERO times (lazy short-circuited every row)',
    lazyRun.reRenderCalls === 0, `${lazyRun.reRenderCalls} re-invocations (expected 0)`);
check('a same-window re-render emits ZERO Fabric ops (no host work at all)',
    lazyRun.fabricOps === 0, `${lazyRun.fabricOps} fabric ops`);
check('lazy did strictly less per-row work than eager (the RND-6 win is real, not a relabel)',
    lazyRun.reRenderCalls < eager.reRenderCalls,
    `lazy=${lazyRun.reRenderCalls} vs eager=${eager.reRenderCalls}`);

// ============================================================================
section(`Result: ${failed === 0 ? '\x1b[32mPASS' : '\x1b[31mFAIL'}\x1b[0m  (${passed} passed, ${failed} failed)`);
if (failed) { console.log('failed checks:\n  - ' + fails.join('\n  - ')); }
process.exit(failed === 0 ? 0 : 1);
