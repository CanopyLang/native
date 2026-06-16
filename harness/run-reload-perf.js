#!/usr/bin/env node
// run-reload-perf.js — DEV-10: the RELOAD-DIFF PERF GATE.
//
// Builds on DEV-8 (the state-preserving reload: __canopy_captureState / __canopy_teardown /
// __canopy_remount over ONE runtime — run-reload-seam.js, run-reload-typehash.js) and on RND-1/RND-6
// (the `lazy`/thunk short-circuit in external/native.js — run-lazy.js, run-list-perf.js).
//
// THE CLAIM (plans/dependent/DEV-10.md): a state-preserving reload re-DIFFS only the changed subtree.
// On a large keyed list with lazy rows, a reload that changes EXACTLY ONE row's data must produce
// create/update counts that are O(changed) — a small constant — NOT O(N). The N−1 unchanged rows must
// pay nothing: their lazy thunks short-circuit, their host nodes are reused, no row re-mounts. And the
// whole re-diff must land inside a wall-clock budget (the DEV-10 "<1s" budget — see BUDGET below).
//
// WHY THIS IS DISTINCT FROM THE GATES IT BUILDS ON:
//   • run-list-perf.js (RND-6) proves a SCROLL that stays in / crosses the window is O(rows entering).
//   • run-reload-typehash.js / run-reload-seam.js (DEV-8/DEV-2) prove a reload of the COUNTER app
//     restores the model with one targeted updateProps.
//   DEV-10 is the INTERSECTION the master plan calls out explicitly: a RELOAD (not a scroll) of a
//   LARGE KEYED LIST (not the single-label counter) where the new bundle differs by ONE ROW — and the
//   re-diff cost is O(changed), not O(N). That is the property a real Fast Refresh edit hits: you tweak
//   one row's render and the reload must not re-mount the other 999.
//
// We prove it on three complementary layers, all device-free (the CI gate, scripts/ci-test.sh):
//
//   PART 1 — END TO END, REAL BUNDLE.  Drive the ACTUAL compiled examples/listtest bundle (a 1000-row
//   Native.List with lazy rows) through the FULL DEV-8 reload loop over ONE runtime — capture →
//   teardown → re-eval → re-boot onto the SAME root → remount. With the captured window equal to the
//   re-booted window (the unchanged-list reload), the re-diff must touch ZERO rows: 0 createView, 0
//   row updateProps, 0 structural insert/remove — the §8 reload criterion applied to a 1000-row list,
//   and inside the budget. This is the real seam, the real walker, the real bundle.
//
//   PART 2 — THE ONE-ROW-CHANGED RELOAD, SCALING.  The end-to-end bundle can't change one row's data
//   across a reload without a compiler edit (the listtest Model fixes its 1000 items at init). So we
//   drive the REAL walker directly (exactly as run-list-perf.js PART 2 and run-keyed.js do): build a
//   large keyed list of lazy rows, then re-diff it against a copy where EXACTLY ONE row's data changed
//   — which is byte-for-byte what __canopy_remount does internally (re-render the restored model against
//   the live tree). We assert across N ∈ {50, 200, 1000} that createView==0, updateProps==1, structural
//   churn==0, and the per-row render is RE-INVOKED exactly ONCE (the changed row) — the counts are
//   CONSTANT in N. O(changed), not O(N).
//
//   PART 3 — THE BUDGET + THE LAZY-FIX DEPENDENCY.  Time the one-row-changed re-diff and assert it lands
//   under the DEV-10 budget. Then prove the budget is HOSTAGE TO THE LAZY FIX (the plan's explicit note):
//   an EAGER list (no lazy wrap) re-invokes renderItem for ALL N rows on the same one-row reload, while
//   the LAZY list re-invokes it once. Without RND-1's short-circuit the reload is O(N) render work — the
//   gate documents and proves exactly why the <1s budget assumes the lazy fix.
//
// Run order independence: PART 1 boots the bundle in this process (require/vm); PARTS 2-3 drive the bare
// walker. No global opt-in flags leak (we never set _Platform_devSeam — native.js auto-enables it in the
// debug bundle), so this is safe to run inline in ci-test.sh after the other harnesses.
//
// Prereq: a listtest DEBUG bundle built from the DEV-2/DEV-3/DEV-8 compiler + native.js:
//   canopy-native build examples/listtest
// (ci-test.sh builds it first if absent, exactly as it does for run-list-perf.js.)

'use strict';

const path = require('path');
const fs = require('fs');
const vm = require('vm');
const { createMockFabric } = require('./mock-fabric');

// ---- the DEV-10 budget -----------------------------------------------------
// The master-plan budget is "<1s" for a state-preserving reload's re-diff. That is a WALL-CLOCK ceiling
// on the work the reload EMITS to the host (the diff that lands on the Fabric thread), not on the
// device's paint. We measure the JS re-diff (the part native.js owns) on this x86_64 CI box; the diff
// here completes in low single-digit milliseconds, so we gate at a hard 1000ms ceiling with enormous
// headroom — it catches an algorithmic blow-up (an O(N^2) reconciler, or a lost lazy short-circuit that
// re-renders every row) without flaking on CPU jitter. The absolute ms are machine-dependent; the
// SCALING assertions (constant counts across N) are the timing-independent heart of the gate.
const BUDGET_MS = 1000;

// ---- tiny assertion harness ------------------------------------------------
let passed = 0, failed = 0; const fails = [];
function check(name, cond, detail) {
  if (cond) { passed++; console.log(`  \x1b[32m✓\x1b[0m ${name}`); }
  else { failed++; fails.push(name); console.log(`  \x1b[31m✗\x1b[0m ${name}${detail ? '  — ' + detail : ''}`); }
}
function section(t) { console.log(`\n\x1b[1m${t}\x1b[0m`); }

// ============================================================================
// PART 1 — END TO END: the REAL listtest bundle through the full DEV-8 reload loop.
// ============================================================================
section('PART 1 — real compiled 1000-row Native.List bundle through the full state-preserving reload');

const BUNDLE = path.resolve(__dirname, '../examples/listtest/build/canopy.bundle.js');
if (!fs.existsSync(BUNDLE)) {
  console.error('listtest bundle not found — build it first:\n  canopy-native build examples/listtest\n  ' + BUNDLE);
  process.exit(2);
}
const SRC = fs.readFileSync(BUNDLE, 'utf8');

const ROW_RE = /^Item /;
// the mock keeps every view it ever created in one flat map — including OLD detached views after a
// teardown's removeChild. So findByTag('RCTText') would mix stale rows from boot #1 with the live ones
// from boot #2. We must read from the LIVE (attached) tree only, walking down from the root — exactly
// what run-reload-seam.js does — so a re-boot/remount count reflects what is actually mounted.
function allViews(mock) {
  const out = [];
  for (const tag of ['RCTRootView', 'RCTView', 'RCTScrollView', 'RCTText', 'RCTRawText']) out.push(...mock.findByTag(tag));
  return out;
}
function liveRowTexts(mock) {
  const byHandle = new Map(allViews(mock).map((v) => [v.handle, v]));
  const seen = new Set();
  const out = [];
  (function walk(handle) {
    if (handle == null || seen.has(handle)) return;
    seen.add(handle);
    const v = byHandle.get(handle);
    if (!v) return;
    if (v.tag === 'RCTText' && typeof v.props.text === 'string' && ROW_RE.test(v.props.text)) out.push(v.props.text);
    for (const c of v.children) walk(c);
  })(mock.rootHandle);
  return out;
}

// Boot #1.
const mock = createMockFabric();
Object.assign(globalThis, mock.fabric);
// We deliberately do NOT set _Platform_devSeam — native.js auto-enables it in a DEBUG bundle.
vm.runInThisContext(SRC, { filename: 'listtest.bundle.js' });
check('bundle installed the __canopy_boot hook', typeof globalThis.__canopy_boot === 'function');
globalThis.__canopy_boot(null, {});
const rootTag = mock.rootHandle;
check('reload seam is live on the list bundle (DEV-8 functions installed)',
  typeof globalThis.__canopy_captureState === 'function'
  && typeof globalThis.__canopy_teardown === 'function'
  && typeof globalThis.__canopy_remount === 'function');

const bootRows = liveRowTexts(mock).slice().sort();
check('boot mounts only a windowful of the 1000 rows (windowed, not all 1000)',
  bootRows.length > 0 && bootRows.length < 40, `${bootRows.length} mounted`);

// PHASE 1 — capture the live model (at the init scroll offset, so the re-booted window will MATCH it).
const captured = globalThis.__canopy_captureState();
check('captureState returned a model carrier', captured != null && typeof captured === 'object',
  JSON.stringify(captured && Object.keys(captured)));

// PHASE 2 — teardown.
const tore = globalThis.__canopy_teardown();
check('teardown tore the active list program down', tore === true, String(tore));
check('teardown detached the list subtree from the root',
  mock.findByTag('RCTRootView')[0].children.length === 0,
  String(mock.findByTag('RCTRootView')[0].children.length));

// PHASE 3 (host) — clear the Canopy registry (+ Elm alias) so the in-process re-eval is accepted, then re-eval + re-boot.
globalThis.Canopy = undefined;
globalThis.Elm = undefined;
if (globalThis.scope) { globalThis.scope.Canopy = undefined; globalThis.scope.Elm = undefined; }
vm.runInThisContext(SRC, { filename: 'listtest.bundle.js (reload)' });
globalThis.__canopy_boot(rootTag, {});  // SAME cached root tag — re-attach, do not re-create the surface
const reBootRows = liveRowTexts(mock).slice().sort();
check('re-boot re-mounted the windowful onto the SAME root',
  mock.findByTag('RCTRootView')[0].children.length === 1
  && reBootRows.length === bootRows.length, `rows=${reBootRows.length}`);

// PHASE 4 — remount the captured model. With the re-booted window EQUAL to the captured window (both at
// the init scroll offset), the state-preserving re-diff must find NOTHING: zero row work. This is the
// §8 reload criterion ("0 createView for the unchanged subtree") applied to a 1000-row list — the whole
// point of DEV-10's perf claim.
mock.clearLog();
const t0 = process.hrtime.bigint();
const restored = globalThis.__canopy_remount(captured);
mock.flushFrames();
const reloadMs = Number(process.hrtime.bigint() - t0) / 1e6;

const e2e = {
  creates: mock.log.filter((m) => m.op === 'createView').length,
  rowUpdates: mock.log.filter((m) => m.op === 'updateProps' && m.tag === 'RCTText'
    && typeof m.props.text === 'string' && ROW_RE.test(m.props.text)).length,
  structural: mock.log.filter((m) => m.op === 'insertChild' || m.op === 'removeChild').length,
  updates: mock.log.filter((m) => m.op === 'updateProps').length,
};
check('remount reported it restored the captured model', restored === true, String(restored));
check('the restored window equals the re-booted window (state preserved, nothing to re-diff)',
  JSON.stringify(liveRowTexts(mock).slice().sort()) === JSON.stringify(reBootRows),
  `restored=${liveRowTexts(mock).length} rows`);
check('reload re-diff created ZERO new views for the 1000-row list (§8 reload criterion at scale)',
  e2e.creates === 0, `${e2e.creates} createView`);
check('reload re-diff did ZERO row-content updates (every windowed lazy row short-circuited)',
  e2e.rowUpdates === 0, `${e2e.rowUpdates} row updateProps`);
check('reload re-diff did ZERO structural insert/remove (no row re-mounted)',
  e2e.structural === 0, `${e2e.structural} structural ops`);
check(`reload re-diff landed well inside the ${BUDGET_MS}ms budget`,
  reloadMs < BUDGET_MS, `took ${reloadMs.toFixed(3)}ms`);
console.log(`    (real-bundle reload re-diff: ${reloadMs.toFixed(3)}ms, ${e2e.updates} total updateProps — budget ${BUDGET_MS}ms)`);

// ============================================================================
// PART 2 — THE ONE-ROW-CHANGED RELOAD, driving the REAL walker directly, scaled in N.
// A reload's re-diff IS _Native_updateTNode(oldTNode, oldVNode, newVNode) over the mounted tree — the
// exact call __canopy_remount makes internally to re-render the restored model. We present a large keyed
// list of lazy rows, then re-diff against a copy with EXACTLY ONE row's data changed.
// ============================================================================
require('./mini-runtime'); // installs F2/F3/_VirtualDom_* the walker needs
const native = require('../package/external/native.js');
const T = native.tags; // { TEXT, NODE, KEYED_NODE, THUNK, ... }

// vnode builders — the exact data shape the compiler emits (as in run-keyed.js / run-list-perf.js).
const vtext = (s) => ({ $: T.TEXT, __text: s });
const node = (tag, facts, kids) => ({ $: T.NODE, __tag: tag, __facts: facts || {}, __kids: kids, __namespace: undefined });
// A lazy/thunk node exactly as VirtualDom.lazy produces it: { $: THUNK, __refs:[fn, arg], __node }.
const lazy = (fn, arg) => ({ $: T.THUNK, __refs: [fn, arg], __node: undefined });

// A module-level (STABLE-reference) per-row render. Counting its invocations is the discriminator
// between "diffed to nothing" and "re-rendered every row" — exactly as run-lazy.js argues.
let renderItemCalls = 0;
function renderItem(it) {
  renderItemCalls++;
  return node('RCTText', {}, [vtext('Item ' + it.label)]);
}
// One keyed row: keyed on the stable id, content a lazy thunk over the (reference-stable) item — so a
// row whose item reference is unchanged short-circuits, and the one changed row (new reference) re-forces.
function rowKeyed(item, mode) {
  const content = mode === 'lazy' ? lazy(renderItem, item) : renderItem(item);
  return { a: String(item.id), b: node('RCTView', {}, [content]) };
}
function keyedList(items, mode) {
  return { $: T.KEYED_NODE, __tag: 'RCTView', __facts: {}, __kids: items.map((it) => rowKeyed(it, mode)) };
}

// Run ONE one-row-changed reload re-diff of an N-row keyed list in the given mode.
//   • boot: render N rows (a stable backing array — reference-stable items, the documented discipline).
//   • reload: the NEW data is the SAME array with EXACTLY ONE row replaced by a fresh object carrying a
//     changed label (a new reference ⇒ that row's lazy thunk re-forces; the other N−1 are === ⇒ skip).
//   • measure the UPDATE re-diff only (boot work excluded): renderItem re-invocations + host ops + ms.
function oneRowChangedReload(N, mode) {
  const mock2 = createMockFabric();
  Object.assign(globalThis, mock2.fabric);
  const ev = function () {};

  const DATA = Array.from({ length: N }, (_, i) => ({ id: i, label: String(i) }));
  const x = keyedList(DATA, mode);
  renderItemCalls = 0;
  const tnode = native._Native_render(x, ev);
  const bootCalls = renderItemCalls;

  // change exactly ONE row, in the middle of the list (not an edge — exercises the keyed reconciler's
  // survivor path on both sides). Every OTHER item is the SAME reference as boot.
  const changeIdx = Math.floor(N / 2);
  const NEW = DATA.map((it, i) => (i === changeIdx ? { id: it.id, label: 'CHANGED' } : it));

  // Count every renderItem invocation the RELOAD causes. For the LAZY path the calls happen lazily
  // INSIDE the walker; for the EAGER path they happen as the new vnode tree is BUILT (renderItem is
  // called inline by rowKeyed). So reset the counter BEFORE building the new tree — building `y` is part
  // of the reload's render cost in eager mode, and is free (deferred into thunks) in lazy mode.
  renderItemCalls = 0;
  mock2.clearLog();
  const t0 = process.hrtime.bigint();
  const y = keyedList(NEW, mode);
  native._Native_updateTNode(tnode, x, y, ev);
  const ms = Number(process.hrtime.bigint() - t0) / 1e6;

  return {
    N, mode, bootCalls, reInvokes: renderItemCalls, ms,
    creates: mock2.log.filter((m) => m.op === 'createView').length,
    updates: mock2.log.filter((m) => m.op === 'updateProps').length,
    structural: mock2.log.filter((m) => m.op === 'insertChild' || m.op === 'removeChild').length,
    changedShown: !!mock2.findByTag('RCTText').find((t) => t.props.text === 'Item CHANGED'),
  };
}

section('PART 2 — one-row-changed reload of a large keyed list with lazy rows: O(changed), not O(N)');
const SIZES = [50, 200, 1000];
const lazyRuns = SIZES.map((N) => oneRowChangedReload(N, 'lazy'));
for (const r of lazyRuns) {
  section(`N = ${r.N} rows — change exactly one row, reload (re-diff)`);
  check('boot rendered every row once (renderItem called N times at mount)', r.bootCalls === r.N,
    `${r.bootCalls} for ${r.N} rows`);
  check('the reload re-rendered ONLY the changed row (renderItem re-invoked exactly once)',
    r.reInvokes === 1, `${r.reInvokes} re-invocations`);
  check('the reload created ZERO new views (no row re-mounted — the N−1 unchanged rows reused)',
    r.creates === 0, `${r.creates} createView`);
  check('the reload emitted exactly ONE updateProps (only the changed row\'s text)',
    r.updates === 1, `${r.updates} updateProps`);
  check('the reload did ZERO structural insert/remove (no reorder for a pure content change)',
    r.structural === 0, `${r.structural} structural ops`);
  check('the changed row\'s new content is live in the tree ("Item CHANGED")', r.changedShown);
}

// THE SCALING ASSERTION — the heart of DEV-10. The cost counts are CONSTANT across N: a 50-row reload
// and a 1000-row reload both re-render 1 row, create 0 views, emit 1 updateProps. O(changed), not O(N).
section('The scaling claim — cost is CONSTANT in N (O(changed), not O(N))');
const reInvokeSet = new Set(lazyRuns.map((r) => r.reInvokes));
const createSet = new Set(lazyRuns.map((r) => r.creates));
const updateSet = new Set(lazyRuns.map((r) => r.updates));
check('renderItem re-invocations are CONSTANT across N (always 1)',
  reInvokeSet.size === 1 && reInvokeSet.has(1), [...reInvokeSet].join(','));
check('createView count is CONSTANT across N (always 0)',
  createSet.size === 1 && createSet.has(0), [...createSet].join(','));
check('updateProps count is CONSTANT across N (always 1)',
  updateSet.size === 1 && updateSet.has(1), [...updateSet].join(','));
console.log('    ' + lazyRuns.map((r) => `N=${r.N}: ${r.reInvokes} render, ${r.creates} create, ${r.updates} update`).join('  |  '));

// ============================================================================
// PART 3 — THE BUDGET + THE LAZY-FIX DEPENDENCY (the plan's explicit note).
// ============================================================================
section('PART 3 — the reload re-diff is inside budget, AND the budget is hostage to the lazy fix');

const big = lazyRuns[lazyRuns.length - 1]; // N = 1000
check(`the 1000-row one-row reload re-diff is well inside the ${BUDGET_MS}ms budget`,
  big.ms < BUDGET_MS, `took ${big.ms.toFixed(3)}ms`);
console.log(`    (1000-row one-row reload re-diff: ${big.ms.toFixed(3)}ms — budget ${BUDGET_MS}ms)`);

// The plan note: "Document the <1s budget assumes the lazy fix." Prove it. An EAGER list (no lazy wrap)
// re-invokes renderItem for ALL N rows on the SAME one-row reload — O(N) render work — while the lazy
// list re-invokes it once. Without RND-1's short-circuit the reload's render cost scales with the list
// size; the budget would be at risk on a real (heavier-per-row) app. Note both still emit ONE
// updateProps (the diff finds a single changed leaf either way) — the RE-INVOCATION count is the true
// discriminator, exactly as run-lazy.js / run-list-perf.js establish.
const eagerBig = oneRowChangedReload(1000, 'eager');
check('CONTROL: an EAGER 1000-row list re-invokes renderItem for ALL 1000 rows on a one-row reload',
  eagerBig.reInvokes === 1000, `${eagerBig.reInvokes} re-invocations (the O(N) render cost the lazy fix removes)`);
check('the LAZY list did strictly less render work than EAGER (the lazy short-circuit is load-bearing)',
  big.reInvokes < eagerBig.reInvokes, `lazy=${big.reInvokes} vs eager=${eagerBig.reInvokes}`);
check('both paths still emit ONE updateProps — the re-invocation count, not the op count, is the discriminator',
  big.updates === 1 && eagerBig.updates === 1, `lazy=${big.updates} eager=${eagerBig.updates}`);
console.log(`    (the <1s reload budget assumes the lazy fix: lazy re-renders ${big.reInvokes} row, eager re-renders ${eagerBig.reInvokes})`);

// ============================================================================
section(`Result: ${failed === 0 ? '\x1b[32mPASS' : '\x1b[31mFAIL'}\x1b[0m  (${passed} passed, ${failed} failed)`);
if (failed) { console.log('failed checks:\n  - ' + fails.join('\n  - ')); }
process.exit(failed === 0 ? 0 : 1);
