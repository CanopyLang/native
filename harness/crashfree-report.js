#!/usr/bin/env node
// crashfree-report.js — TEL-1 / REL-4: compute the crash-free-sessions metric from telemetry events.
//
// The crash floor (CanopyCrashFloor.{java,mm}) writes buildId-keyed records; the session beacon
// writes one `session-start` per process launch. This reporter turns those events into the honest
// crash-free-% the reliability claim rests on:
//
//     crash-free% (per platform+buildId) = 100 * (1 - distinct(sessionId with a fatal crash)
//                                                      / distinct(sessionId with a session-start))
//
// It is the DEVICE-FREE half: `--selftest` fabricates event sets and asserts the math (incl. that a
// multi-crash session is counted once, and that an emulator/simulator source forces the caveat), so
// the computation is gated on every CI run even before a real shipped-device denominator exists. Feed
// it real drained telemetry (from device-farm artifacts / an opt-in HTTP sink) for the headline number.
//
// Usage:
//   node crashfree-report.js <dir-or-ndjson>...        # report per platform+buildId
//   node crashfree-report.js --gate --floor 99.0 <in>  # exit 1 if any group is below the floor
//   node crashfree-report.js --selftest                # device-free proof of the computation
//
// Event schema (schema:2 — see docs/telemetry.md): a common envelope
//   { schema, eventType: "session-start"|"crash", platform, buildId, sessionId, timestampMs,
//     appVersion?, osVersion?, source?: "emulator"|"simulator"|"device", caveatTag? }
// and a crash adds { kind, fatal, errorClass?, message?, frames?[] }.

'use strict';
const fs = require('fs');
const path = require('path');

// ---- event loading -------------------------------------------------------------------------------

function loadEventsFromText(text, where) {
  const out = [];
  text.split(/\r?\n/).forEach((line, i) => {
    const s = line.trim();
    if (!s) return;
    try {
      const obj = JSON.parse(s);
      if (obj && typeof obj === 'object') out.push(obj);
    } catch (e) {
      // A directory of one-JSON-object-per-file also lands here when read whole; tolerate by trying
      // the whole blob as a single object below. Per-line parse errors on NDJSON are reported.
      throw new Error(`bad JSON in ${where} line ${i + 1}: ${e.message}`);
    }
  });
  return out;
}

function loadEvents(inputs) {
  const events = [];
  for (const input of inputs) {
    const st = fs.existsSync(input) ? fs.statSync(input) : null;
    if (st && st.isDirectory()) {
      for (const name of fs.readdirSync(input)) {
        if (!/\.(json|ndjson)$/.test(name)) continue;
        const p = path.join(input, name);
        const text = fs.readFileSync(p, 'utf8');
        // A *.json file is usually ONE object (the crash floor writes one record per file); a
        // *.ndjson is many. Try whole-object first, fall back to line-delimited.
        if (name.endsWith('.json')) {
          try { events.push(JSON.parse(text)); continue; } catch (e) { /* fall through to ndjson */ }
        }
        events.push(...loadEventsFromText(text, p));
      }
    } else if (st && st.isFile()) {
      events.push(...loadEventsFromText(fs.readFileSync(input, 'utf8'), input));
    } else {
      throw new Error(`input not found: ${input}`);
    }
  }
  return events;
}

// ---- the computation -----------------------------------------------------------------------------

function computeCrashFree(events) {
  // group key = platform|buildId
  const groups = new Map();
  const groupOf = (e) => {
    const k = `${e.platform || 'unknown'}|${e.buildId || 'unknown'}`;
    if (!groups.has(k)) {
      groups.set(k, {
        platform: e.platform || 'unknown',
        buildId: e.buildId || 'unknown',
        sessions: new Set(),      // distinct sessionId with a session-start
        crashedSessions: new Set(), // distinct sessionId with a fatal crash
        sources: new Set(),
      });
    }
    return groups.get(k);
  };
  for (const e of events) {
    if (!e || typeof e !== 'object') continue;
    const g = groupOf(e);
    if (e.source) g.sources.add(e.source);
    const sid = e.sessionId || '';
    if (e.eventType === 'session-start') {
      if (sid) g.sessions.add(sid);
    } else if (e.eventType === 'crash' && e.fatal) {
      if (sid) {
        g.crashedSessions.add(sid);
        // A fatal crash implies the session existed even if its session-start beacon was lost
        // (e.g. a crash during boot before the beacon flushed) — count it in the denominator too.
        g.sessions.add(sid);
      }
    }
  }
  const rows = [];
  for (const g of groups.values()) {
    const total = g.sessions.size;
    const crashed = g.crashedSessions.size;
    const crashFreePct = total === 0 ? null : 100 * (1 - crashed / total);
    // The number is only the HEADLINE when it comes from real devices. An emulator/simulator (or
    // unknown) source carries a caveat so a pre-ship number is never reported as the shipped metric.
    const onlyDevice = g.sources.size > 0 && [...g.sources].every((s) => s === 'device');
    rows.push({
      platform: g.platform,
      buildId: g.buildId,
      totalSessions: total,
      crashedSessions: crashed,
      crashFreePct,
      sources: [...g.sources].sort(),
      caveat: onlyDevice ? null : 'NOT-A-SHIPPED-METRIC (emulator/simulator/unknown source)',
    });
  }
  rows.sort((a, b) => (a.platform + a.buildId).localeCompare(b.platform + b.buildId));
  return rows;
}

function fmtPct(p) { return p === null ? 'n/a (0 sessions)' : `${p.toFixed(3)}%`; }

function printReport(rows) {
  console.log('crash-free sessions (TEL-1/REL-4) — per platform + buildId\n');
  for (const r of rows) {
    console.log(`  ${r.platform}  build ${r.buildId.slice(0, 12)}`);
    console.log(`    crash-free: ${fmtPct(r.crashFreePct)}  (denominator: ${r.totalSessions} sessions, ${r.crashedSessions} with a fatal)`);
    console.log(`    source: ${r.sources.join(',') || 'unknown'}${r.caveat ? '  ⚠ ' + r.caveat : ''}`);
  }
  if (rows.length === 0) console.log('  (no events)');
  console.log('');
}

// ---- selftest (device-free proof) ----------------------------------------------------------------

function assert(cond, msg) { if (!cond) { console.error('  ✗ ' + msg); process.exitCode = 1; } else { console.log('  ✓ ' + msg); } }

function selftest() {
  console.log('==> crashfree-report selftest (the computation, device-free)\n');
  const ss = (platform, buildId, sessionId, source) => ({ schema: 2, eventType: 'session-start', platform, buildId, sessionId, source, timestampMs: 1 });
  const cr = (platform, buildId, sessionId, source) => ({ schema: 2, eventType: 'crash', kind: 'jvm-uncaught', fatal: true, platform, buildId, sessionId, source, timestampMs: 2 });

  // 4 device sessions on android/buildA, 1 of them crashed → 75% crash-free.
  let ev = [ss('android', 'A', 's1', 'device'), ss('android', 'A', 's2', 'device'), ss('android', 'A', 's3', 'device'), ss('android', 'A', 's4', 'device'), cr('android', 'A', 's2', 'device')];
  let rows = computeCrashFree(ev);
  assert(rows.length === 1 && Math.abs(rows[0].crashFreePct - 75) < 1e-9, 'android/A: 1 of 4 sessions crashed → 75.000%');
  assert(rows[0].caveat === null, 'android/A: all-device source → no caveat (headline-eligible)');

  // A session that crashes TWICE is counted once in the numerator.
  ev = [ss('ios', 'B', 's1', 'device'), ss('ios', 'B', 's2', 'device'), cr('ios', 'B', 's1', 'device'), cr('ios', 'B', 's1', 'device')];
  rows = computeCrashFree(ev);
  assert(Math.abs(rows[0].crashFreePct - 50) < 1e-9, 'ios/B: a twice-crashing session counts once → 50.000%');

  // An emulator source forces the caveat (never reported as the shipped metric).
  ev = [ss('android', 'C', 's1', 'emulator'), cr('android', 'C', 's1', 'emulator')];
  rows = computeCrashFree(ev);
  assert(rows[0].caveat !== null, 'android/C: emulator source → caveat present (not a shipped metric)');

  // A boot crash with no session-start still counts in the denominator (no division surprise).
  ev = [cr('android', 'D', 's1', 'device')];
  rows = computeCrashFree(ev);
  assert(rows[0].totalSessions === 1 && Math.abs(rows[0].crashFreePct - 0) < 1e-9, 'android/D: boot crash w/o beacon → denominator 1, 0.000%');

  // Zero sessions → null (no false 100%).
  rows = computeCrashFree([]);
  assert(rows.length === 0, 'no events → no rows (never a fake 100%)');

  console.log(process.exitCode ? '\nselftest FAILED' : '\nselftest OK — crash-free math is correct.');
}

// ---- main ----------------------------------------------------------------------------------------

function main() {
  const args = process.argv.slice(2);
  if (args.includes('--selftest')) return selftest();
  const gate = args.includes('--gate');
  let floor = 99.0;
  const fi = args.indexOf('--floor');
  if (fi >= 0 && args[fi + 1]) floor = parseFloat(args[fi + 1]);
  const inputs = args.filter((a, i) => !a.startsWith('--') && !(i > 0 && args[i - 1] === '--floor'));
  if (inputs.length === 0) {
    console.error('usage: crashfree-report.js <dir-or-ndjson>... [--gate --floor 99.0] | --selftest');
    process.exit(2);
  }
  const rows = computeCrashFree(loadEvents(inputs));
  printReport(rows);
  if (gate) {
    let failed = false;
    for (const r of rows) {
      if (r.crashFreePct !== null && r.crashFreePct < floor) {
        console.error(`  ✗ ${r.platform}/${r.buildId.slice(0, 12)}: ${fmtPct(r.crashFreePct)} < floor ${floor}%`);
        failed = true;
      }
    }
    if (failed) process.exit(1);
    console.log(`gate OK — every group ≥ ${floor}% crash-free.`);
  }
}

if (require.main === module) main();
module.exports = { computeCrashFree, loadEvents };
