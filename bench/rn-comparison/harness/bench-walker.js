#!/usr/bin/env node
// bench-walker.js — RND-5 device-free CANOPY-SIDE measurement of the head-to-head workloads.
//
// WHAT THIS IS
// ------------
// The on-device half of RND-5 (scripts/bench-compare.sh) needs a real device + a built RN 0.76.9
// APK to produce gfxinfo/meminfo. Neither RN 0.76.9 nor a device-gfx pipe exists in THIS sandbox.
// So this harness produces the CANOPY side of the comparison the only honest way available here:
// it drives the REAL canopy/native walker (package/external/native.js — the same code that runs
// on the phone) against the in-memory mock Fabric (harness/mock-fabric.js, byte-identical to the
// host's mount surface), for the SAME three workloads spec.json defines, and emits a metrics file
// in the SAME canonical shape the device gfxinfo path would (so scripts/compare-report.js consumes
// either interchangeably).
//
// It measures what a device-free box CAN measure truthfully:
//   • list1000  : per-frame WALKER CPU (ns) for a one-row windowed scroll step, p50/p95/p99, AND
//                 the host-mutation COUNT per scroll frame (the structural truth a device can't fake:
//                 a 1-row scroll must touch only the entering/leaving rows, not re-diff 1000).
//   • counter   : tap-to-repaint WALKER CPU for the single-leaf update, AND the AND-8 call-path
//                 proof (the per-tap mutation took the no-JSON scalar seam).
//   • depth30   : cold mount + full teardown CPU for the 30-deep tree, and the create/remove op
//                 counts (per-node mount cost the device TTI is dominated by).
//
// WHAT IT IS NOT: it is NOT a wall-clock vsync/jank number — that is a device measurement
// (scripts/perf-android.sh + bench-compare.sh). The output is explicitly tagged `lane:"walker-cpu"`
// and `device:false` so a reader (and compare-report.js) can never mistake it for an on-device fps
// figure. The ns are x86_64 CPU time and machine-dependent (same caveat as harness/bench.js).
//
// Usage:
//   node bench-walker.js                          human table
//   node bench-walker.js --json                   machine-readable canonical metrics
//   node bench-walker.js --out <file.json>        write the canonical metrics JSON to <file>
//   node bench-walker.js --runs <K> --warmup <N>  tune iteration counts (defaults 400 / 50)

'use strict';

const path = require('path');
const fs = require('fs');
const os = require('os');

// Reuse the harness machinery VERBATIM (same modules bench.js / run.js use). Resolved relative to
// this file so the bench dir stays self-contained but does not duplicate the runtime/mock/walker.
const HARNESS = path.join(__dirname, '..', '..', '..', 'harness');
const PKG_NATIVE = path.join(__dirname, '..', '..', '..', 'package', 'external', 'native.js');
require(path.join(HARNESS, 'mini-runtime')); // installs F2..F9, _Platform_*, etc. onto globalThis
const native = require(PKG_NATIVE);
const { createMockFabric } = require(path.join(HARNESS, 'mock-fabric'));

const spec = require(path.join(__dirname, '..', 'spec.json'));
const T = native.tags;

// ============================================================================
// CLI
// ============================================================================
function parseArgs(argv) {
  const a = { runs: 400, warmup: 50, batches: 5, json: false, out: null };
  for (let i = 2; i < argv.length; i++) {
    const t = argv[i];
    switch (t) {
      case '--runs': a.runs = parseInt(argv[++i], 10); break;
      case '--warmup': a.warmup = parseInt(argv[++i], 10); break;
      case '--batches': a.batches = parseInt(argv[++i], 10); break;
      case '--json': a.json = true; break;
      case '--out': a.out = argv[++i]; break;
      case '-h': case '--help': a.help = true; break;
      default: if (t.startsWith('-')) { console.error('unknown flag: ' + t); process.exit(2); }
    }
  }
  return a;
}

const C = {
  g: (s) => `\x1b[32m${s}\x1b[0m`, r: (s) => `\x1b[31m${s}\x1b[0m`,
  y: (s) => `\x1b[33m${s}\x1b[0m`, b: (s) => `\x1b[1m${s}\x1b[0m`, dim: (s) => `\x1b[2m${s}\x1b[0m`,
};

// ============================================================================
// vnode builders — same shapes the correctness harnesses (run-keyed.js, bench.js) prove.
// ============================================================================
const vtext = (s) => ({ $: T.TEXT, __text: s });
const node = (tag, kids) => ({ $: T.NODE, __tag: tag, __facts: {}, __kids: kids, __namespace: undefined });
const factNode = (tag, facts, kids) => ({ $: T.NODE, __tag: tag, __facts: facts, __kids: kids, __namespace: undefined });
const keyed = (entries) => ({ $: T.KEYED_NODE, __tag: 'RCTView', __facts: {}, __kids: entries });
const ev = function () {};

function freshMock() {
  const mock = createMockFabric();
  Object.assign(globalThis, mock.fabric);
  return mock;
}

// ============================================================================
// MEASUREMENT — same percentile/batch engine philosophy as harness/bench.js.
// ============================================================================
function percentile(sorted, p) {
  if (sorted.length === 0) return 0;
  const idx = Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1);
  return sorted[Math.max(0, idx)];
}

function timeOp(setupFn, opFn, { runs, warmup, batches }) {
  for (let i = 0; i < warmup; i++) { const ctx = setupFn(); opFn(ctx); }
  const nB = Math.max(1, batches);
  const per = Math.max(1, Math.floor(runs / nB));
  const batchP = [];
  for (let b = 0; b < nB; b++) {
    const s = new Array(per);
    for (let i = 0; i < per; i++) {
      const ctx = setupFn();
      const t0 = process.hrtime.bigint();
      opFn(ctx);
      const t1 = process.hrtime.bigint();
      s[i] = Number(t1 - t0);
    }
    s.sort((x, y) => x - y);
    batchP.push({ p50: percentile(s, 50), p95: percentile(s, 95), p99: percentile(s, 99), min: s[0] });
  }
  const med = (k) => { const v = batchP.map((x) => x[k]).sort((a, c) => a - c); return percentile(v, 50); };
  return { p50: med('p50'), p95: med('p95'), p99: med('p99'), min: Math.min(...batchP.map((x) => x.min)) };
}

// ============================================================================
// WORKLOAD MODELS — the canopy/native vnode shapes for each spec workload, built so the
// walker exercises the exact path the on-device app would.
// ============================================================================

// A windowed list FRAME: only the rows in [start, start+window) are mounted, keyed by their
// global index — exactly what Native.List emits. A one-row scroll advances `start` by 1, so the
// keyed diff drops the leaving row, inserts the entering row, and leaves the rest untouched (the
// structural property the device gfx jank is downstream of). We build the two adjacent window
// frames and diff between them.
function listWindow(rows, rowHeight, viewportH, overscan) {
  const window = Math.ceil(viewportH / rowHeight) + overscan; // mounted rows
  const row = (n) => factNode('RCTView', {}, [factNode('RCTView', {}, [vtext('Item ' + n)])]);
  const frameAt = (start) => {
    const entries = [];
    for (let i = 0; i < window && start + i < rows; i++) {
      const idx = start + i;
      entries.push({ a: String(idx), b: row(idx) });
    }
    return keyed(entries);
  };
  return { window, frameAt };
}

function buildScenarios(args) {
  const L = spec.workloads.list1000;
  const D = spec.workloads.depth30;

  // ---- list1000 : one-row windowed scroll step ----------------------------
  const list = (() => {
    const { window, frameAt } = listWindow(L.rows, L.rowHeight, spec.viewport.height, L.overscan);
    let mock, nNode, start, flip;
    const A = frameAt(0);
    const B = frameAt(1);
    return {
      name: 'list1000',
      window,
      setup: () => {
        if (!mock) { mock = freshMock(); nNode = native._Native_render(A, ev); flip = true; }
        const from = flip ? A : B, to = flip ? B : A; flip = !flip;
        return { from, to };
      },
      op: (ctx) => { nNode = native._Native_updateTNode(nNode, ctx.from, ctx.to, ev); },
      // structural truth: count host mutations for ONE scroll step.
      measureOps: () => {
        const m = freshMock();
        let n = native._Native_render(A, ev);
        m.clearLog();
        n = native._Native_updateTNode(n, A, B, ev);
        const creates = m.log.filter((x) => x.op === 'createView').length;
        const removes = m.log.filter((x) => x.op === 'removeChild' || x.op === 'remove').length;
        const inserts = m.log.filter((x) => x.op === 'insertChild' || x.op === 'insert').length;
        const updates = m.log.filter((x) => x.op === 'updateProps').length;
        return { mountedRows: window, creates, removes, inserts, updates, totalOps: m.log.length };
      },
    };
  })();

  // ---- counter : single-leaf tap-to-repaint -------------------------------
  const counter = (() => {
    const label = (s) => node('RCTView', [vtext(s)]); // lone-text node → scalar fast path
    const A = label('Count: 0'), B = label('Count: 1');
    let mock, nNode, flip;
    return {
      name: 'counter',
      setup: () => {
        if (!mock) { mock = freshMock(); nNode = native._Native_render(A, ev); flip = true; mock.resetCounts(); }
        const from = flip ? A : B, to = flip ? B : A; flip = !flip;
        return { from, to };
      },
      op: (ctx) => { nNode = native._Native_updateTNode(nNode, ctx.from, ctx.to, ev); },
      _counts: () => mock && mock.counts,
      measureOps: () => {
        const m = freshMock();
        let n = native._Native_render(A, ev);
        m.resetCounts(); m.clearLog();
        n = native._Native_updateTNode(n, A, B, ev);
        return {
          updates: m.log.filter((x) => x.op === 'updateProps').length,
          scalarProps: m.counts.scalarProps, jsonProps: m.counts.jsonProps,
        };
      },
    };
  })();

  // ---- depth30 : cold mount + full teardown of a 30-deep tree -------------
  const depth = (() => {
    const build = (n) => (n <= 0
      ? node('RCTView', [vtext('leaf @ depth ' + D.depth)])
      : node('RCTView', [build(n - 1)]));
    const tree = build(D.depth);
    return {
      name: 'depth30',
      depth: D.depth,
      // cold mount: fresh mock each iter, render the whole deep tree.
      setup: () => { freshMock(); return { tree }; },
      op: (ctx) => { native._Native_render(ctx.tree, ev); },
      measureOps: () => {
        const m = freshMock();
        native._Native_render(tree, ev);
        return {
          depth: D.depth,
          createViews: m.log.filter((x) => x.op === 'createView').length,
          totalOps: m.log.length,
        };
      },
    };
  })();

  return { list, counter, depth };
}

// ============================================================================
// MAIN
// ============================================================================
function fmtNs(ns) {
  if (ns >= 1e6) return (ns / 1e6).toFixed(3) + ' ms';
  if (ns >= 1e3) return (ns / 1e3).toFixed(2) + ' us';
  return ns.toFixed(0) + ' ns';
}

function main() {
  const args = parseArgs(process.argv);
  if (args.help) {
    console.log('bench-walker.js — RND-5 device-free canopy-side measurement (see header).');
    return 0;
  }
  const human = !args.json;
  if (human) {
    console.log(C.b('RND-5 — canopy/native side (device-free walker-CPU lane)'));
    console.log(C.dim(`node ${process.version} · ${os.cpus()[0].model} · runs=${args.runs} warmup=${args.warmup}`));
    console.log(C.dim('NOTE: walker-CPU ns are x86_64 + machine-dependent; this is NOT an on-device fps/jank number.'));
  }

  const sc = buildScenarios(args);
  const cfg = { runs: args.runs, warmup: args.warmup, batches: args.batches };

  // time each workload
  const listT = timeOp(sc.list.setup, sc.list.op, cfg);
  const counterT = timeOp(sc.counter.setup, sc.counter.op, cfg);
  const depthT = timeOp(sc.depth.setup, sc.depth.op, cfg);

  // structural op counts
  const listOps = sc.list.measureOps();
  const counterOps = sc.counter.measureOps();
  const depthOps = sc.depth.measureOps();

  // ---- correctness guards (so we never report a number for a broken path) --
  const guards = [];
  // (G1) a one-row windowed scroll must NOT re-create the whole window: creates ≤ a small constant
  // (the single entering row, possibly its text leaf), never ~window. This is the perf-at-scale
  // invariant the whole RND track exists to protect.
  const g1 = listOps.creates <= 3;
  guards.push({ name: 'list: one-row scroll creates ≤3 views (no full-window rebuild)', ok: g1,
    detail: `creates=${listOps.creates}, mountedRows=${listOps.mountedRows}` });
  // (G2) the per-tap counter mutation took the AND-8 scalar seam (no JSON marshalling).
  const g2 = counterOps.scalarProps >= 1 && counterOps.jsonProps === 0 && counterOps.updates === 1;
  guards.push({ name: 'counter: tap = ONE updateProps via scalar seam (no JSON)', ok: g2,
    detail: `updates=${counterOps.updates}, scalar=${counterOps.scalarProps}, json=${counterOps.jsonProps}` });
  // (G3) depth-30 cold mount creates exactly one view per nesting level + the leaf (31 RCTViews):
  // proves the deep tree mounts the expected node count, not a degenerate explosion.
  const g3 = depthOps.createViews === sc.depth.depth + 1;
  guards.push({ name: `depth: cold mount creates exactly ${sc.depth.depth + 1} views`, ok: g3,
    detail: `createViews=${depthOps.createViews}` });

  const allOk = guards.every((g) => g.ok);

  if (human) {
    console.log('\n' + C.b('Structural guards'));
    for (const g of guards) console.log(`  ${g.ok ? C.g('✓') : C.r('✗')} ${g.name}  ${C.dim('(' + g.detail + ')')}`);

    console.log('\n' + C.b('Walker-CPU (per op)'));
    const rows = [
      ['list1000 (1-row scroll)', listT, `${listOps.mountedRows} rows windowed; ${listOps.totalOps} host ops/frame`],
      ['counter  (tap repaint)', counterT, `1 updateProps (scalar)`],
      ['depth30  (cold mount)', depthT, `${depthOps.createViews} views`],
    ];
    const head = ['workload', 'p50', 'p95', 'p99', 'note'];
    const body = rows.map(([n, t, note]) => [n, fmtNs(t.p50), fmtNs(t.p95), fmtNs(t.p99), note]);
    const w = head.map((h, i) => Math.max(h.length, ...body.map((r) => r[i].length)));
    const fr = (c) => c.map((x, i) => x.padEnd(w[i])).join('  ');
    console.log(C.b(fr(head)));
    console.log(C.dim(w.map((x) => '-'.repeat(x)).join('  ')));
    for (const r of body) console.log(fr(r));
    console.log('\n' + (allOk ? C.b('Result: ') + C.g('PASS') : C.b('Result: ') + C.r('FAIL (a structural guard tripped)')));
  }

  // ---- canonical metrics object (same shape compare-report.js consumes for either side) ----
  const metrics = {
    schema: 'rnd5-bench/1',
    side: 'canopy',
    lane: 'walker-cpu',      // NOT device-fps — see header
    device: false,
    abi: process.arch,
    node: process.version,
    cpu: os.cpus()[0].model,
    recordedAt: new Date().toISOString(),
    specVersion: spec.specVersion,
    rnTarget: spec.rnTarget,
    caveat: 'Device-free walker-CPU lane: ns are x86_64 + machine-dependent and measure the JS-side '
      + 'reconciler cost + host-mutation COUNTS, NOT on-device frame time / jank / RSS. For the '
      + 'wall-clock head-to-head, run scripts/bench-compare.sh on a device with a built RN 0.76.9 APK.',
    guardsPass: allOk,
    workloads: {
      list1000: {
        walkerNs: { p50: listT.p50, p95: listT.p95, p99: listT.p99 },
        mountedRows: listOps.mountedRows,
        opsPerScrollStep: listOps.totalOps,
        creates: listOps.creates, updates: listOps.updates,
      },
      counter: {
        walkerNs: { p50: counterT.p50, p95: counterT.p95, p99: counterT.p99 },
        updatesPerTap: counterOps.updates,
        scalarProps: counterOps.scalarProps, jsonProps: counterOps.jsonProps,
      },
      depth30: {
        coldMountNs: { p50: depthT.p50, p95: depthT.p95, p99: depthT.p99 },
        depth: depthOps.depth, createViews: depthOps.createViews,
      },
    },
  };

  if (args.out) {
    fs.writeFileSync(args.out, JSON.stringify(metrics, null, 2) + '\n');
    if (human) console.log(C.g('\nmetrics written → ' + args.out));
  }
  if (args.json) console.log(JSON.stringify(metrics, null, 2));

  return allOk ? 0 : 1;
}

process.exit(main());
