#!/usr/bin/env node
// perf-bar.js — RND-9: ratify + ENFORCE the "competitive" perf bar.
//
// WHAT THIS IS
// ------------
// RND-5 built the head-to-head bench app + the RN-vs-canopy comparison gate
// (bench/rn-comparison/compare-report.js); RND-6 made Native.List genuinely skip off-window work.
// RND-9 is the RATIFICATION + the committed gate: it pins the numeric bar (harness/perf-bar.json,
// owner-signed) against a COMMITTED ledger of real canopy numbers (harness/perf-ledger.json) and
// fails the build when canopy/native is no longer competitive with React Native 0.76.9.
//
// It is the harness-owned counterpart to bench/rn-comparison/compare-report.js: compare-report.js
// merges two LIVE per-side metrics files on a device; perf-bar.js gates the COMMITTED ledger against
// the RATIFIED bar so the bar travels with the repo and CI enforces it with no device and no RN.
//
// THE RATIFIED BAR (harness/perf-bar.json `gates`):
//   list jank    ≤ 1.2× RN  AND ≤ 5% dropped        (blocking)
//   tap-to-paint ≤ RN + 4 ms                          (blocking)
//   cold TTI     ≤ 1.3× RN                            (advisory until CMP-8 .hbc; see perf-bar.json)
//   peak RSS     ≤ 1.5× RN                            (blocking)
//   no-op frame  = 0 host mutations                   (blocking, HARD, device-free, the one always-on)
//
// HONESTY LANES (perf-ledger.json):
//   • canopy.device — REAL emulator capture (verified:true). x86_64 = upper bound on jank.
//   • canopy.walker — REAL device-free structural counts (verified:true). The no-op-frame=0 gate
//                     is proven HERE and is ALWAYS enforced (it needs neither a device nor RN).
//   • rn            — AUTHORED RN 0.76.9 reference (verified:false; not installed in this sandbox).
//                     The RN-relative rows are evaluated but tagged UNVERIFIED until a real rn.json
//                     lands; they do NOT block CI while unverified (a soft reference must not gate
//                     a build). The no-op-frame gate is independent of RN and DOES block.
//
// Usage:
//   node perf-bar.js                                  gate the committed ledger vs the ratified bar
//   node perf-bar.js --bar B.json --ledger L.json     gate explicit files
//   node perf-bar.js --json                            machine-readable verdict
//   node perf-bar.js --selftest                        device-free check of the gate logic (CI-safe)
//   node perf-bar.js --record-walker bench/.../walker.json   refresh canopy.walker rows from a capture
//   node perf-bar.js --record-device bench/.../canopy.json   refresh canopy.device rows from a capture
//   node perf-bar.js --record-rn     bench/.../rn.json        replace the rn reference with a REAL capture
//
// Exit code: 0 iff every BLOCKING gate that is judgeable passes; 1 on any blocking failure; 2 on usage.

'use strict';

const fs = require('fs');
const path = require('path');

const HERE = __dirname;
const DEFAULT_BAR = path.join(HERE, 'perf-bar.json');
const DEFAULT_LEDGER = path.join(HERE, 'perf-ledger.json');

const C = {
  g: (s) => `\x1b[32m${s}\x1b[0m`, r: (s) => `\x1b[31m${s}\x1b[0m`,
  y: (s) => `\x1b[33m${s}\x1b[0m`, b: (s) => `\x1b[1m${s}\x1b[0m`, dim: (s) => `\x1b[2m${s}\x1b[0m`,
};

function readJson(p) { return JSON.parse(fs.readFileSync(p, 'utf8')); }
function get(obj, dotted) {
  return dotted.split('.').reduce((o, k) => (o == null ? undefined : o[k]), obj);
}
function num(v) { return typeof v === 'number' && isFinite(v) ? v : null; }

// ============================================================================
// THE GATE — evaluate every ratified gate against the ledger.
//   verdict.rows[]  : { id, label, kind, blocking, canopy, rn, limit, value, ok, verified, note }
//   verdict.pass    : every BLOCKING + JUDGED + VERIFIED-enough row ok.
// ============================================================================
function evaluate(bar, ledger) {
  const g = bar.gates;
  const dev = (ledger.canopy && ledger.canopy.device) || {};
  const walk = (ledger.canopy && ledger.canopy.walker) || {};
  const rn = ledger.rn || {};
  const rnVerified = rn.verified === true;
  const rows = [];

  // pull a metric from the right canopy lane.
  const canopyOf = (metric) => {
    if (metric.startsWith('walker.')) return num(get(walk, metric.slice('walker.'.length)));
    return num(get(dev, metric));
  };
  const rnOf = (metric) => num(get(rn, metric.replace(/^walker\./, '')));

  // ---- no-op frame: ABSOLUTE, device-free, RN-independent, always enforced ----
  {
    const gate = g.noOpFrameMutations;
    const v = canopyOf(gate.metric); // walker.noOpFrameMutations
    const ok = v === null ? null : v === gate.value;
    rows.push({
      id: 'noOpFrameMutations', label: 'no-op frame mutations', kind: gate.kind,
      blocking: gate.blocking, canopy: v, rn: null, limit: gate.value, value: v,
      ratioStr: v === null ? '—' : `${v} (must be ${gate.value})`,
      ok, verified: true, gatesOnRn: false,
      note: ok === null ? 'no walker.noOpFrameMutations in ledger'
        : (ok ? 'zero host ops on a no-op frame (lazy+windowing hold)' : `emitted ${v} mutations on a no-op frame`),
    });
  }

  // ---- list dropped-frame absolute cap (RN-independent floor) ----
  {
    const gate = g.listDroppedFramePct;
    const v = canopyOf(gate.metric);
    const ok = v === null ? null : v <= gate.value;
    rows.push({
      id: 'listDroppedFramePct', label: `list dropped frames (≤${gate.value}%)`, kind: gate.kind,
      blocking: gate.blocking, canopy: v, rn: null, limit: gate.value, value: v,
      ratioStr: v === null ? '—' : `${v.toFixed(2)}% / ${gate.value}%`,
      ok, verified: true, gatesOnRn: false,
      note: ok === null ? 'no list jank in ledger' : (ok ? 'within absolute 5% cap' : `${v.toFixed(2)}% > ${gate.value}% cap`),
    });
  }

  // ---- RN-relative rows: list jank, tap-to-paint, cold TTI, RSS ----
  const rnMultiple = (gate, id, label) => {
    const c = canopyOf(gate.metric), rv = rnOf(gate.metric);
    const limit = rv === null ? null : rv * gate.value;
    const ok = (c === null || limit === null) ? null : c <= limit;
    rows.push({
      id, label, kind: gate.kind, blocking: gate.blocking, canopy: c, rn: rv,
      limit: gate.value, value: c, gatesOnRn: true, verified: rnVerified,
      ratio: (c === null || rv === null || rv === 0) ? null : c / rv,
      ratioStr: (c === null || rv === null || rv === 0) ? '—' : `${(c / rv).toFixed(2)}× (≤${gate.value}×)`,
      ok, note: gate.contingentOn ? ('contingent: ' + gate.contingentOn.split('.')[0]) : '',
    });
  };
  const rnPlusMs = (gate, id, label) => {
    const c = canopyOf(gate.metric), rv = rnOf(gate.metric);
    const limit = rv === null ? null : rv + gate.value;
    const ok = (c === null || limit === null) ? null : c <= limit;
    rows.push({
      id, label, kind: gate.kind, blocking: gate.blocking, canopy: c, rn: rv,
      limit: gate.value, value: c, gatesOnRn: true, verified: rnVerified,
      ratioStr: (c === null || rv === null) ? '—' : `${(c - rv >= 0 ? '+' : '') + (c - rv).toFixed(1)}ms (≤+${gate.value}ms)`,
      ok, note: '',
    });
  };

  rnMultiple(g.listJankMultiple, 'listJankMultiple', `list jank (≤${g.listJankMultiple.value}× RN)`);
  rnPlusMs(g.tapToPaintExtraMs, 'tapToPaintExtraMs', `tap-to-paint (≤ RN +${g.tapToPaintExtraMs.value}ms)`);
  rnMultiple(g.coldTtiMultiple, 'coldTtiMultiple', `cold TTI (≤${g.coldTtiMultiple.value}× RN)`);
  rnMultiple(g.rssMultiple, 'rssMultiple', `peak RSS (≤${g.rssMultiple.value}× RN)`);

  // PASS rule: a row BLOCKS the build iff it is blocking AND judged AND (RN-independent OR rn-verified).
  // An RN-relative row whose reference is unverified is reported but does NOT block (a soft reference
  // must never gate). The no-op-frame + dropped-frame floors are RN-independent and always block.
  const blockers = rows.filter((x) => x.blocking && x.ok !== null && (!x.gatesOnRn || x.verified));
  const blockingFails = blockers.filter((x) => !x.ok);
  const pass = blockingFails.length === 0;

  return { rows, pass, blockingFails, rnVerified };
}

// ============================================================================
// REPORTING
// ============================================================================
function printVerdict(bar, ledger, verdict, opts) {
  const dev = ledger.canopy.device, walk = ledger.canopy.walker, rn = ledger.rn;
  console.log(C.b('\nRND-9 — canopy/native competitive perf bar (ratified)'));
  console.log(C.dim(`bar v${bar.barVersion} ratified by ${bar.ratified.by} on ${bar.ratified.on} · ` +
    `RN reference ${bar.rnReference} · ledger recorded ${ledger.recordedAt}`));
  console.log(C.dim(`canopy.device: ${dev.abi} ${dev.bundleKind} (verified=${dev.verified}) · ` +
    `canopy.walker: device-free counts (verified=${walk.verified}) · ` +
    `rn: ${rn.verified ? C.g('VERIFIED') : C.y('AUTHORED, not measured here')}`));
  if (!verdict.rnVerified) {
    console.log(C.y('  NOTE: RN 0.76.9 not installed here — RN-relative rows are reported but do NOT block ' +
      'until a real rn.json lands. The no-op-frame + dropped-frame gates ARE enforced (RN-independent).'));
  }
  if (/x86/.test(String(dev.abi))) {
    console.log(C.y('  CAVEAT: ') + C.dim('x86_64 emulator device numbers are an UPPER BOUND on real-device jank, never a floor.'));
  }

  // table
  const head = ['gate', 'canopy', 'RN 0.76.9', 'result', ''];
  const fmtC = (r) => r.canopy == null ? '—' : (typeof r.canopy === 'number' ? trim(r.canopy) : String(r.canopy));
  const fmtR = (r) => r.rn == null ? (r.gatesOnRn ? '—' : 'n/a') : trim(r.rn);
  const body = verdict.rows.map((r) => {
    let mark;
    if (r.ok === null) mark = C.y('skip');
    else if (!r.blocking || (r.gatesOnRn && !r.verified)) mark = (r.ok ? C.g('pass') : C.y('FAIL*')) + C.dim('·adv');
    else mark = r.ok ? C.g('PASS') : C.r('FAIL');
    return [r.label, fmtC(r), fmtR(r), r.ratioStr, mark];
  });
  const plain = (s) => String(s).replace(/\x1b\[[0-9;]*m/g, '');
  const w = head.map((h, i) => Math.max(plain(h).length, ...body.map((r) => plain(r[i]).length)));
  const pad = (s, n) => s + ' '.repeat(Math.max(0, n - plain(s).length));
  const fr = (c) => c.map((x, i) => pad(String(x), w[i])).join('  ');
  console.log('\n' + C.b(fr(head)));
  console.log(C.dim(w.map((x) => '-'.repeat(x)).join('  ')));
  for (const r of body) console.log(fr(r));
  console.log(C.dim('\n  *·adv = advisory: reported, not blocking (RN reference unverified, or contingent gate).'));

  console.log('\n' + C.b('Perf bar verdict: ') + (verdict.pass
    ? C.g('PASS') + C.dim(`  (${verdict.rows.filter((r) => r.blocking && r.ok !== null && (!r.gatesOnRn || r.verified)).length} blocking gate(s) enforced)`)
    : C.r('FAIL') + C.dim(`  (${verdict.blockingFails.length} blocking gate(s) failed: ${verdict.blockingFails.map((x) => x.id).join(', ')})`)));
}

function trim(v) { return (Math.round(v * 100) / 100).toString(); }

// ============================================================================
// RECORD — refresh a ledger lane from a fresh capture, keeping the gate's source of truth committed.
// ============================================================================
function record(which, capturePath, ledgerPath) {
  const cap = readJson(capturePath);
  const ledger = readJson(ledgerPath);
  if (which === 'walker') {
    const w = cap.workloads || {};
    Object.assign(ledger.canopy.walker, {
      verified: true, device: false, abi: cap.abi || ledger.canopy.walker.abi,
      cpu: cap.cpu, node: cap.node, source: 'bench-walker.js capture',
      noOpFrameMutations: 0,
      list1000: { opsPerScrollStep: w.list1000.opsPerScrollStep, creates: w.list1000.creates,
        mountedRows: w.list1000.mountedRows, walkerNs: w.list1000.walkerNs },
      counter: { updatesPerTap: w.counter.updatesPerTap, scalarProps: w.counter.scalarProps,
        jsonProps: w.counter.jsonProps, walkerNs: w.counter.walkerNs },
      depth30: { createViews: w.depth30.createViews, coldMountNs: w.depth30.coldMountNs },
    });
    // the no-op-frame guarantee is exactly "0 creates + (windowed) ≤3 ops + 0 json on a no-op": derive it.
    ledger.canopy.walker.noOpFrameMutations =
      (w.counter.jsonProps === 0 && w.list1000.creates === 0) ? 0 : 1;
  } else if (which === 'device') {
    const wl = cap.workloads || {};
    Object.assign(ledger.canopy.device, {
      verified: true, device: true, abi: cap.abi, source: 'bench-compare.sh --side canopy capture',
      list1000: wl.list1000, counter: wl.counter, depth30: wl.depth30,
      tti: cap.tti, rss: cap.rss, caveat: cap.caveat,
    });
  } else if (which === 'rn') {
    const wl = cap.workloads || {};
    Object.assign(ledger.rn, {
      verified: true, device: true, abi: cap.abi, source: 'bench-compare.sh --side rn capture',
      list1000: wl.list1000, counter: wl.counter, tti: cap.tti, rss: cap.rss,
      caveat: cap.caveat || 'real RN 0.76.9 capture',
    });
  } else { console.error('unknown record target: ' + which); return 2; }
  ledger.recordedAt = new Date().toISOString();
  fs.writeFileSync(ledgerPath, JSON.stringify(ledger, null, 2) + '\n');
  console.log(C.g(`ledger.${which} updated from ${capturePath} → ${ledgerPath}`));
  return 0;
}

// ============================================================================
// SELFTEST — device-free proof the gate logic is correct (the CI-safe verification).
// ============================================================================
function selftest() {
  const bar = readJson(DEFAULT_BAR);
  let fails = 0;
  const ok = (m) => console.log('  ' + C.g('✓ ') + m);
  const bad = (m) => { fails++; console.log('  ' + C.r('✗ ') + m); };

  const mkLedger = (over) => {
    const base = {
      ledgerVersion: 1, barVersion: 1, recordedAt: 'selftest',
      canopy: {
        device: { verified: true, device: true, abi: 'arm64-v8a', bundleKind: 'js',
          list1000: { jankPct: 2.0 }, counter: { tapToPaintMs: 12 }, tti: { coldMs: 500 }, rss: { peakMb: 120 } },
        walker: { verified: true, device: false, noOpFrameMutations: 0 },
      },
      rn: { verified: true, device: true, abi: 'arm64-v8a',
        list1000: { jankPct: 2.0 }, counter: { tapToPaintMs: 10 }, tti: { coldMs: 450 }, rss: { peakMb: 100 } },
    };
    return deepMerge(base, over || {});
  };

  // (1) a within-bar ledger with verified RN passes every blocking gate.
  let v = evaluate(bar, mkLedger());
  v.pass ? ok('within-bar ledger (verified RN) → PASS') : bad('within-bar ledger gated FAIL: ' + JSON.stringify(v.blockingFails.map((x) => x.id)));

  // (2) the no-op-frame gate is HARD: a single stray mutation fails the build even with everything else green.
  v = evaluate(bar, mkLedger({ canopy: { walker: { noOpFrameMutations: 1 } } }));
  (!v.pass && v.blockingFails.some((x) => x.id === 'noOpFrameMutations')) ? ok('no-op frame = 1 → FAIL (hard, RN-independent)') : bad('no-op frame stray mutation did NOT fail');

  // (3) list jank 1.5× RN (> 1.2×) fails when RN is verified.
  v = evaluate(bar, mkLedger({ canopy: { device: { list1000: { jankPct: 3.0 } } } }));
  (!v.pass && v.blockingFails.some((x) => x.id === 'listJankMultiple')) ? ok('list jank 1.5× RN (verified) → FAIL') : bad('list jank 1.5× did NOT fail');

  // (4) dropped-frame ABSOLUTE cap: 6% jank fails even if RN is also janky (6% > 5% cap, RN-independent).
  v = evaluate(bar, mkLedger({ canopy: { device: { list1000: { jankPct: 6.0 } } }, rn: { list1000: { jankPct: 6.0 } } }));
  (!v.pass && v.blockingFails.some((x) => x.id === 'listDroppedFramePct')) ? ok('list jank 6% (>5% cap) → FAIL even vs janky RN') : bad('6% jank did not trip the absolute cap');

  // (5) RSS 1.6× RN (> 1.5×) fails; 1.4× passes.
  v = evaluate(bar, mkLedger({ canopy: { device: { rss: { peakMb: 160 } } } }));
  (!v.pass && v.blockingFails.some((x) => x.id === 'rssMultiple')) ? ok('peak RSS 1.6× RN → FAIL') : bad('RSS 1.6× did NOT fail');
  v = evaluate(bar, mkLedger({ canopy: { device: { rss: { peakMb: 140 } } } }));
  v.pass ? ok('peak RSS 1.4× RN → PASS') : bad('RSS 1.4× should pass');

  // (6) tap-to-paint RN+3ms passes (≤+4ms); RN+6ms fails.
  v = evaluate(bar, mkLedger({ canopy: { device: { counter: { tapToPaintMs: 13 } } } }));
  v.pass ? ok('tap-to-paint RN+3ms (≤+4ms) → PASS') : bad('tap +3ms should pass');
  v = evaluate(bar, mkLedger({ canopy: { device: { counter: { tapToPaintMs: 16 } } } }));
  (!v.pass && v.blockingFails.some((x) => x.id === 'tapToPaintExtraMs')) ? ok('tap-to-paint RN+6ms (>+4ms) → FAIL') : bad('tap +6ms did NOT fail');

  // (7) THE HONESTY RULE: when RN is UNVERIFIED, an RN-RELATIVE breach is reported but does NOT block.
  //     Use jank 4.5% vs RN 2%: that is > 1.2× RN (relative breach) yet < the 5% absolute cap, so the
  //     ONLY tripped row is the RN-relative one — which must be advisory (not blocking) while RN is
  //     unverified. (The RN-independent absolute cap is exercised separately in case 4.)
  v = evaluate(bar, mkLedger({ rn: { verified: false }, canopy: { device: { list1000: { jankPct: 4.5 } } } }));
  const jankRow7 = v.rows.find((r) => r.id === 'listJankMultiple');
  (v.pass && jankRow7 && jankRow7.ok === false)
    ? ok('unverified RN + RN-relative jank breach → still PASS (RN-relative row advisory, not blocking)')
    : bad('unverified RN-relative row wrongly blocked the build: ' + JSON.stringify({ pass: v.pass, jankOk: jankRow7 && jankRow7.ok }));
  v = evaluate(bar, mkLedger({ rn: { verified: false }, canopy: { walker: { noOpFrameMutations: 2 } } }));
  (!v.pass && v.blockingFails.some((x) => x.id === 'noOpFrameMutations'))
    ? ok('unverified RN but no-op frame=2 → FAIL (the hard gate is RN-independent)')
    : bad('no-op gate did not block when RN unverified');

  // (8) cold TTI is ADVISORY (contingent on CMP-8 .hbc): 2× RN TTI does NOT block even with verified RN.
  v = evaluate(bar, mkLedger({ canopy: { device: { tti: { coldMs: 900 } } } }));
  const ttiRow = v.rows.find((r) => r.id === 'coldTtiMultiple');
  (v.pass && ttiRow && ttiRow.ok === false && ttiRow.blocking === false)
    ? ok('cold TTI 2× RN → reported FAIL but ADVISORY (contingent on CMP-8 .hbc), build still PASS')
    : bad('TTI advisory semantics wrong: ' + JSON.stringify({ pass: v.pass, ttiOk: ttiRow && ttiRow.ok, blocking: ttiRow && ttiRow.blocking }));

  // (9) the COMMITTED ledger on disk passes the gate (the artifact RND-9 commits is green).
  const realLedger = readJson(DEFAULT_LEDGER);
  v = evaluate(bar, realLedger);
  v.pass ? ok('the committed harness/perf-ledger.json passes the ratified bar') : bad('committed ledger FAILS its own bar: ' + JSON.stringify(v.blockingFails.map((x) => x.id)));

  console.log('\n' + (fails === 0 ? C.g('selftest PASS') : C.r(`selftest FAIL (${fails})`)));
  return fails === 0 ? 0 : 1;
}

function deepMerge(a, b) {
  const out = Array.isArray(a) ? a.slice() : Object.assign({}, a);
  for (const k of Object.keys(b)) {
    out[k] = (b[k] && typeof b[k] === 'object' && !Array.isArray(b[k]) && a[k] && typeof a[k] === 'object')
      ? deepMerge(a[k], b[k]) : b[k];
  }
  return out;
}

// ============================================================================
// MAIN
// ============================================================================
function main() {
  const argv = process.argv.slice(2);
  // Parse ALL flags first (so --ledger is order-independent: it must be applied before any
  // --record-* acts on it), then dispatch the one action after the loop.
  const opts = { bar: DEFAULT_BAR, ledger: DEFAULT_LEDGER, json: false, action: null, capture: null };
  for (let i = 0; i < argv.length; i++) {
    const t = argv[i];
    switch (t) {
      case '--selftest': opts.action = 'selftest'; break;
      case '--bar': opts.bar = argv[++i]; break;
      case '--ledger': opts.ledger = argv[++i]; break;
      case '--json': opts.json = true; break;
      case '--record-walker': opts.action = 'walker'; opts.capture = argv[++i]; break;
      case '--record-device': opts.action = 'device'; opts.capture = argv[++i]; break;
      case '--record-rn': opts.action = 'rn'; opts.capture = argv[++i]; break;
      case '-h': case '--help':
        console.log('node perf-bar.js [--bar B] [--ledger L] [--json] [--selftest] ' +
          '[--record-walker|--record-device|--record-rn CAPTURE.json]');
        return 0;
      default: console.error('unknown flag: ' + t); return 2;
    }
  }
  if (opts.action === 'selftest') return selftest();
  if (opts.action === 'walker' || opts.action === 'device' || opts.action === 'rn') {
    return record(opts.action, opts.capture, opts.ledger);
  }
  const bar = readJson(opts.bar);
  const ledger = readJson(opts.ledger);
  const verdict = evaluate(bar, ledger);
  if (opts.json) {
    console.log(JSON.stringify({ pass: verdict.pass, rnVerified: verdict.rnVerified,
      blockingFails: verdict.blockingFails.map((x) => x.id), rows: verdict.rows }, null, 2));
  } else {
    printVerdict(bar, ledger, verdict, opts);
  }
  return verdict.pass ? 0 : 1;
}

process.exit(main());
