#!/usr/bin/env node
// perf-report.js — RND-4: parse + report the on-device frame-metrics dump from perf-android.sh.
//
// scripts/perf-android.sh drives a scripted fling on a device, the host's Choreographer frame
// instrumentation (CanopyFrameMetrics) writes a JSON dump, and this prints the jank ledger and runs
// a RELATIVE regression gate — the device-side analogue of bench.js for the JS-CPU lane.
//
// THE HEADLINE METRIC is jank%: the fraction of frames during the fling that missed a vsync. A
// windowed list "scrolls at 60fps" iff that fraction is ~0 and p95 frame-time stays under the
// refresh interval (~16.67ms at 60Hz). We surface jank at 1x/2x/4x-refresh thresholds plus the
// frame-time percentiles the dump carries.
//
// EMULATOR CAVEAT (RND-4 "upper-bound-on-jank"): the dump itself carries a `caveat` string when it
// came from an emulator; we print it prominently and tag the abi, so a reader can never mistake an
// x86_64 emulator number for an arm64-device measurement. The gate is RELATIVE to a recorded
// baseline (per device/abi class), never an absolute "ms" threshold — for the same reason bench.js's
// gate is relative: only the SAME hardware's numbers are comparable.
//
// Usage:
//   node perf-report.js <dump.json>                         print the ledger
//   node perf-report.js <dump.json> --baseline <b.json>     fail (exit 1) on >tolerance regression
//   node perf-report.js <dump.json> --update-baseline <b>   (re)write the baseline from this dump
//   node perf-report.js --selftest                          device-free check of the parser+gate
//
// The --selftest path fabricates representative dumps (a smooth one and a janky one) and asserts the
// ledger fields + the gate verdict, so this tool is verifiable on a box with no device (this sandbox).

'use strict';

const fs = require('fs');
const path = require('path');

const C = {
  g: (s) => `\x1b[32m${s}\x1b[0m`,
  r: (s) => `\x1b[31m${s}\x1b[0m`,
  y: (s) => `\x1b[33m${s}\x1b[0m`,
  b: (s) => `\x1b[1m${s}\x1b[0m`,
  dim: (s) => `\x1b[2m${s}\x1b[0m`,
};

// Default regression tolerances. jank% is an ADDITIVE points budget (a fling that was 0% jank
// regressing to 5% is the signal; a *relative* multiple of ~0 is meaningless), while frame-time is
// a RELATIVE multiple (machine-dependent ns, same as bench.js). Chosen loose enough to absorb the
// real run-to-run noise of a scripted fling on shared/emulated hardware, tight enough to catch a
// genuine "the list now stutters" regression.
const DEFAULT_JANK_POINTS = 5;   // allow +5 percentage points of jank before failing
const DEFAULT_P95_TOL = 0.30;    // allow +30% p95 frame-time before failing

function parseArgs(argv) {
  const a = { dump: null, baseline: null, updateBaseline: null, selftest: false,
    jankPoints: DEFAULT_JANK_POINTS, p95Tol: DEFAULT_P95_TOL, json: false };
  for (let i = 2; i < argv.length; i++) {
    const t = argv[i];
    switch (t) {
      case '--baseline': a.baseline = argv[++i]; break;
      case '--update-baseline': a.updateBaseline = argv[++i]; break;
      case '--selftest': a.selftest = true; break;
      case '--jank-points': a.jankPoints = parseFloat(argv[++i]); break;
      case '--p95-tol': a.p95Tol = parseFloat(argv[++i]); break;
      case '--json': a.json = true; break;
      case '-h': case '--help': a.help = true; break;
      default:
        if (t.startsWith('-')) { console.error('unknown flag: ' + t); process.exit(2); }
        else a.dump = t;
    }
  }
  return a;
}

// Normalize a raw device dump into the ledger shape we report + gate on. Tolerant of missing fields
// (an old/partial dump) so the tool never throws on real-world input.
function toLedger(d) {
  const ctx = d.context || {};
  return {
    label: d.label || ctx.segment || 'fling',
    abi: ctx.abi || 'unknown',
    device: ctx.device || 'unknown',
    refreshHz: num(d.refreshHz, 60),
    frames: num(d.frames, 0),
    elapsedMs: num(ctx.elapsedMs, 0),
    effectiveFps: num(ctx.effectiveFps, 0),
    jankFrames: num(d.jankFrames, 0),
    jankFrames2x: num(d.jankFrames2x, 0),
    jankFrames4x: num(d.jankFrames4x, 0),
    jankPct: num(d.jankPct, 0),
    p50Ms: num(d.p50Ms, 0),
    p90Ms: num(d.p90Ms, 0),
    p95Ms: num(d.p95Ms, 0),
    p99Ms: num(d.p99Ms, 0),
    meanMs: num(d.meanMs, 0),
    maxMs: num(d.maxMs, 0),
    hostOps: ctx.hostOps != null ? num(ctx.hostOps, 0) : null,
    caveat: d.caveat || null,
  };
}

function num(v, dflt) { return typeof v === 'number' && isFinite(v) ? v : dflt; }

function isEmulatorAbi(abi) { return /x86/.test(String(abi)); }

function printLedger(L) {
  console.log('\n' + C.b('canopy/native frame instrumentation (RND-4)'));
  console.log(C.dim(`segment=${L.label} · device=${L.device} · abi=${L.abi} · ` +
    `${L.refreshHz}Hz · ${L.frames} frames over ${L.elapsedMs.toFixed(0)}ms ` +
    `(${L.effectiveFps.toFixed(1)} eff fps)`));

  const refreshMs = 1000 / L.refreshHz;
  const rows = [
    ['jank% (>1 vsync)', L.jankPct.toFixed(2) + ' %', `${L.jankFrames}/${L.frames} frames`],
    ['  severe (>2x)', '', `${L.jankFrames2x} frames`],
    ['  hitch  (>4x)', '', `${L.jankFrames4x} frames`],
    ['p50 frame', L.p50Ms.toFixed(2) + ' ms', smoothMark(L.p50Ms, refreshMs)],
    ['p90 frame', L.p90Ms.toFixed(2) + ' ms', smoothMark(L.p90Ms, refreshMs)],
    ['p95 frame', L.p95Ms.toFixed(2) + ' ms', smoothMark(L.p95Ms, refreshMs)],
    ['p99 frame', L.p99Ms.toFixed(2) + ' ms', smoothMark(L.p99Ms, refreshMs)],
    ['max frame', L.maxMs.toFixed(2) + ' ms', smoothMark(L.maxMs, refreshMs)],
    ['mean frame', L.meanMs.toFixed(2) + ' ms', ''],
  ];
  if (L.hostOps != null) rows.push(['host ops (window)', String(L.hostOps), '']);

  const w0 = Math.max(...rows.map((r) => r[0].length));
  const w1 = Math.max(...rows.map((r) => r[1].length));
  for (const [k, v, note] of rows) {
    console.log('  ' + k.padEnd(w0) + '  ' + v.padStart(w1) + (note ? '  ' + C.dim(note) : ''));
  }

  // Headline verdict.
  const smooth = L.jankPct < 1.0 && L.p95Ms <= refreshMs * 1.0;
  console.log('\n  ' + (smooth
    ? C.g('SMOOTH: <1% jank and p95 within one refresh — the fling holds 60fps')
    : C.y(`JANK: ${L.jankPct.toFixed(1)}% of frames missed a vsync (p95 ${L.p95Ms.toFixed(1)}ms vs ` +
        `${refreshMs.toFixed(1)}ms refresh)`)));

  if (isEmulatorAbi(L.abi)) {
    console.log('\n  ' + C.y('CAVEAT: ') + C.dim(L.caveat ||
      'x86_64 emulator — these timings are an UPPER BOUND on real-device jank, never a floor. ' +
      'Re-run on real arm64 hardware for shippable figures.'));
  }
}

function smoothMark(ms, refreshMs) {
  if (ms <= refreshMs) return C.dim('within refresh');
  if (ms <= refreshMs * 2) return C.dim('> 1 vsync');
  return C.dim('> 2 vsync');
}

// Relative regression gate. jank% is gated additively (points), frame-time relatively (multiple).
function gate(L, base, opts) {
  const regressions = [];
  const jankBudget = base.jankPct + opts.jankPoints;
  if (L.jankPct > jankBudget) {
    regressions.push({ metric: 'jankPct', baseline: base.jankPct, current: L.jankPct,
      budget: jankBudget, kind: 'points' });
  }
  if (base.p95Ms > 0) {
    const limit = base.p95Ms * (1 + opts.p95Tol);
    if (L.p95Ms > limit) {
      regressions.push({ metric: 'p95Ms', baseline: base.p95Ms, current: L.p95Ms,
        budget: limit, kind: 'relative' });
    }
  }
  return regressions;
}

function baselineFromLedger(L) {
  return {
    recordedAt: new Date().toISOString(),
    device: L.device, abi: L.abi, refreshHz: L.refreshHz,
    jankPct: L.jankPct, p50Ms: L.p50Ms, p95Ms: L.p95Ms, p99Ms: L.p99Ms,
    note: 'Frame-timing baselines are DEVICE/ABI-specific. jank% is gated additively (points), ' +
      'frame-time relatively. NEVER compare an emulator (x86) baseline to an arm64 device run.',
  };
}

// --- selftest: device-free proof the parser + gate work --------------------------------------
function makeDump({ frames, jankPct, p50, p95, p99, max, abi }) {
  return {
    label: 'list-fling', refreshHz: 60, frames,
    jankFrames: Math.round(frames * jankPct / 100),
    jankFrames2x: Math.round(frames * jankPct / 200),
    jankFrames4x: Math.round(frames * jankPct / 400),
    jankPct, p50Ms: p50, p90Ms: (p50 + p95) / 2, p95Ms: p95, p99Ms: p99,
    meanMs: p50, maxMs: max,
    caveat: abi && /x86/.test(abi)
      ? 'emulator/x86_64 frame timings are an UPPER BOUND on real-device jank' : null,
    context: { segment: 'list-fling', elapsedMs: frames * 16.7, effectiveFps: 59.4,
      abi: abi || 'arm64-v8a', device: 'selftest / api34', hostOps: 0 },
  };
}

function selftest() {
  let pass = true;
  const fail = (m) => { pass = false; console.log('  ' + C.r('✗ ') + m); };
  const ok = (m) => console.log('  ' + C.g('✓ ') + m);

  // 1. a smooth dump parses to ~0 jank and is judged SMOOTH by the gate vs itself.
  const smooth = toLedger(makeDump({ frames: 300, jankPct: 0.3, p50: 16.6, p95: 16.7, p99: 17.0, max: 18, abi: 'x86_64' }));
  if (smooth.frames === 300 && smooth.jankPct === 0.3 && smooth.p95Ms === 16.7) ok('smooth dump parses');
  else fail('smooth dump parse: ' + JSON.stringify(smooth));

  const baseSmooth = baselineFromLedger(smooth);
  const noReg = gate(smooth, baseSmooth, { jankPoints: DEFAULT_JANK_POINTS, p95Tol: DEFAULT_P95_TOL });
  if (noReg.length === 0) ok('identical dump passes the gate (no false positive)');
  else fail('gate flagged a no-op: ' + JSON.stringify(noReg));

  // 2. emulator caveat detected from the x86 abi.
  if (isEmulatorAbi(smooth.abi) && smooth.caveat) ok('emulator abi → upper-bound caveat present');
  else fail('emulator caveat missing');

  // 3. a janky regression (0.3% → 12% jank, p95 16.7 → 40ms) is FLAGGED.
  const janky = toLedger(makeDump({ frames: 300, jankPct: 12, p50: 18, p95: 40, p99: 70, max: 120, abi: 'x86_64' }));
  const reg = gate(janky, baseSmooth, { jankPoints: DEFAULT_JANK_POINTS, p95Tol: DEFAULT_P95_TOL });
  const flaggedJank = reg.some((r) => r.metric === 'jankPct');
  const flaggedP95 = reg.some((r) => r.metric === 'p95Ms');
  if (flaggedJank) ok('jank regression (12% > 0.3%+5pts budget) flagged');
  else fail('jank regression NOT flagged');
  if (flaggedP95) ok('p95 regression (40ms > 16.7ms*1.3 budget) flagged');
  else fail('p95 regression NOT flagged');

  // 4. a small wobble within budget is NOT flagged (no flake).
  const wobble = toLedger(makeDump({ frames: 300, jankPct: 2.0, p50: 16.8, p95: 19.0, p99: 22, max: 30, abi: 'arm64-v8a' }));
  const reg2 = gate(wobble, baseSmooth, { jankPoints: DEFAULT_JANK_POINTS, p95Tol: DEFAULT_P95_TOL });
  if (reg2.length === 0) ok('within-budget wobble not flagged (no flake)');
  else fail('within-budget wobble flagged: ' + JSON.stringify(reg2));

  // 5. tolerant of a partial/garbage dump (no throw, sane defaults).
  try {
    const partial = toLedger({ label: 'x' });
    if (partial.frames === 0 && partial.jankPct === 0) ok('partial dump tolerated (no throw)');
    else fail('partial dump produced odd values');
  } catch (e) { fail('partial dump threw: ' + e.message); }

  console.log('\n' + (pass ? C.g('selftest PASS') : C.r('selftest FAIL')));
  return pass ? 0 : 1;
}

function main() {
  const a = parseArgs(process.argv);
  if (a.help) {
    console.log('node perf-report.js <dump.json> [--baseline b.json] [--update-baseline b.json] ' +
      '[--jank-points N] [--p95-tol F] [--selftest] [--json]');
    return 0;
  }
  if (a.selftest) return selftest();
  if (!a.dump) { console.error('usage: perf-report.js <dump.json> [--baseline b.json] (or --selftest)'); return 2; }
  if (!fs.existsSync(a.dump)) { console.error('dump not found: ' + a.dump); return 1; }

  let raw;
  try { raw = JSON.parse(fs.readFileSync(a.dump, 'utf8')); }
  catch (e) { console.error('could not parse dump JSON: ' + e.message); return 1; }
  const L = toLedger(raw);

  if (a.json) { console.log(JSON.stringify(L, null, 2)); }
  else printLedger(L);

  if (a.updateBaseline) {
    fs.writeFileSync(a.updateBaseline, JSON.stringify(baselineFromLedger(L), null, 2) + '\n');
    console.log('\n' + C.g('baseline written → ' + a.updateBaseline));
    return 0;
  }

  if (a.baseline) {
    if (!fs.existsSync(a.baseline)) { console.error('baseline not found: ' + a.baseline); return 1; }
    const base = JSON.parse(fs.readFileSync(a.baseline, 'utf8'));
    if (isEmulatorAbi(L.abi) !== isEmulatorAbi(base.abi)) {
      console.log('\n' + C.y(`WARN: comparing across abi classes (run=${L.abi} vs baseline=${base.abi}) ` +
        `— emulator and device frame timings are NOT comparable.`));
    }
    const regressions = gate(L, base, { jankPoints: a.jankPoints, p95Tol: a.p95Tol });
    console.log('\n' + C.b('Baseline gate') +
      C.dim(` (jank +${a.jankPoints}pts, p95 +${(a.p95Tol * 100).toFixed(0)}%)`));
    if (regressions.length === 0) {
      console.log('  ' + C.g('✓ no regression vs baseline'));
      return 0;
    }
    for (const reg of regressions) {
      console.log('  ' + C.r('✗ ') + `${reg.metric}: ${fmt(reg.current)} > budget ${fmt(reg.budget)} ` +
        `(baseline ${fmt(reg.baseline)})`);
    }
    console.log('\n' + C.r(`FAIL: ${regressions.length} metric(s) regressed`));
    return 1;
  }
  return 0;
}

function fmt(v) { return (Math.round(v * 100) / 100).toString(); }

process.exit(main());
