#!/usr/bin/env node
// dev-server.test.js — DEV-5 headless regression for tool/canopy-dev-server.js.
//
// Proves the watcher + incremental-rebuild + WS-push pipeline end to end WITHOUT a device,
// an emulator, the real canopy compiler, or any npm dependency (node v22 built-ins only):
//
//   A. arg parsing + config load          (CLI surface)
//   B. path filtering                      (only .can/.js/.json, not build output / dotfiles)
//   C. debounce / coalesce                 (a burst of saves → ONE rebuild)
//   D. WS frame codec                      (server-encode ↔ client-decode round-trip, masking)
//   E. selectPushFrame short-circuit       (DEV-9 content-hash: same buildId → "nochange")
//   F. runBuild over a FAKE runner         (success reads artifacts; failure surfaces report)
//   G. end-to-end: createDevServer + a real built-in WebSocket client receives reload/error
//   H. live coalescing under createDevServer (change mid-build → exactly one extra rebuild)
//
// Exits non-zero on the first failing assertion so it is a real gate (mirrors the other
// harnesses + tool/test/Spec.hs).
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const assert = require('assert');

const D = require('../canopy-dev-server.js');

// ---- tiny assertion harness ------------------------------------------------
let passed = 0, failed = 0; const fails = [];
function check(name, fn) {
  return Promise.resolve().then(fn).then(() => {
    passed++; console.log('  \x1b[32m✓\x1b[0m ' + name);
  }).catch((e) => {
    failed++; fails.push(name); console.log('  \x1b[31m✗\x1b[0m ' + name + '  — ' + (e && e.message || e));
  });
}
function section(t) { console.log('\n\x1b[1m' + t + '\x1b[0m'); }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// A throwaway app dir with a native.config.json + a writable build/ output.
function makeTmpApp(extra) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'canopy-dev-'));
  fs.mkdirSync(path.join(dir, 'src'), { recursive: true });
  fs.mkdirSync(path.join(dir, 'build'), { recursive: true });
  fs.writeFileSync(path.join(dir, 'src', 'Main.can'), 'module Main exposing (main)\n');
  fs.writeFileSync(path.join(dir, 'native.config.json'), JSON.stringify(Object.assign({
    appName: 'T', bundleId: 'org.canopy.t', outputDir: 'build', runtimeVersion: '7',
  }, extra)));
  return dir;
}

// Write a bundle + map + manifest into an app's build dir, as a real `canopy-native build` would.
function writeArtifacts(dir, bundleText, mapText) {
  const out = path.join(dir, 'build');
  fs.writeFileSync(path.join(out, 'canopy.bundle.js'), bundleText);
  if (mapText != null) fs.writeFileSync(path.join(out, 'canopy.bundle.js.map'), mapText);
  const buildId = D.sha256Hex(bundleText);
  fs.writeFileSync(path.join(out, 'canopy.manifest.json'),
    JSON.stringify({ buildId, bundle: { name: 'canopy.bundle.js', sha256: buildId } }));
  return buildId;
}

async function run() {
  // =========================================================================
  section('A. arg parsing + config load');

  await check('parseArgs reads app dir + flags', () => {
    const o = D.parseArgs(['myapp', '--port', '9001', '--host', '0.0.0.0', '--once']);
    assert.strictEqual(o.appDir, 'myapp');
    assert.strictEqual(o.port, 9001);
    assert.strictEqual(o.host, '0.0.0.0');
    assert.strictEqual(o.once, true);
  });
  await check('parseArgs defaults port/host/build-cmd', () => {
    const o = D.parseArgs(['app']);
    assert.strictEqual(o.port, 8099);
    assert.strictEqual(o.host, '127.0.0.1');
    assert.strictEqual(o.buildCmd, 'canopy-native build');
  });
  await check('parseArgs requires an app dir', () => {
    assert.throws(() => D.parseArgs(['--port', '1']), /usage/);
  });
  await check('parseArgs rejects an unknown flag', () => {
    assert.throws(() => D.parseArgs(['app', '--nope']), /unknown flag/);
  });
  await check('loadAppConfig reads outputDir + runtimeVersion', () => {
    const dir = makeTmpApp({ outputDir: 'dist', runtimeVersion: '42' });
    const c = D.loadAppConfig(dir);
    assert.strictEqual(c.outputDir, 'dist');
    assert.strictEqual(c.runtimeVersion, '42');
  });
  await check('loadAppConfig falls back to build/1 for a bare dir', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'canopy-bare-'));
    const c = D.loadAppConfig(dir);
    assert.strictEqual(c.outputDir, 'build');
    assert.strictEqual(c.runtimeVersion, '1');
  });

  // =========================================================================
  section('B. path filtering');

  await check('a .can edit is watched', () => assert.ok(D.isWatchedPath('/a/src/Main.can')));
  await check('a native.js edit is watched', () => assert.ok(D.isWatchedPath('/a/pkg/native.js')));
  await check('build output is ignored', () => assert.ok(!D.isWatchedPath('/a/build/canopy.bundle.js')));
  await check('generated output is ignored', () => assert.ok(!D.isWatchedPath('/a/build/generated/x.ts')));
  await check('.git internals are ignored', () => assert.ok(!D.isWatchedPath('/a/.git/index')));
  await check('node_modules is ignored', () => assert.ok(!D.isWatchedPath('/a/node_modules/x/y.js')));
  await check('an editor swap dotfile is ignored', () => assert.ok(!D.isWatchedPath('/a/src/.Main.can.swp')));
  await check('an emacs backup~ is ignored', () => assert.ok(!D.isWatchedPath('/a/src/Main.can~')));
  await check('a non-source ext is ignored', () => assert.ok(!D.isWatchedPath('/a/src/icon.png')));

  // =========================================================================
  section('C. debounce / coalesce');

  await check('a burst of N triggers fires the callback exactly ONCE', async () => {
    let fired = 0;
    const d = D.makeDebouncer(40, () => { fired++; });
    for (let i = 0; i < 25; i++) d.trigger();
    assert.ok(d.isPending(), 'should be pending right after triggers');
    await sleep(80);
    assert.strictEqual(fired, 1, 'coalesced to one fire, got ' + fired);
    assert.ok(!d.isPending());
  });
  await check('a later burst fires again (window resets per quiet period)', async () => {
    let fired = 0;
    const d = D.makeDebouncer(30, () => { fired++; });
    d.trigger(); await sleep(60);
    d.trigger(); await sleep(60);
    assert.strictEqual(fired, 2);
  });
  await check('flush() forces the trailing edge immediately', () => {
    let fired = 0;
    const d = D.makeDebouncer(10000, () => { fired++; });
    d.trigger(); d.flush();
    assert.strictEqual(fired, 1);
  });
  await check('cancel() drops a pending fire', async () => {
    let fired = 0;
    const d = D.makeDebouncer(30, () => { fired++; });
    d.trigger(); d.cancel(); await sleep(60);
    assert.strictEqual(fired, 0);
  });

  // =========================================================================
  section('D. WS frame codec (server-encode ↔ client-decode)');

  // A masked client frame decodes to its text (server must unmask).
  function maskedClientFrame(str) {
    const payload = Buffer.from(str, 'utf8');
    const mask = Buffer.from([0x12, 0x34, 0x56, 0x78]);
    const masked = Buffer.alloc(payload.length);
    for (let i = 0; i < payload.length; i++) masked[i] = payload[i] ^ mask[i & 3];
    let header;
    if (payload.length < 126) header = Buffer.from([0x81, 0x80 | payload.length]);
    else { header = Buffer.alloc(4); header[0] = 0x81; header[1] = 0x80 | 126; header.writeUInt16BE(payload.length, 2); }
    return Buffer.concat([header, mask, masked]);
  }
  await check('decodeFrame unmasks a short masked client text frame', () => {
    const f = D.decodeFrame(maskedClientFrame('hello'));
    assert.strictEqual(f.payload.toString('utf8'), 'hello');
    assert.strictEqual(f.opcode, 0x1);
  });
  await check('decodeFrame handles a 126..65535 extended length', () => {
    const big = 'x'.repeat(1000);
    const f = D.decodeFrame(maskedClientFrame(big));
    assert.strictEqual(f.payload.toString('utf8'), big);
  });
  await check('decodeFrame returns null on a short buffer (needs more bytes)', () => {
    assert.strictEqual(D.decodeFrame(Buffer.from([0x81])), null);
  });
  await check('encodeTextFrame round-trips through a (locally-masked) decode', () => {
    // encode a server frame (unmasked), then re-mask it as a client would to feed decodeFrame.
    const server = D.encodeTextFrame('{"type":"reload"}');
    // server frame is unmasked; decodeFrame accepts unmasked too (masked bit 0).
    const f = D.decodeFrame(server);
    assert.strictEqual(f.payload.toString('utf8'), '{"type":"reload"}');
  });
  await check('encodeTextFrame uses the 64-bit length path for >64KiB payloads', () => {
    const huge = 'y'.repeat(70000);
    const frame = D.encodeTextFrame(huge);
    assert.strictEqual(frame[1] & 0x7f, 127, 'should select the 8-byte length');
    const f = D.decodeFrame(frame);
    assert.strictEqual(f.payload.length, 70000);
  });
  await check('wsAccept matches the RFC 6455 example', () => {
    // RFC 6455 §1.3 worked example: key "dGhlIHNhbXBsZSBub25jZQ==" → this accept value.
    assert.strictEqual(D.wsAccept('dGhlIHNhbXBsZSBub25jZQ=='), 's3pPLMBiTxaQ9kYGzzhZRbK+xOo=');
  });

  // =========================================================================
  section('E. selectPushFrame — content-hash short-circuit (DEV-9 seam)');

  await check('a build failure → error frame carrying the report', () => {
    const f = D.selectPushFrame({ ok: false, report: 'boom' }, 'abc');
    assert.strictEqual(f.type, 'error');
    assert.strictEqual(f.report, 'boom');
  });
  await check('first successful build → reload frame with bundle + map', () => {
    const f = D.selectPushFrame({ ok: true, buildId: 'aaa', bundle: 'B', map: 'M' }, null);
    assert.strictEqual(f.type, 'reload');
    assert.strictEqual(f.buildId, 'aaa');
    assert.strictEqual(f.bundle, 'B');
    assert.strictEqual(f.map, 'M');
  });
  await check('a rebuild to the SAME buildId short-circuits to nochange (no bundle bytes)', () => {
    const f = D.selectPushFrame({ ok: true, buildId: 'same', bundle: 'BIG', map: 'M' }, 'same');
    assert.strictEqual(f.type, 'nochange');
    assert.strictEqual(f.buildId, 'same');
    assert.strictEqual(f.bundle, undefined, 'nochange must NOT carry the bundle');
  });
  await check('a rebuild to a NEW buildId pushes a fresh reload', () => {
    const f = D.selectPushFrame({ ok: true, buildId: 'new', bundle: 'B2', map: null }, 'old');
    assert.strictEqual(f.type, 'reload');
    assert.strictEqual(f.buildId, 'new');
  });

  // =========================================================================
  section('F. runBuild over a fake runner');

  await check('a successful runner makes runBuild read the on-disk artifacts', async () => {
    const dir = makeTmpApp();
    const buildId = writeArtifacts(dir, 'BUNDLE-V1', '{"map":1}');
    const opts = { appDir: dir, outputDir: 'build', buildCmd: 'fake' };
    const res = await D.runBuild(opts, async () => ({ code: 0, stdout: 'built', stderr: '' }));
    assert.strictEqual(res.ok, true);
    assert.strictEqual(res.buildId, buildId);
    assert.strictEqual(res.bundle, 'BUNDLE-V1');
    assert.strictEqual(res.map, '{"map":1}');
  });
  await check('a failing runner surfaces the compiler report', async () => {
    const dir = makeTmpApp();
    const opts = { appDir: dir, outputDir: 'build', buildCmd: 'fake' };
    const res = await D.runBuild(opts, async () => ({ code: 1, stdout: '', stderr: 'TYPE ERROR at Main.can:3' }));
    assert.strictEqual(res.ok, false);
    assert.ok(/TYPE ERROR/.test(res.report), res.report);
  });
  await check('success-but-no-bundle is reported as a failure', async () => {
    const dir = makeTmpApp(); // build/ exists but is empty (no bundle written)
    const opts = { appDir: dir, outputDir: 'build', buildCmd: 'fake' };
    const res = await D.runBuild(opts, async () => ({ code: 0, stdout: 'ok', stderr: '' }));
    assert.strictEqual(res.ok, false);
    assert.ok(/no bundle/.test(res.report), res.report);
  });
  await check('buildId falls back to sha256 of bytes when the manifest is missing', async () => {
    const dir = makeTmpApp();
    fs.writeFileSync(path.join(dir, 'build', 'canopy.bundle.js'), 'NOMANIFEST');
    const opts = { appDir: dir, outputDir: 'build', buildCmd: 'fake' };
    const res = await D.runBuild(opts, async () => ({ code: 0, stdout: '', stderr: '' }));
    assert.strictEqual(res.ok, true);
    assert.strictEqual(res.buildId, D.sha256Hex('NOMANIFEST'));
  });

  // =========================================================================
  section('G. end-to-end — real WebSocket client receives the pushed frames');

  // Connect a built-in node WebSocket and collect the JSON frames it receives.
  function connect(url) {
    const ws = new WebSocket(url);
    const frames = [];
    ws._frames = frames;
    ws.addEventListener('message', (ev) => { frames.push(JSON.parse(ev.data)); });
    return new Promise((resolve, reject) => {
      ws.addEventListener('open', () => resolve(ws));
      ws.addEventListener('error', (e) => reject(new Error('ws error: ' + (e.message || 'connect failed'))));
    });
  }
  const waitFor = async (pred, ms) => {
    const t0 = Date.now();
    while (Date.now() - t0 < (ms || 2000)) { if (pred()) return true; await sleep(15); }
    return pred();
  };

  await check('a connecting host gets a hello, then a reload on the first build', async () => {
    const dir = makeTmpApp({ runtimeVersion: '9' });
    let version = 0;
    // fake runner: each invocation "compiles" a NEW bundle so the buildId changes.
    const runner = async () => { writeArtifacts(dir, 'BUNDLE-' + (++version), '{"v":' + version + '}'); return { code: 0 }; };
    const server = D.createDevServer({ appDir: dir, host: '127.0.0.1', port: 0, buildCmd: 'fake', debounceMs: 20 }, { runner, log: () => {} });
    const addr = await server.ws.listen();
    try {
      const ws = await connect('ws://127.0.0.1:' + addr.port);
      await waitFor(() => ws._frames.length >= 1);
      assert.strictEqual(ws._frames[0].type, 'hello');
      assert.strictEqual(ws._frames[0].runtimeVersion, '9');
      assert.strictEqual(ws._frames[0].buildId, null, 'no build yet at connect time');
      // now trigger a build by simulating a watched-file change
      server.onChange(path.join(dir, 'src', 'Main.can'));
      await waitFor(() => ws._frames.some((f) => f.type === 'reload'));
      const reload = ws._frames.find((f) => f.type === 'reload');
      assert.ok(reload, 'expected a reload frame');
      assert.strictEqual(reload.bundle, 'BUNDLE-1');
      assert.strictEqual(reload.map, '{"v":1}');
      assert.ok(/^[0-9a-f]{64}$/.test(reload.buildId), 'buildId is a sha256 hex');
      // a building frame should have preceded the reload
      assert.ok(ws._frames.some((f) => f.type === 'building'), 'expected a building frame');
      ws.close();
    } finally { await server.stop(); }
  });

  await check('an unchanged rebuild pushes nochange (short-circuit over the wire)', async () => {
    const dir = makeTmpApp();
    // runner writes the SAME bytes every time → identical buildId → must short-circuit.
    const runner = async () => { writeArtifacts(dir, 'STATIC-BUNDLE', '{"m":1}'); return { code: 0 }; };
    const server = D.createDevServer({ appDir: dir, host: '127.0.0.1', port: 0, buildCmd: 'fake', debounceMs: 20 }, { runner, log: () => {} });
    const addr = await server.ws.listen();
    try {
      const ws = await connect('ws://127.0.0.1:' + addr.port);
      server.onChange(path.join(dir, 'src', 'Main.can'));     // build #1 → reload
      await waitFor(() => ws._frames.some((f) => f.type === 'reload'));
      await sleep(40);
      server.onChange(path.join(dir, 'src', 'Main.can'));     // build #2 → identical → nochange
      await waitFor(() => ws._frames.some((f) => f.type === 'nochange'));
      const reloads = ws._frames.filter((f) => f.type === 'reload');
      const nochanges = ws._frames.filter((f) => f.type === 'nochange');
      assert.strictEqual(reloads.length, 1, 'exactly one bundle pushed, got ' + reloads.length);
      assert.ok(nochanges.length >= 1, 'expected a nochange short-circuit frame');
      assert.strictEqual(nochanges[0].bundle, undefined, 'nochange carried no bundle bytes');
      ws.close();
    } finally { await server.stop(); }
  });

  await check('a build failure pushes an error frame with the report', async () => {
    const dir = makeTmpApp();
    const runner = async () => ({ code: 1, stdout: '', stderr: 'PARSE ERROR: unexpected token at Main.can:5' });
    const server = D.createDevServer({ appDir: dir, host: '127.0.0.1', port: 0, buildCmd: 'fake', debounceMs: 20 }, { runner, log: () => {} });
    const addr = await server.ws.listen();
    try {
      const ws = await connect('ws://127.0.0.1:' + addr.port);
      server.onChange(path.join(dir, 'src', 'Main.can'));
      await waitFor(() => ws._frames.some((f) => f.type === 'error'));
      const err = ws._frames.find((f) => f.type === 'error');
      assert.ok(err, 'expected an error frame');
      assert.ok(/PARSE ERROR/.test(err.report), err.report);
      ws.close();
    } finally { await server.stop(); }
  });

  await check('a late-joining host is greeted with the latest buildId in hello', async () => {
    const dir = makeTmpApp();
    let v = 0;
    const runner = async () => { writeArtifacts(dir, 'B-' + (++v)); return { code: 0 }; };
    const server = D.createDevServer({ appDir: dir, host: '127.0.0.1', port: 0, buildCmd: 'fake', debounceMs: 10 }, { runner, log: () => {} });
    const addr = await server.ws.listen();
    try {
      // build first, with no client connected
      await server.rebuildAndPush();
      const expected = server.getLastBuildId();
      assert.ok(expected, 'a build should have set lastBuildId');
      // now a host joins late
      const ws = await connect('ws://127.0.0.1:' + addr.port);
      await waitFor(() => ws._frames.length >= 1);
      assert.strictEqual(ws._frames[0].type, 'hello');
      assert.strictEqual(ws._frames[0].buildId, expected, 'hello carries the latest buildId');
      ws.close();
    } finally { await server.stop(); }
  });

  // =========================================================================
  section('H. live coalescing under createDevServer');

  await check('changes arriving mid-build coalesce to exactly ONE extra rebuild', async () => {
    const dir = makeTmpApp();
    let builds = 0;
    // a slow runner so we can fire changes while build #1 is in flight
    const runner = async () => {
      builds++;
      await sleep(60);
      writeArtifacts(dir, 'BUNDLE-' + builds); // unique bytes each time → distinct buildId
      return { code: 0 };
    };
    const server = D.createDevServer({ appDir: dir, host: '127.0.0.1', port: 0, buildCmd: 'fake', debounceMs: 10 }, { runner, log: () => {} });
    const addr = await server.ws.listen();
    try {
      const p1 = server.rebuildAndPush();           // build #1 starts (in flight ~60ms)
      await sleep(15);
      assert.ok(server.isBuilding(), 'build #1 should be in flight');
      // fire a flurry of changes WHILE #1 runs — these must coalesce into ONE follow-up build
      server.onChange(path.join(dir, 'src', 'Main.can'));
      server.onChange(path.join(dir, 'src', 'Main.can'));
      server.onChange(path.join(dir, 'src', 'Main.can'));
      server.debouncer.flush(); // collapse the debounce window immediately
      await p1;
      await waitFor(() => !server.isBuilding(), 1000);
      await sleep(20);
      assert.strictEqual(builds, 2, 'expected exactly 2 builds (initial + one coalesced), got ' + builds);
    } finally { await server.stop(); }
  });

  // =========================================================================
  console.log('\n\x1b[1mResult: ' + (failed === 0 ? '\x1b[32mPASS' : '\x1b[31mFAIL') +
    '\x1b[0m  (' + passed + ' passed, ' + failed + ' failed)');
  if (failed) { console.log('failed:\n  - ' + fails.join('\n  - ')); process.exitCode = 1; }
}

run().catch((e) => { console.error('harness crashed:', e); process.exit(1); });
