#!/usr/bin/env node
// bench.js — deterministic JS-CPU timing harness for the canopy/native walker (RND-3).
//
// This is the FIRST timing data that exists anywhere for canopy/native. It drives the
// REAL external/native.js walker (_Native_render + _Native_updateTNode) against the same
// in-memory mock Fabric the correctness harnesses use (run.js / run-keyed.js / run-lazy.js),
// and measures CPU time with process.hrtime.bigint() over four representative scenarios:
//
//   1. COLD RENDER      — build a keyed list of N rows from scratch (fresh mock each iter).
//   2. WARM DIFF        — re-diff the SAME tree with one leaf text changed (the §8 targeted
//                         single-prop update — the counter-app fast path).
//   3. FULL REORDER     — diff keyed(ids) → keyed(reverse ids): exercises the LIS move-min pass.
//   4. LAZY-STABLE DIFF — diff a tree with a lazy/thunk subtree whose arg is UNCHANGED while a
//                         sibling changes: proves the RND-1 lazy short-circuit is FAST, not just
//                         correct (the thunk render-fn must NOT be re-invoked).
//   5. SCALAR FAST PATH — (AND-8) a pure single-leaf-text-update loop, timed AND call-path-checked:
//                         the dominant per-frame mutation must take __fabric_updatePropScalar (no
//                         object/JSON marshalling), NOT __fabric_updateProps. The CI guard here is
//                         the call-path assertion (scalarProps>0, jsonProps==0 across the loop) +
//                         the p50 regression gate; the real arm64 per-frame-ms ledger (Phase A) is
//                         a device task (this sandbox is x86_64 — see AND-8).
//
// For each scenario we report p50 / p95 / p99 (plus min and mean) over K measured iterations
// after `warmup` unmeasured iterations (so V8's JIT has settled). With --expose-gc we also
// report a bytes/op allocation proxy (heapUsed delta over a fixed batch, gc'd before).
//
// --------------------------------------------------------------------------------------------
// BASELINE GATE (--baseline <path> / --update-baseline):
//   Absolute nanoseconds are MACHINE-DEPENDENT, so the regression gate is RELATIVE: current p50
//   per scenario is compared to the baseline p50, and the run fails (exit 1) only if current
//   exceeds baseline * (1 + tolerance) for any scenario (default tolerance = 0.25 = 25%, chosen
//   so the gate catches ALGORITHMIC regressions — an O(n)→O(n²) reconciler blows up 5-50x at
//   N=200 — without flaking on the real ~10-20% run-to-run CPU jitter of shared CI hardware;
//   tighten with --tolerance 0.10 on a dedicated/quiet machine).
//   ==> The baseline MUST be re-recorded per CI machine class. Never treat the ns figures as
//       portable thresholds. Re-record with: node --expose-gc bench.js --update-baseline.
// --------------------------------------------------------------------------------------------
// HERMES LANE (--hermes-compile): COMPILE-ONLY in this sandbox. We shell out to hermesc to PROVE
//   the real compiler bundle compiles to a valid .hbc (bytecode). We do NOT execute the .hbc —
//   there is no standalone `hermes` VM runner on disk or installable via npm (hermes-engine ships
//   only the compiler). Actual Hermes-CPU timing is gated to an on-device run (RND-4). Point
//   CANOPY_HERMESC at a hermesc binary, e.g. react-native/sdks/hermesc/linux64-bin/hermesc.
// --------------------------------------------------------------------------------------------

'use strict';

const path = require('path');
const fs = require('fs');
const os = require('os');
const { execFileSync } = require('child_process');

require('./mini-runtime'); // installs F2..F9, _Utils_Tuple0, _Platform_initialize, …
const native = require('../package/external/native.js');
const { createMockFabric } = require('./mock-fabric');

const T = native.tags; // { TEXT, NODE, KEYED_NODE, CUSTOM, TAGGER, THUNK, BLOCK }

// ============================================================================
// CLI
// ============================================================================
function parseArgs(argv) {
    const a = {
        runs: 1000,
        warmup: 100,
        batches: 5,
        rows: 200,
        json: false,
        baseline: null,
        updateBaseline: false,
        // Default 25%: a JS-CPU microbench on shared/loaded CI hardware has real run-to-run
        // jitter (scheduler + GC), and the fastest scenario (warmDiff, ~80us) shows the largest
        // RELATIVE noise. The gate exists to catch ALGORITHMIC regressions (e.g. a reconciler
        // going O(n)→O(n²) = a 5-50x blowup at N=200), not 10% noise. Tighten with --tolerance
        // 0.10 on a dedicated/quiet machine. See the header comment.
        tolerance: 0.25,
        hermesCompile: false,
    };
    for (let i = 2; i < argv.length; i++) {
        const t = argv[i];
        switch (t) {
            case '--runs': case '-K': a.runs = parseInt(argv[++i], 10); break;
            case '--warmup': a.warmup = parseInt(argv[++i], 10); break;
            case '--batches': a.batches = parseInt(argv[++i], 10); break;
            case '--rows': a.rows = parseInt(argv[++i], 10); break;
            case '--json': a.json = true; break;
            case '--baseline': a.baseline = argv[++i]; break;
            case '--update-baseline':
                a.updateBaseline = true;
                // allow `--update-baseline` to optionally carry a path, else fall back to
                // the conventional location handled below.
                break;
            case '--tolerance': a.tolerance = parseFloat(argv[++i]); break;
            case '--hermes-compile': a.hermesCompile = true; break;
            case '--help': case '-h': a.help = true; break;
            default:
                if (t.startsWith('-')) { console.error('unknown flag: ' + t); process.exit(2); }
        }
    }
    return a;
}

const DEFAULT_BASELINE = path.join(__dirname, 'bench-baseline.json');

// ============================================================================
// ANSI helpers (mirror run.js style)
// ============================================================================
const C = {
    g: (s) => `\x1b[32m${s}\x1b[0m`,
    r: (s) => `\x1b[31m${s}\x1b[0m`,
    y: (s) => `\x1b[33m${s}\x1b[0m`,
    b: (s) => `\x1b[1m${s}\x1b[0m`,
    dim: (s) => `\x1b[2m${s}\x1b[0m`,
};

// ============================================================================
// vnode builders — reused VERBATIM from run-keyed.js / run-lazy.js so the bench
// times the exact same shapes the correctness harnesses prove.
// ============================================================================
const vtext = (s) => ({ $: T.TEXT, __text: s });
const node = (tag, kids) => ({ $: T.NODE, __tag: tag, __facts: {}, __kids: kids, __namespace: undefined });
const row = (id) => node('RCTText', [vtext(id)]);
const keyed = (ids) => ({
    $: T.KEYED_NODE, __tag: 'RCTView', __facts: {},
    __kids: ids.map((id) => ({ a: id, b: row(id) })),
});

// a lazy/thunk node, identical shape to run-lazy.js: { $: THUNK, __refs: [fn, ...args], __node }
const lazy = (fn, arg) => ({ $: T.THUNK, __refs: [fn, arg], __node: undefined });

const ev = function () {}; // rows/leaves carry no event facts → eventNode is unused

// seeded shuffle so REORDER is deterministic run-to-run (stable baseline)
function shuffleSeeded(arr) {
    const a = arr.slice();
    let seed = 0x9e3779b9;
    const rnd = () => {
        // xorshift32
        seed ^= seed << 13; seed ^= seed >>> 17; seed ^= seed << 5;
        return ((seed >>> 0) / 0xffffffff);
    };
    for (let i = a.length - 1; i > 0; i--) {
        const j = Math.floor(rnd() * (i + 1));
        const tmp = a[i]; a[i] = a[j]; a[j] = tmp;
    }
    return a;
}

function freshMock() {
    const mock = createMockFabric();
    Object.assign(globalThis, mock.fabric); // install __fabric_* onto the global JSI surface
    return mock;
}

// ============================================================================
// MEASUREMENT ENGINE
// ============================================================================
function percentile(sorted, p) {
    if (sorted.length === 0) return 0;
    const idx = Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1);
    return sorted[Math.max(0, idx)];
}

// runScenario: do `warmup` unmeasured iters (JIT warm-up), then `runs` measured iters split into
// `batches` equal sub-batches. Each iteration runs setupFn() (UNtimed) then times exactly opFn(ctx).
// We report the MEDIAN of the per-batch p50s for p50 (and likewise for the other stats). Taking the
// median across independent sub-batches rejects transient GC/scheduler spikes, so the reported
// figures — and thus the --baseline gate — are stable run-to-run on the same code, even on a loaded
// machine. (A single-pass p50 swings widely when a major GC lands mid-pass.)
function runScenario(name, setupFn, opFn, { runs, warmup, batches }) {
    // warm-up (untimed): lets V8 tier the hot functions up to optimized code.
    for (let i = 0; i < warmup; i++) {
        const ctx = setupFn();
        opFn(ctx);
    }
    const nBatches = Math.max(1, batches);
    const perBatch = Math.max(1, Math.floor(runs / nBatches));
    const batchStats = [];
    for (let b = 0; b < nBatches; b++) {
        const samples = new Array(perBatch);
        for (let i = 0; i < perBatch; i++) {
            const ctx = setupFn();
            const t0 = process.hrtime.bigint();
            opFn(ctx);
            const t1 = process.hrtime.bigint();
            samples[i] = Number(t1 - t0);
        }
        samples.sort((a, b2) => a - b2);
        const sum = samples.reduce((s, v) => s + v, 0);
        batchStats.push({
            min: samples[0],
            mean: sum / samples.length,
            p50: percentile(samples, 50),
            p95: percentile(samples, 95),
            p99: percentile(samples, 99),
        });
    }
    // median across batches for each statistic (robust central estimate)
    const med = (key) => {
        const vs = batchStats.map((s) => s[key]).sort((a, b2) => a - b2);
        return percentile(vs, 50);
    };
    return {
        name,
        runs: perBatch * nBatches,
        batches: nBatches,
        min: Math.min(...batchStats.map((s) => s.min)),
        mean: med('mean'),
        p50: med('p50'),
        p95: med('p95'),
        p99: med('p99'),
    };
}

// allocation proxy: gc, snapshot heapUsed, run `batch` ops, snapshot again → bytes/op.
// Returns null when run without --expose-gc.
function measureAlloc(setupFn, opFn, batch) {
    if (typeof global.gc !== 'function') return null;
    // settle, then take a clean baseline
    global.gc(); global.gc();
    const before = process.memoryUsage().heapUsed;
    for (let i = 0; i < batch; i++) {
        const ctx = setupFn();
        opFn(ctx);
    }
    const after = process.memoryUsage().heapUsed;
    const delta = after - before;
    return delta / batch; // bytes/op (a proxy — includes retained nNode trees for diff scenarios)
}

// ============================================================================
// SCENARIO DEFINITIONS
// ============================================================================
function buildScenarios(rows) {
    const ids = [];
    for (let i = 0; i < rows; i++) ids.push('r' + i);
    const reversed = ids.slice().reverse();
    const shuffled = shuffleSeeded(ids);

    // ---- 1. COLD RENDER ------------------------------------------------------
    // Fresh mock per measured iteration so every run is a TRUE cold build (no handle/log
    // carry-over that would skew heap/GC numbers). We rebuild the keyed vtree too because
    // render mutates nothing on the vnode that would corrupt it, but a fresh tree keeps the
    // alloc proxy honest.
    const coldRender = {
        name: 'coldRender',
        desc: `cold render of keyed(${rows}) from scratch`,
        setup: () => {
            freshMock();
            return { tree: keyed(ids) };
        },
        op: (ctx) => { native._Native_render(ctx.tree, ev); },
    };

    // ---- 2. WARM DIFF --------------------------------------------------------
    // Render once (untimed in setup), then time a single-leaf-text-changed re-diff. We diff
    // back and forth between two stable trees (A↔B) so the op is repeatable against the SAME
    // nNode without re-rendering each iteration. nNode is mutated in place by the walker.
    const warmDiff = (() => {
        // one persistent mock + nNode for this scenario; toggle a single leaf's text.
        let mock, nNode, xV, yV, flip;
        const treeA = keyed(ids);
        // treeB differs only in the last row's text (single targeted updateProps).
        const idsB = ids.slice(); idsB[idsB.length - 1] = ids[ids.length - 1] + '*';
        const treeB = keyed(idsB);
        return {
            name: 'warmDiff',
            desc: `warm diff of keyed(${rows}) with one leaf text changed`,
            setup: () => {
                if (!mock) {
                    mock = freshMock();
                    nNode = native._Native_render(treeA, ev);
                    xV = treeA; yV = treeB; flip = true;
                }
                // alternate direction so we always diff against the tree currently mounted.
                const from = flip ? xV : yV;
                const to = flip ? yV : xV;
                flip = !flip;
                return { from, to };
            },
            op: (ctx) => { nNode = native._Native_updateTNode(nNode, ctx.from, ctx.to, ev); },
        };
    })();

    // ---- 3. FULL REORDER -----------------------------------------------------
    // Render keyed(ids), then time keyed(ids) → keyed(shuffled) and back, exercising the LIS
    // move-minimization pass on every measured op. Diff back-and-forth on a persistent nNode.
    const fullReorder = (() => {
        let mock, nNode, flip;
        const treeStraight = keyed(ids);
        const treeShuffled = keyed(shuffled);
        return {
            name: 'fullReorder',
            desc: `full reorder of keyed(${rows}) (seeded shuffle, LIS move-min)`,
            setup: () => {
                if (!mock) {
                    mock = freshMock();
                    nNode = native._Native_render(treeStraight, ev);
                    flip = true;
                }
                const from = flip ? treeStraight : treeShuffled;
                const to = flip ? treeShuffled : treeStraight;
                flip = !flip;
                return { from, to };
            },
            op: (ctx) => { nNode = native._Native_updateTNode(nNode, ctx.from, ctx.to, ev); },
        };
    })();

    // ---- 4. LAZY-STABLE DIFF -------------------------------------------------
    // A tree with a lazy(renderSub, arg) subtree whose arg is UNCHANGED, plus a sibling whose
    // text DOES change. The walker must short-circuit the lazy subtree (NOT re-invoke renderSub)
    // while still updating the sibling. We assert renderSub call-count does not grow across the
    // measured loop — i.e. we are timing the FAST short-circuit path, not a re-force.
    const lazyStable = (() => {
        let mock, nNode, flip, subRenders = 0;
        // module-stable render fn — refs[0] is === across frames (the contract lazy relies on).
        const renderSub = (n) => {
            subRenders++;
            return node('RCTView', [node('RCTText', [vtext('sub=' + n)])]);
        };
        const STABLE_ARG = 'fixed';
        // Two trees: a sibling label that flips text, plus a lazy subtree with the SAME arg in both.
        const make = (label) => node('RCTView', [
            node('RCTText', [vtext(label)]),
            lazy(renderSub, STABLE_ARG),
        ]);
        const treeA = make('side=A');
        const treeB = make('side=B');
        let baselineRenders = -1;
        return {
            name: 'lazyStable',
            desc: 'lazy-stable diff (sibling changes, lazy arg unchanged → short-circuit)',
            setup: () => {
                if (!mock) {
                    mock = freshMock();
                    nNode = native._Native_render(treeA, ev);
                    flip = true;
                    baselineRenders = subRenders; // after the initial render
                }
                const from = flip ? treeA : treeB;
                const to = flip ? treeB : treeA;
                flip = !flip;
                return { from, to };
            },
            op: (ctx) => { nNode = native._Native_updateTNode(nNode, ctx.from, ctx.to, ev); },
            // exposed for the smoke assertion
            _renders: () => subRenders,
            _baseline: () => baselineRenders,
        };
    })();

    // ---- 5. SCALAR FAST PATH (AND-8) -----------------------------------------
    // A single lone-text label whose text flips A↔B every frame — the dominant per-frame mutation
    // a counter/clock/score app makes. The walker must route this through __fabric_updatePropScalar
    // (no object alloc, no JSON.stringify/parse + host JSONObject decode), NOT __fabric_updateProps.
    // We time it AND record the call-path counters on the mock so the CI guard can assert the JSON
    // tax was actually eliminated (scalarProps grows, jsonProps does not) — not merely relabelled.
    const scalarFastPath = (() => {
        let mock, nNode, flip;
        const label = (s) => node('RCTView', [vtext(s)]); // lone-text node → text fast path
        const treeA = label('Count: 0');
        const treeB = label('Count: 1');
        return {
            name: 'scalarFastPath',
            desc: 'single-leaf text update via __fabric_updatePropScalar (AND-8 fast path)',
            setup: () => {
                if (!mock) {
                    mock = freshMock();
                    nNode = native._Native_render(treeA, ev);
                    flip = true;
                    mock.resetCounts(); // ignore the create-time props in the path counters
                }
                const from = flip ? treeA : treeB;
                const to = flip ? treeB : treeA;
                flip = !flip;
                return { from, to };
            },
            op: (ctx) => { nNode = native._Native_updateTNode(nNode, ctx.from, ctx.to, ev); },
            _counts: () => mock && mock.counts,
        };
    })();

    return { coldRender, warmDiff, fullReorder, lazyStable, scalarFastPath, ids };
}

// ============================================================================
// SMOKE ASSERTIONS — fail loudly if the walker wiring is broken (so we never
// silently time a no-op). Mirrors run-keyed.js's correctness reads.
// ============================================================================
function smokeTest(rows) {
    const ids = [];
    for (let i = 0; i < rows; i++) ids.push('s' + i);
    const mock = freshMock();
    const nNode = native._Native_render(keyed(ids), ev);
    const textRows = mock.findByTag('RCTText').length;
    if (textRows !== rows) {
        throw new Error(`SMOKE FAIL: cold render produced ${textRows} RCTText rows, expected ${rows} ` +
            `— the walker is not wired to the mock Fabric correctly.`);
    }
    // diff to a single changed leaf and assert exactly one updateProps fired.
    const idsB = ids.slice(); idsB[0] = ids[0] + 'X';
    mock.clearLog();
    native._Native_updateTNode(nNode, keyed(ids), keyed(idsB), ev);
    const updates = mock.log.filter((m) => m.op === 'updateProps').length;
    if (updates !== 1) {
        throw new Error(`SMOKE FAIL: single-leaf diff produced ${updates} updateProps, expected 1 ` +
            `— the targeted-update fast path is broken.`);
    }
    return { textRows, updates };
}

// ============================================================================
// AND-8 SCALAR FAST-PATH ASSERTIONS — the device-free correctness guard for the
// single-scalar reroute. Proves the dominant per-frame mutations take the no-JSON
// __fabric_updatePropScalar seam, while every shape that MUST stay on the JSON path
// (multi-key delta, a removal/null, a style key other than opacity, an event change)
// still goes through __fabric_updateProps. These are the two correctness traps AND-8
// calls out (opacity-is-a-style-key; null-stays-JSON), asserted directly.
// ============================================================================
function scalarPathAssertions() {
    const T2 = native.tags;
    const vtext2 = (s) => ({ $: T2.TEXT, __text: s });
    // facts-carrying node builder: __facts can hold a__1_STYLE / plain props per-frame.
    const fnode = (facts, kids) => ({ $: T2.NODE, __tag: 'RCTView', __facts: facts, __kids: kids, __namespace: undefined });
    const labelFacts = (facts, txt) => fnode(facts, [vtext2(txt)]);

    const cases = [];
    function one(name, buildOld, buildNew, expect) {
        const mock = freshMock();
        const oldV = buildOld();
        const nNode = native._Native_render(oldV, ev);
        mock.resetCounts();
        mock.clearLog();
        native._Native_updateTNode(nNode, oldV, buildNew(), ev);
        const c = mock.counts;
        const ok = c.scalarProps === expect.scalar && c.jsonProps === expect.json;
        cases.push({ name, ok, got: { scalar: c.scalarProps, json: c.jsonProps }, expect });
        return ok;
    }

    // (1) pure text change on a lone-text node → ONE scalar, ZERO json.
    one('text-only change → scalar path',
        () => labelFacts({}, 'a'), () => labelFacts({}, 'b'),
        { scalar: 1, json: 0 });

    // (2) opacity-only style change (non-null scalar) → ONE scalar, ZERO json (opacity nests in style).
    one('opacity-only style change → scalar path',
        () => labelFacts({ 'a__1_STYLE': { opacity: '1' } }, 'x'),
        () => labelFacts({ 'a__1_STYLE': { opacity: '0.5' } }, 'x'),
        { scalar: 1, json: 0 });

    // (2b) a lone `text` PLAIN-prop change on a NON-lone-text node → routed by _Native_soleScalarDelta
    // INSIDE diffApplyFacts (not the call-site lone-text branch), proving the facts-diff fast path.
    const kids2 = (facts) => fnode(facts, [vtext2('k0'), vtext2('k1')]);
    one('lone text plain-prop change (via diffApplyFacts) → scalar path',
        () => kids2({ text: 'a' }), () => kids2({ text: 'b' }),
        { scalar: 1, json: 0 });

    // (3) two plain props changing together in ONE diffApplyFacts delta (multi-key) → JSON path.
    // (Uses a NON-lone-text node so `text` rides diffApplyFacts as a plain prop, bundled with
    // `value` — the genuine "delta has >1 key" case the fast path must decline. A lone-text node
    // is intentionally different: its text is split out at the call site and always scalars,
    // independent of any sibling facts change — see _Native_updateTNode's lone-text branch.)
    const twoKids = (facts) => fnode(facts, [vtext2('k0'), vtext2('k1')]);
    one('two plain props (text + value) in one delta → JSON fallback',
        () => twoKids({ text: 'a', value: 'v0' }),
        () => twoKids({ text: 'b', value: 'v1' }),
        { scalar: 0, json: 1 });

    // (4) opacity + another style key changing together → JSON path (style delta has >1 key).
    one('opacity + width together → JSON fallback',
        () => labelFacts({ 'a__1_STYLE': { opacity: '1', width: '10' } }, 'x'),
        () => labelFacts({ 'a__1_STYLE': { opacity: '0.5', width: '20' } }, 'x'),
        { scalar: 0, json: 1 });

    // (5) a plain-prop REMOVAL (null) MUST stay on the JSON path so the host's reset fires.
    one('plain-prop removal (null) → JSON fallback (host reset)',
        () => labelFacts({ source: 'img://a' }, 'x'),
        () => labelFacts({}, 'x'),
        { scalar: 0, json: 1 });

    // (6) an opacity REMOVAL (style key dropped → null) MUST stay on the JSON path (style reset).
    one('opacity removal (null) → JSON fallback (style reset)',
        () => labelFacts({ 'a__1_STYLE': { opacity: '0.5' } }, 'x'),
        () => labelFacts({ 'a__1_STYLE': {} }, 'x'),
        { scalar: 0, json: 1 });

    return cases;
}

// ============================================================================
// HERMES LANE (compile-only)
// ============================================================================
function hermesCompile() {
    const hermesc = process.env.CANOPY_HERMESC;
    const bundle = path.join(__dirname, '..', 'examples', 'counter', 'build', 'canopy.bundle.js');
    if (!hermesc) {
        return {
            ok: false,
            reason: 'CANOPY_HERMESC is not set. Point it at a hermesc binary, e.g.\n' +
                '  CANOPY_HERMESC=.../react-native/sdks/hermesc/linux64-bin/hermesc',
        };
    }
    if (!fs.existsSync(hermesc)) {
        return { ok: false, reason: `CANOPY_HERMESC points at a missing file: ${hermesc}` };
    }
    if (!fs.existsSync(bundle)) {
        return { ok: false, reason: `compiler bundle not found at ${bundle} ` +
            `(build examples/counter first).` };
    }
    const out = path.join(os.tmpdir(), 'canopy-bench-' + process.pid + '.hbc');
    try {
        // -emit-binary -O: optimized bytecode. Warnings about web globals (Promise/document/URL)
        // are expected and benign for a compile-only smoke.
        execFileSync(hermesc, ['-emit-binary', '-O', '-out=' + out, bundle],
            { stdio: ['ignore', 'ignore', 'ignore'] });
    } catch (e) {
        return { ok: false, reason: `hermesc exited non-zero: ${e.message}` };
    }
    if (!fs.existsSync(out) || fs.statSync(out).size === 0) {
        return { ok: false, reason: 'hermesc reported success but produced no .hbc' };
    }
    const size = fs.statSync(out).size;
    try { fs.unlinkSync(out); } catch (_) { /* best effort */ }
    return {
        ok: true,
        hbcBytes: size,
        note: 'Hermes-CPU timing requires a hermes VM runner or on-device run (RND-4); ' +
            'not available in this sandbox (compile-only here).',
    };
}

// ============================================================================
// OUTPUT
// ============================================================================
function fmtNs(ns) {
    if (ns >= 1e6) return (ns / 1e6).toFixed(3) + ' ms';
    if (ns >= 1e3) return (ns / 1e3).toFixed(2) + ' us';
    return ns.toFixed(0) + ' ns';
}

function printTable(results, allocs) {
    const head = ['scenario', 'p50', 'p95', 'p99', 'min', 'mean', 'bytes/op'];
    const rows = results.map((r) => {
        const alloc = allocs[r.name];
        return [
            r.name,
            fmtNs(r.p50), fmtNs(r.p95), fmtNs(r.p99),
            fmtNs(r.min), fmtNs(r.mean),
            alloc == null ? '—' : Math.round(alloc) + ' B',
        ];
    });
    const widths = head.map((h, i) => Math.max(h.length, ...rows.map((r) => r[i].length)));
    const fmtRow = (cells) => cells.map((c, i) => c.padEnd(widths[i])).join('  ');
    console.log('\n' + C.b(fmtRow(head)));
    console.log(C.dim(widths.map((w) => '-'.repeat(w)).join('  ')));
    for (const r of rows) console.log(fmtRow(r));
}

// ============================================================================
// MAIN
// ============================================================================
function main() {
    const args = parseArgs(process.argv);
    if (args.help) {
        console.log(`canopy/native CPU micro-bench (RND-3)

Usage: node [--expose-gc] bench.js [options]

  --runs, -K <n>        measured iterations per scenario (default 1000)
  --warmup <n>          unmeasured warm-up iterations (default 100)
  --batches <n>         split measured iters into n batches; report median p50 (default 5)
  --rows <n>            rows in the keyed list (default 200)
  --json                emit machine-readable JSON
  --baseline <path>     compare p50 vs baseline; exit 1 on >tolerance regression
  --update-baseline     (re)write the baseline file (default ${DEFAULT_BASELINE})
  --tolerance <f>       regression tolerance fraction (default 0.25 = 25%; use 0.10 on a quiet box)
  --hermes-compile      compile examples/counter bundle to .hbc via CANOPY_HERMESC (compile-only)
  --expose-gc           (node flag) enables the bytes/op allocation proxy

Baselines are MACHINE-DEPENDENT — re-record per CI machine class.`);
        return 0;
    }

    const human = !args.json;
    if (human) {
        console.log(C.b('canopy/native CPU micro-bench (RND-3)'));
        console.log(C.dim(`node ${process.version} · ${os.cpus()[0].model} · ` +
            `runs=${args.runs} warmup=${args.warmup} rows=${args.rows}` +
            (typeof global.gc === 'function' ? ' · alloc-proxy ON' : ' · alloc-proxy OFF (run with --expose-gc)')));
    }

    // ---- smoke ---------------------------------------------------------------
    const smoke = smokeTest(args.rows);
    if (human) {
        console.log('\n' + C.b('Smoke') + '  (walker wiring sanity)');
        console.log(`  ${C.g('✓')} cold render produced ${smoke.textRows} RCTText rows (== rows)`);
        console.log(`  ${C.g('✓')} single-leaf diff fired exactly ${smoke.updates} updateProps`);
    }

    // ---- build + run scenarios ----------------------------------------------
    const sc = buildScenarios(args.rows);
    const order = [sc.coldRender, sc.warmDiff, sc.fullReorder, sc.lazyStable, sc.scalarFastPath];
    const results = [];
    const allocs = {};
    for (const s of order) {
        const res = runScenario(s.name, s.setup, s.op, { runs: args.runs, warmup: args.warmup, batches: args.batches });
        results.push(res);
        // allocation proxy on a smaller fixed batch (heap math is noisier than CPU timing)
        allocs[s.name] = measureAlloc(s.setup, s.op, Math.min(args.runs, 1000));
    }

    // lazy short-circuit assertion: across the whole lazy-stable loop, renderSub must NOT have
    // been re-invoked (beyond the single initial render). If it was, we were timing a re-force,
    // not the short-circuit — the bench would be lying about the lazy fast path.
    const lazyOk = sc.lazyStable._renders() === sc.lazyStable._baseline();
    if (human) {
        console.log('\n' + C.b('Lazy short-circuit guard'));
        if (lazyOk) {
            console.log(`  ${C.g('✓')} renderSub NOT re-invoked across the lazy-stable loop ` +
                `(timed the short-circuit, not a re-force)`);
        } else {
            console.log(`  ${C.r('✗')} renderSub WAS re-invoked ` +
                `(${sc.lazyStable._renders() - sc.lazyStable._baseline()} extra) — lazy short-circuit broken`);
        }
    }

    // ---- AND-8 scalar fast-path guard ---------------------------------------
    // Two checks: (a) the structured assertions (text/opacity scalar vs multi-key/null JSON), and
    // (b) the timed scalarFastPath scenario's own call-path counters across the whole measured loop
    // (the dominant per-frame mutation must have taken the no-JSON seam, not updateProps).
    const scalarCases = scalarPathAssertions();
    const scalarAssertOk = scalarCases.every((c) => c.ok);
    const scCounts = sc.scalarFastPath._counts() || { scalarProps: 0, jsonProps: 0 };
    const scalarLoopOk = scCounts.scalarProps > 0 && scCounts.jsonProps === 0;
    const scalarOk = scalarAssertOk && scalarLoopOk;
    if (human) {
        console.log('\n' + C.b('AND-8 scalar fast-path guard'));
        for (const c of scalarCases) {
            const mark = c.ok ? C.g('✓') : C.r('✗');
            console.log(`  ${mark} ${c.name}` +
                (c.ok ? '' : `  — got scalar=${c.got.scalar}/json=${c.got.json}, ` +
                    `expected scalar=${c.expect.scalar}/json=${c.expect.json}`));
        }
        const mark = scalarLoopOk ? C.g('✓') : C.r('✗');
        console.log(`  ${mark} pure text-update loop took the scalar seam ` +
            `(scalarProps=${scCounts.scalarProps}, jsonProps=${scCounts.jsonProps}; ` +
            `JSON marshalling eliminated, not relabelled)`);
    }

    // ---- hermes lane ---------------------------------------------------------
    let hermes = null;
    if (args.hermesCompile) {
        hermes = hermesCompile();
        if (human) {
            console.log('\n' + C.b('Hermes lane') + '  (compile-only)');
            if (hermes.ok) {
                console.log(`  ${C.g('✓')} hermesc compiled the counter bundle → ${hermes.hbcBytes} byte .hbc`);
                console.log(`  ${C.dim('note: ' + hermes.note)}`);
            } else {
                console.log(`  ${C.r('✗')} ${hermes.reason}`);
            }
        }
    }

    // ---- human table ---------------------------------------------------------
    if (human) printTable(results, allocs);

    // ---- baseline gate -------------------------------------------------------
    const baselinePath = args.baseline || (args.updateBaseline ? DEFAULT_BASELINE : null);
    let gate = { checked: false, regressions: [] };

    if (args.updateBaseline) {
        const payload = {
            node: process.version,
            cpu: os.cpus()[0].model,
            recordedAt: new Date().toISOString(),
            rows: args.rows,
            runs: args.runs,
            tolerance: args.tolerance,
            note: 'p50/p95/p99 are MACHINE-DEPENDENT ns. The --baseline gate is RELATIVE ' +
                '(current p50 vs baseline p50, default 25% tolerance to absorb CI CPU jitter; ' +
                'use --tolerance 0.10 on a quiet box). Re-record per CI machine class.',
            scenarios: {},
        };
        for (const r of results) {
            payload.scenarios[r.name] = { p50: r.p50, p95: r.p95, p99: r.p99 };
        }
        fs.writeFileSync(baselinePath, JSON.stringify(payload, null, 2) + '\n');
        if (human) console.log('\n' + C.g(`baseline written → ${baselinePath}`));
    } else if (args.baseline) {
        if (!fs.existsSync(args.baseline)) {
            console.error(C.r(`baseline not found: ${args.baseline} (run --update-baseline first)`));
            return 1;
        }
        const base = JSON.parse(fs.readFileSync(args.baseline, 'utf8'));
        gate.checked = true;
        for (const r of results) {
            const b = base.scenarios && base.scenarios[r.name];
            if (!b) continue;
            const limit = b.p50 * (1 + args.tolerance);
            if (r.p50 > limit) {
                gate.regressions.push({
                    scenario: r.name,
                    baselineP50: b.p50,
                    currentP50: r.p50,
                    ratio: r.p50 / b.p50,
                });
            }
        }
        if (human) {
            console.log('\n' + C.b(`Baseline gate`) + C.dim(` (tolerance ${(args.tolerance * 100).toFixed(0)}%)`));
            for (const r of results) {
                const b = base.scenarios && base.scenarios[r.name];
                if (!b) { console.log(`  ${C.y('?')} ${r.name}: not in baseline`); continue; }
                const ratio = r.p50 / b.p50;
                const reg = gate.regressions.find((x) => x.scenario === r.name);
                const mark = reg ? C.r('✗') : C.g('✓');
                console.log(`  ${mark} ${r.name}: ${fmtNs(r.p50)} vs ${fmtNs(b.p50)} ` +
                    `(${(ratio * 100).toFixed(0)}% of baseline)`);
            }
        }
    }

    // ---- json output ---------------------------------------------------------
    if (args.json) {
        const out = {
            node: process.version,
            cpu: os.cpus()[0].model,
            config: { runs: args.runs, warmup: args.warmup, rows: args.rows, tolerance: args.tolerance },
            smoke,
            lazyShortCircuit: lazyOk,
            scalarFastPath: {
                pass: scalarOk,
                cases: scalarCases.map((c) => ({ name: c.name, ok: c.ok, got: c.got, expect: c.expect })),
                loop: { scalarProps: scCounts.scalarProps, jsonProps: scCounts.jsonProps },
            },
            scenarios: results.map((r) => ({
                name: r.name, p50: r.p50, p95: r.p95, p99: r.p99, min: r.min, mean: r.mean,
                bytesPerOp: allocs[r.name],
            })),
            hermes,
            baselineGate: gate.checked ? { regressions: gate.regressions, pass: gate.regressions.length === 0 } : null,
        };
        console.log(JSON.stringify(out, null, 2));
    }

    // ---- exit code -----------------------------------------------------------
    if (!lazyOk) {
        if (human) console.log('\n' + C.r('FAIL: lazy short-circuit guard tripped'));
        return 1;
    }
    if (!scalarOk) {
        if (human) console.log('\n' + C.r('FAIL: AND-8 scalar fast-path guard tripped ' +
            '(a scalar mutation took the JSON path, or a multi-key/null delta took the scalar path)'));
        return 1;
    }
    if (args.hermesCompile && hermes && !hermes.ok) {
        if (human) console.log('\n' + C.r('FAIL: hermesc compile lane failed'));
        return 1;
    }
    if (gate.checked && gate.regressions.length > 0) {
        if (human) {
            console.log('\n' + C.r(`FAIL: ${gate.regressions.length} scenario(s) regressed > ` +
                `${(args.tolerance * 100).toFixed(0)}%:`));
            for (const g of gate.regressions) {
                console.log(C.r(`  - ${g.scenario}: ${fmtNs(g.currentP50)} > baseline ` +
                    `${fmtNs(g.baselineP50)} (${(g.ratio * 100).toFixed(0)}%)`));
            }
        }
        return 1;
    }
    if (human) console.log('\n' + C.b('Result: ') + C.g('PASS'));
    return 0;
}

process.exit(main());
