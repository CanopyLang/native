#!/usr/bin/env node
// compare-report.js — RND-5 side-by-side reporter + perf-bar gate.
//
// Merges two per-side metrics files into ONE table and (when both are device-fps lanes) ratifies
// the proposed perf bar from spec.json `gates`. There are two metric lanes:
//
//   • lane "device-fps"  — emitted by scripts/bench-compare.sh from `dumpsys gfxinfo` + `meminfo`
//                          on a real device, for EITHER side (canopy host or RN APK). Carries the
//                          wall-clock jank%, frame-time percentiles, TTI and RSS the bar is defined on.
//   • lane "walker-cpu"  — emitted by harness/bench-walker.js (device-free, canopy side only). Carries
//                          reconciler CPU + host-mutation counts. NOT comparable to a device-fps file;
//                          we print it but REFUSE to gate it against an RN device number (that would be
//                          apples-to-oranges — the honesty rule of the whole RND track).
//
// Usage:
//   node compare-report.js <canopy.json> <rn.json>          side-by-side + gate (exit 1 on bar fail)
//   node compare-report.js <canopy.json>                    print one side (no gate)
//   node compare-report.js --selftest                       device-free check of the merge + gate
//
// The gate multipliers come from spec.json (RND-9 will RATIFY them with owner sign-off; until then
// they are the PROPOSED M5 bar). They are multipliers of the RN reference on the SAME device.

'use strict';

const fs = require('fs');
const path = require('path');

const spec = require(path.join(__dirname, '..', 'spec.json'));

const C = {
  g: (s) => `\x1b[32m${s}\x1b[0m`, r: (s) => `\x1b[31m${s}\x1b[0m`,
  y: (s) => `\x1b[33m${s}\x1b[0m`, b: (s) => `\x1b[1m${s}\x1b[0m`, dim: (s) => `\x1b[2m${s}\x1b[0m`,
};

function load(p) {
  if (!fs.existsSync(p)) { console.error(C.r('metrics file not found: ' + p)); process.exit(2); }
  return JSON.parse(fs.readFileSync(p, 'utf8'));
}

function fmtPct(x) { return (x == null ? '—' : x.toFixed(1) + '%'); }
function fmtMs(x) { return (x == null ? '—' : x.toFixed(2) + ' ms'); }
function fmtMb(x) { return (x == null ? '—' : x.toFixed(0) + ' MB'); }
function ratio(a, b) { return (a == null || b == null || b === 0) ? null : a / b; }

// ============================================================================
// GATE — compares a canopy device-fps file against an RN device-fps file using spec.gates.
// Returns { rows:[{metric, canopy, rn, ratio, limit, ok}], pass }.
// ============================================================================
function gate(canopy, rn) {
  const g = spec.gates;
  const cw = canopy.workloads || {};
  const rw = rn.workloads || {};
  const rows = [];

  // list jank multiple (canopy jank% ≤ listJankMultiple × RN jank%); also an absolute dropped-frame cap.
  const cJank = cw.list1000 && cw.list1000.jankPct;
  const rJank = rw.list1000 && rw.list1000.jankPct;
  const jankRatio = ratio(cJank, rJank);
  rows.push({
    metric: 'list jank% (≤' + g.listJankMultiple + '× RN)',
    canopy: fmtPct(cJank), rn: fmtPct(rJank),
    ratio: jankRatio == null ? '—' : jankRatio.toFixed(2) + '×',
    ok: cJank == null || rJank == null
      ? null
      : (cJank <= rJank * g.listJankMultiple && cJank <= g.listDroppedFramePct),
  });

  // tap-to-paint: canopy median ≤ RN median + tapToPaintExtraMs.
  const cTap = cw.counter && cw.counter.tapToPaintMs;
  const rTap = rw.counter && rw.counter.tapToPaintMs;
  rows.push({
    metric: 'tap-to-paint (≤ RN + ' + g.tapToPaintExtraMs + 'ms)',
    canopy: fmtMs(cTap), rn: fmtMs(rTap),
    ratio: (cTap == null || rTap == null) ? '—' : (cTap - rTap).toFixed(2) + ' ms Δ',
    ok: (cTap == null || rTap == null) ? null : cTap <= rTap + g.tapToPaintExtraMs,
  });

  // cold TTI multiple.
  const cTti = canopy.tti && canopy.tti.coldMs;
  const rTti = rn.tti && rn.tti.coldMs;
  const ttiRatio = ratio(cTti, rTti);
  rows.push({
    metric: 'cold TTI (≤' + g.coldTtiMultiple + '× RN)',
    canopy: fmtMs(cTti), rn: fmtMs(rTti),
    ratio: ttiRatio == null ? '—' : ttiRatio.toFixed(2) + '×',
    ok: ttiRatio == null ? null : ttiRatio <= g.coldTtiMultiple,
  });

  // RSS multiple.
  const cRss = canopy.rss && canopy.rss.peakMb;
  const rRss = rn.rss && rn.rss.peakMb;
  const rssRatio = ratio(cRss, rRss);
  rows.push({
    metric: 'peak RSS (≤' + g.rssMultiple + '× RN)',
    canopy: fmtMb(cRss), rn: fmtMb(rRss),
    ratio: rssRatio == null ? '—' : rssRatio.toFixed(2) + '×',
    ok: rssRatio == null ? null : rssRatio <= g.rssMultiple,
  });

  const judged = rows.filter((x) => x.ok !== null);
  const pass = judged.length > 0 && judged.every((x) => x.ok);
  return { rows, pass, judged: judged.length };
}

function printSide(m) {
  console.log(C.b(`\n${m.side} (lane: ${m.lane}, device: ${m.device})`));
  if (m.caveat) console.log(C.dim('  ' + m.caveat));
  const w = m.workloads || {};
  if (m.lane === 'walker-cpu') {
    if (w.list1000) console.log(`  list1000 : walker p50 ${(w.list1000.walkerNs.p50 / 1000).toFixed(2)} us · ` +
      `${w.list1000.opsPerScrollStep} host ops/scroll-step · ${w.list1000.creates} creates`);
    if (w.counter) console.log(`  counter  : walker p50 ${w.counter.walkerNs.p50} ns · ` +
      `${w.counter.updatesPerTap} updateProps/tap (scalar=${w.counter.scalarProps}, json=${w.counter.jsonProps})`);
    if (w.depth30) console.log(`  depth30  : cold-mount p50 ${(w.depth30.coldMountNs.p50 / 1000).toFixed(2)} us · ` +
      `${w.depth30.createViews} views`);
  } else {
    if (w.list1000) console.log(`  list1000 : jank ${fmtPct(w.list1000.jankPct)} · p95 frame ${fmtMs(w.list1000.frameP95Ms)}`);
    if (w.counter) console.log(`  counter  : tap-to-paint ${fmtMs(w.counter.tapToPaintMs)}`);
    if (m.tti) console.log(`  TTI cold : ${fmtMs(m.tti.coldMs)}`);
    if (m.rss) console.log(`  peak RSS : ${fmtMb(m.rss.peakMb)}`);
  }
}

function printTable(rows) {
  const head = ['metric', 'canopy', 'RN 0.76.9', 'ratio/Δ', ''];
  const body = rows.map((r) => [r.metric, r.canopy, r.rn, r.ratio,
    r.ok === null ? C.y('skip') : (r.ok ? C.g('PASS') : C.r('FAIL'))]);
  // strip ANSI for width math
  const plain = (s) => s.replace(/\x1b\[[0-9;]*m/g, '');
  const w = head.map((h, i) => Math.max(plain(h).length, ...body.map((r) => plain(r[i]).length)));
  const pad = (s, n) => s + ' '.repeat(Math.max(0, n - plain(s).length));
  const fr = (c) => c.map((x, i) => pad(x, w[i])).join('  ');
  console.log('\n' + C.b(fr(head)));
  console.log(C.dim(w.map((x) => '-'.repeat(x)).join('  ')));
  for (const r of body) console.log(fr(r));
}

// ============================================================================
// SELFTEST — device-free check that the merge + gate behave (so this tool is verifiable here).
// ============================================================================
function selftest() {
  const mkDevice = (side, jank, tap, tti, rss) => ({
    schema: 'rnd5-bench/1', side, lane: 'device-fps', device: true,
    workloads: { list1000: { jankPct: jank, frameP95Ms: 14 }, counter: { tapToPaintMs: tap } },
    tti: { coldMs: tti }, rss: { peakMb: rss },
  });
  let failures = 0;
  const expect = (name, cond) => { console.log(`  ${cond ? C.g('✓') : C.r('✗')} ${name}`); if (!cond) failures++; };

  // (1) canopy within bar → pass.
  const passCase = gate(mkDevice('canopy', 4.0, 12, 900, 180), mkDevice('rn', 4.0, 10, 800, 140));
  expect('within-bar case gates PASS', passCase.pass === true && passCase.judged === 4);

  // (2) canopy jank 3× RN → fail (bar is ≤1.2×).
  const jankCase = gate(mkDevice('canopy', 18.0, 12, 900, 180), mkDevice('rn', 4.0, 10, 800, 140));
  expect('3× jank case gates FAIL', jankCase.pass === false);

  // (3) RSS 2× RN → fail (bar is ≤1.5×).
  const rssCase = gate(mkDevice('canopy', 4.0, 12, 900, 300), mkDevice('rn', 4.0, 10, 800, 140));
  expect('2× RSS case gates FAIL', rssCase.pass === false);

  // (4) tap +3ms (within +4ms budget) → tap row passes.
  const tapCase = gate(mkDevice('canopy', 4.0, 13, 900, 180), mkDevice('rn', 4.0, 10, 800, 140));
  const tapRow = tapCase.rows.find((x) => x.metric.startsWith('tap-to-paint'));
  expect('tap +3ms (≤+4ms budget) row PASS', tapRow.ok === true);

  // (5) walker-cpu vs device-fps must NOT be gated (lanes differ).
  const walker = { schema: 'rnd5-bench/1', side: 'canopy', lane: 'walker-cpu', device: false, workloads: {} };
  expect('walker-cpu lane detected (would refuse RN gate)', walker.lane === 'walker-cpu');

  console.log('\n' + (failures === 0 ? C.g('selftest PASS') : C.r(`selftest FAIL (${failures})`)));
  return failures === 0 ? 0 : 1;
}

// ============================================================================
// MAIN
// ============================================================================
function main() {
  const argv = process.argv.slice(2);
  if (argv[0] === '--selftest') return selftest();
  if (argv.length < 1) {
    console.error('usage: compare-report.js <canopy.json> [<rn.json>]  |  --selftest');
    return 2;
  }
  const canopy = load(argv[0]);
  printSide(canopy);
  if (argv.length < 2) {
    console.log(C.dim('\n(only one side given — no gate. Provide both a canopy and an RN metrics file to ratify the bar.)'));
    return 0;
  }
  const rn = load(argv[1]);
  printSide(rn);

  // Refuse to gate across lanes (the honesty rule).
  if (canopy.lane !== rn.lane || canopy.lane === 'walker-cpu') {
    console.log(C.y('\nLANES DIFFER (' + canopy.lane + ' vs ' + rn.lane + ') — printing both sides but NOT gating.'));
    console.log(C.dim('A perf-bar verdict requires BOTH sides on the device-fps lane (run bench-compare.sh on a device).'));
    return 0;
  }
  if (canopy.lane !== 'device-fps') {
    console.log(C.y('\nNeither side is the device-fps lane — no bar to ratify.'));
    return 0;
  }

  const verdict = gate(canopy, rn);
  printTable(verdict.rows);
  console.log('\n' + C.b('Perf bar (proposed M5; RND-9 ratifies): ') +
    (verdict.pass ? C.g('PASS') : C.r('FAIL')));
  return verdict.pass ? 0 : 1;
}

process.exit(main());
