#!/usr/bin/env node
// canopy-dev-server.js — DEV-5: the dev loop's push side. Watches a native app's `.can`
// sources (+ a linked native.js), debounces a burst of saves, drives `canopy-native build`,
// and pushes the freshly-assembled bundle to every connected host over WebSocket.
//
//   edit src/Main.can  ──▶  debounce ──▶  canopy-native build ──▶  content-hash short-circuit
//                                                                       │
//                            ws frame {type:"reload", buildId, bundle, map}  (or {type:"error", report})
//                                                                       ▼
//                                                                  connected host
//
// ZERO npm deps by design. Node v22 ships a built-in `WebSocket` *client* and the built-in
// `http`/`net`/`crypto` modules are enough to stand up an RFC-6455 *server* — so this needs
// neither `ws` nor `chokidar` (the plan named them, but vendoring two npm trees into a Haskell
// toolchain repo is the wrong trade; `fs.watch` + a 130-line WS server cover the dev loop).
//
// DEV-9 hook: the build is content-addressed (the bundle's sha256 *is* the buildId — see
// tool/src/Canopy/Native/Build.hs `buildManifest`). When a rebuild lands on the SAME buildId
// (e.g. a comment-only edit, or a save that round-trips to identical output), the server
// SHORT-CIRCUITS: it neither re-reads the bundle off disk nor pushes a frame. That is the
// "content-hash short-circuit" the incremental-rebuild plan calls for, applied at the push seam.
//
// The whole pipeline is split into small pure-ish pieces and EXPORTED so tool/test/
// dev-server.test.js can exercise the watcher debounce, the rebuild short-circuit, the WS frame
// codec, and a real end-to-end WS round-trip with no device and no emulator.
//
// Usage:
//   node tool/canopy-dev-server.js <app-dir> [--port 8099] [--host 127.0.0.1]
//                                            [--build-cmd "canopy-native build"] [--once]
//   --once   build + push to whoever is already connected, then exit (CI / scripted smoke test)
//
// Wire protocol (one JSON object per WS text frame, server → host):
//   {"type":"hello",   "buildId":<string|null>, "runtimeVersion":<string>}   on connect
//   {"type":"building","buildId":<prev|null>}                                rebuild started
//   {"type":"reload",  "buildId":<sha256>, "bundle":<js>, "map":<json|null>} rebuild OK + changed
//   {"type":"nochange","buildId":<sha256>}                                   rebuild OK, same buildId
//   {"type":"error",   "report":<compiler stderr/stdout>}                    rebuild FAILED
'use strict';

const fs = require('fs');
const path = require('path');
const http = require('http');
const crypto = require('crypto');
const { spawn } = require('child_process');

// ---------------------------------------------------------------------------
// Config / arg parsing
// ---------------------------------------------------------------------------

const DEFAULT_PORT = 8099;
const DEFAULT_HOST = '127.0.0.1';
const DEFAULT_DEBOUNCE_MS = 120;
const WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'; // RFC 6455 magic

// Source extensions a `.can` edit can touch. native.js is the linked package FFI surface.
const WATCHED_EXT = new Set(['.can', '.js', '.json']);
const WATCH_IGNORE = /(^|\/)(\.git|\.stack-work|node_modules|build|generated)(\/|$)/;

function parseArgs(argv) {
  const out = { appDir: null, port: DEFAULT_PORT, host: DEFAULT_HOST,
    buildCmd: 'canopy-native build', once: false, debounceMs: DEFAULT_DEBOUNCE_MS };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--port') out.port = Number(argv[++i]);
    else if (a === '--host') out.host = argv[++i];
    else if (a === '--build-cmd') out.buildCmd = argv[++i];
    else if (a === '--debounce') out.debounceMs = Number(argv[++i]);
    else if (a === '--once') out.once = true;
    else if (a.startsWith('--')) throw new Error('unknown flag: ' + a);
    else if (out.appDir === null) out.appDir = a;
    else throw new Error('unexpected positional arg: ' + a);
  }
  if (out.appDir === null) throw new Error('usage: canopy-dev-server <app-dir> [--port N] [--host H] [--once]');
  return out;
}

// Read native.config.json to learn the output dir + runtimeVersion. Falls back to "build"/"1"
// so the server still runs against a bare dir (the build will then fail loud, not the server).
function loadAppConfig(appDir) {
  const p = path.join(appDir, 'native.config.json');
  let cfg = {};
  try { cfg = JSON.parse(fs.readFileSync(p, 'utf8')); } catch (_) { /* default below */ }
  return {
    outputDir: cfg.outputDir || 'build',
    runtimeVersion: String(cfg.runtimeVersion == null ? '1' : cfg.runtimeVersion),
    entry: cfg.entry || 'src/Main.can',
  };
}

// ---------------------------------------------------------------------------
// Debounce / coalesce — collapse a burst of saves into ONE rebuild
// ---------------------------------------------------------------------------

// A save (editor "atomic write" especially) fires modify/create/delete in quick succession,
// often across several files. Coalesce every event inside a `delayMs` window into a single
// rebuild, and if events keep arriving, keep sliding the window (trailing-edge debounce).
function makeDebouncer(delayMs, fire) {
  let timer = null;
  let pending = false;
  const trigger = () => {
    pending = true;
    if (timer) clearTimeout(timer);
    timer = setTimeout(() => { timer = null; pending = false; fire(); }, delayMs);
  };
  return {
    trigger,
    // for tests: is a rebuild currently queued?
    isPending: () => pending,
    // for tests: force the trailing edge now
    flush: () => { if (timer) { clearTimeout(timer); timer = null; pending = false; fire(); } },
    cancel: () => { if (timer) { clearTimeout(timer); timer = null; pending = false; } },
  };
}

// Should this changed path trigger a rebuild? (filters editor temp files, build output, vcs)
function isWatchedPath(p) {
  if (WATCH_IGNORE.test(p)) return false;
  const base = path.basename(p);
  if (base.startsWith('.') && base !== '.') return false; // dotfiles / editor swap (.foo.swp etc)
  if (base.endsWith('~')) return false;                   // emacs backups
  return WATCHED_EXT.has(path.extname(p));
}

// ---------------------------------------------------------------------------
// Build orchestration + content-hash short-circuit (DEV-9 seam)
// ---------------------------------------------------------------------------

// Run the build command (default `canopy-native build <appDir>`) and read the resulting bundle
// + map + buildId. Returns one of:
//   { ok:true,  buildId, bundle, map }   build succeeded, artifacts read
//   { ok:false, report }                 build failed; report = combined stderr/stdout
// `runner` is injectable so tests can drive a fake compiler without a real toolchain.
function runBuild(opts, runner) {
  const run = runner || defaultRunner;
  return run(opts.buildCmd, opts.appDir).then((res) => {
    if (res.code !== 0) {
      return { ok: false, report: (res.stderr || '') + (res.stdout || '') || ('build exited ' + res.code) };
    }
    return readArtifacts(opts).then((art) => {
      if (!art) return { ok: false, report: 'build reported success but produced no bundle in ' + opts.outputDir };
      return Object.assign({ ok: true }, art);
    });
  });
}

// Default runner: spawn the build command (first token = program, rest = args) with the app dir
// appended, capturing exit code + output. Uses spawn (not shell) so args with spaces are safe.
function defaultRunner(buildCmd, appDir) {
  return new Promise((resolve) => {
    const parts = buildCmd.split(/\s+/).filter(Boolean);
    const prog = parts[0];
    const args = parts.slice(1).concat([appDir]);
    const child = spawn(prog, args, { stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '', stderr = '';
    child.stdout.on('data', (d) => { stdout += d; });
    child.stderr.on('data', (d) => { stderr += d; });
    child.on('error', (e) => resolve({ code: 127, stdout, stderr: stderr + '\n' + e.message }));
    child.on('close', (code) => resolve({ code, stdout, stderr }));
  });
}

// Read the assembled bundle + sibling map + manifest buildId from the app's output dir.
// The manifest's buildId IS the bundle's sha256 (Build.hs); we recompute it independently as a
// fallback so the short-circuit is robust even if the manifest is stale/absent.
function readArtifacts(opts) {
  const outDir = path.isAbsolute(opts.outputDir) ? opts.outputDir : path.join(opts.appDir, opts.outputDir);
  const bundlePath = path.join(outDir, 'canopy.bundle.js');
  const mapPath = path.join(outDir, 'canopy.bundle.js.map');
  const manifestPath = path.join(outDir, 'canopy.manifest.json');
  return new Promise((resolve) => {
    fs.readFile(bundlePath, 'utf8', (err, bundle) => {
      if (err) return resolve(null);
      let map = null;
      try { map = fs.readFileSync(mapPath, 'utf8'); } catch (_) { map = null; }
      let buildId = null;
      try { buildId = JSON.parse(fs.readFileSync(manifestPath, 'utf8')).buildId || null; } catch (_) { buildId = null; }
      if (!buildId) buildId = sha256Hex(bundle); // fallback: hash the bytes ourselves
      resolve({ buildId, bundle, map });
    });
  });
}

function sha256Hex(s) {
  return crypto.createHash('sha256').update(s).digest('hex');
}

// Pick the frame to push given the new build result and the buildId we last pushed.
// This is the DEV-9 content-hash short-circuit: a successful rebuild whose buildId equals the
// last one we shipped collapses to a tiny "nochange" frame (no bundle bytes re-sent).
function selectPushFrame(result, lastBuildId) {
  if (!result.ok) return { type: 'error', report: result.report };
  if (lastBuildId && result.buildId === lastBuildId) {
    return { type: 'nochange', buildId: result.buildId };
  }
  return { type: 'reload', buildId: result.buildId, bundle: result.bundle, map: result.map };
}

// ---------------------------------------------------------------------------
// Minimal RFC-6455 WebSocket server (text frames only, server→client + client close)
// ---------------------------------------------------------------------------

// Build the Sec-WebSocket-Accept value from the client's key (RFC 6455 §1.3).
function wsAccept(key) {
  return crypto.createHash('sha1').update(key + WS_GUID).digest('base64');
}

// Encode a server→client TEXT frame (FIN=1, opcode=0x1, unmasked — servers never mask).
function encodeTextFrame(str) {
  const payload = Buffer.from(str, 'utf8');
  const len = payload.length;
  let header;
  if (len < 126) {
    header = Buffer.from([0x81, len]);
  } else if (len < 65536) {
    header = Buffer.alloc(4);
    header[0] = 0x81; header[1] = 126; header.writeUInt16BE(len, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x81; header[1] = 127;
    // 64-bit length; JS bundles never exceed 2^53, so hi-word stays 0.
    header.writeUInt32BE(Math.floor(len / 0x100000000), 2);
    header.writeUInt32BE(len >>> 0, 6);
  }
  return Buffer.concat([header, payload]);
}

// Encode a server CLOSE frame (opcode 0x8), optional status code.
function encodeCloseFrame(code) {
  if (code == null) return Buffer.from([0x88, 0x00]);
  const b = Buffer.alloc(4);
  b[0] = 0x88; b[1] = 0x02; b.writeUInt16BE(code, 2);
  return b;
}

// Decode ONE client→server frame from a buffer. Clients MUST mask (RFC 6455 §5.1).
// Returns { opcode, payload(Buffer), total(bytesConsumed) } or null if the buffer is short.
function decodeFrame(buf) {
  if (buf.length < 2) return null;
  const b0 = buf[0], b1 = buf[1];
  const opcode = b0 & 0x0f;
  const masked = (b1 & 0x80) !== 0;
  let len = b1 & 0x7f;
  let offset = 2;
  if (len === 126) {
    if (buf.length < 4) return null;
    len = buf.readUInt16BE(2); offset = 4;
  } else if (len === 127) {
    if (buf.length < 10) return null;
    // hi word ignored (frames are small in this protocol)
    len = buf.readUInt32BE(6); offset = 10;
  }
  let mask = null;
  if (masked) {
    if (buf.length < offset + 4) return null;
    mask = buf.slice(offset, offset + 4); offset += 4;
  }
  if (buf.length < offset + len) return null;
  const raw = buf.slice(offset, offset + len);
  const payload = Buffer.alloc(len);
  for (let i = 0; i < len; i++) payload[i] = mask ? (raw[i] ^ mask[i & 3]) : raw[i];
  return { opcode, payload, total: offset + len };
}

// Stand up the WS server on an HTTP server (so the upgrade path is standard). Tracks live
// sockets; `broadcast(obj)` JSON-encodes + frames `obj` to every open socket. `onConnect(send)`
// fires per client so the caller can greet it (the "hello" frame).
function createWsServer({ port, host }, { onConnect } = {}) {
  const sockets = new Set();
  const httpServer = http.createServer((req, res) => {
    // A plain GET (e.g. a health probe) — answer 200 so `--once` smoke tests can poll readiness.
    res.writeHead(200, { 'content-type': 'text/plain' });
    res.end('canopy-dev-server\n');
  });

  httpServer.on('upgrade', (req, socket) => {
    const key = req.headers['sec-websocket-key'];
    if (req.headers.upgrade !== 'websocket' || !key) { socket.destroy(); return; }
    socket.write(
      'HTTP/1.1 101 Switching Protocols\r\n' +
      'Upgrade: websocket\r\n' +
      'Connection: Upgrade\r\n' +
      'Sec-WebSocket-Accept: ' + wsAccept(key) + '\r\n\r\n');
    socket.setNoDelay(true);
    sockets.add(socket);

    let acc = Buffer.alloc(0);
    socket.on('data', (chunk) => {
      acc = Buffer.concat([acc, chunk]);
      let frame;
      while ((frame = decodeFrame(acc)) !== null) {
        acc = acc.slice(frame.total);
        if (frame.opcode === 0x8) { // client close
          try { socket.write(encodeCloseFrame(1000)); } catch (_) {}
          socket.end();
          break;
        }
        // ping → pong (0x9 → 0xA); text frames from the host are ignored (one-way push).
        if (frame.opcode === 0x9) {
          const pong = Buffer.concat([Buffer.from([0x8a, frame.payload.length]), frame.payload]);
          try { socket.write(pong); } catch (_) {}
        }
      }
    });
    const drop = () => sockets.delete(socket);
    socket.on('close', drop);
    socket.on('error', drop);

    const send = (obj) => {
      try { socket.write(encodeTextFrame(JSON.stringify(obj))); return true; }
      catch (_) { sockets.delete(socket); return false; }
    };
    if (onConnect) onConnect(send);
  });

  function broadcast(obj) {
    const frame = encodeTextFrame(JSON.stringify(obj));
    let n = 0;
    for (const s of sockets) {
      try { s.write(frame); n++; } catch (_) { sockets.delete(s); }
    }
    return n; // how many hosts received it
  }

  function close() {
    for (const s of sockets) { try { s.write(encodeCloseFrame(1001)); s.end(); } catch (_) {} }
    sockets.clear();
    return new Promise((resolve) => httpServer.close(resolve));
  }

  function listen() {
    return new Promise((resolve, reject) => {
      httpServer.once('error', reject);
      httpServer.listen(port, host, () => resolve(httpServer.address()));
    });
  }

  return { listen, broadcast, close, clientCount: () => sockets.size, httpServer };
}

// ---------------------------------------------------------------------------
// Recursive directory watch (fs.watch, no chokidar) with graceful fallback
// ---------------------------------------------------------------------------

// fs.watch supports { recursive:true } on Linux only since Node ~20; it's reliable on v22.
// We still guard: if the recursive watch throws, fall back to watching each subdir.
function watchTree(rootDir, onChange) {
  const watchers = [];
  const tryRecursive = () => {
    const w = fs.watch(rootDir, { recursive: true }, (_ev, file) => {
      if (file) onChange(path.join(rootDir, file));
    });
    watchers.push(w);
  };
  try {
    tryRecursive();
  } catch (_) {
    // fallback: walk + watch each dir non-recursively
    const walk = (dir) => {
      let entries = [];
      try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch (_) { return; }
      const w = fs.watch(dir, (_ev, file) => { if (file) onChange(path.join(dir, file)); });
      watchers.push(w);
      for (const e of entries) {
        if (e.isDirectory() && !WATCH_IGNORE.test(path.join(dir, e.name))) walk(path.join(dir, e.name));
      }
    };
    walk(rootDir);
  }
  return { close: () => { for (const w of watchers) { try { w.close(); } catch (_) {} } } };
}

// ---------------------------------------------------------------------------
// The server: wire it all together
// ---------------------------------------------------------------------------

// Create (but do not start) a dev server around `opts`. Returns a handle with start()/stop()
// and a few test hooks. `runner` (build command runner) is injectable for headless tests.
function createDevServer(opts, { runner, log } = {}) {
  const cfg = loadAppConfig(opts.appDir);
  const full = Object.assign({}, opts, { outputDir: cfg.outputDir });
  const say = log || ((...a) => console.log('[dev]', ...a));

  let lastBuildId = null;     // last buildId we successfully PUSHED (drives the short-circuit)
  let building = false;       // a rebuild is in flight
  let queued = false;         // a change arrived while a rebuild was in flight → rebuild again
  let watcher = null;

  const ws = createWsServer(full, {
    onConnect: (send) => {
      send({ type: 'hello', buildId: lastBuildId, runtimeVersion: cfg.runtimeVersion });
    },
  });

  // One rebuild + push cycle. Coalesces: if a change lands mid-build, runs exactly one more.
  async function rebuildAndPush() {
    if (building) { queued = true; return; }
    building = true;
    ws.broadcast({ type: 'building', buildId: lastBuildId });
    let result;
    try {
      result = await runBuild(full, runner);
    } catch (e) {
      result = { ok: false, report: String((e && e.stack) || e) };
    }
    const frame = selectPushFrame(result, lastBuildId);
    if (frame.type === 'reload') {
      lastBuildId = frame.buildId;
      const n = ws.broadcast(frame);
      say('reload', frame.buildId.slice(0, 12), '→', n, 'host(s)');
    } else if (frame.type === 'nochange') {
      ws.broadcast(frame);
      say('no change (buildId unchanged) — short-circuited push');
    } else {
      ws.broadcast(frame);
      say('build FAILED:\n' + frame.report.split('\n').slice(0, 12).join('\n'));
    }
    building = false;
    if (queued) { queued = false; setImmediate(rebuildAndPush); }
    return frame;
  }

  const debouncer = makeDebouncer(full.debounceMs, rebuildAndPush);

  async function start() {
    const addr = await ws.listen();
    const watchRoot = opts.appDir;
    watcher = watchTree(watchRoot, (p) => { if (isWatchedPath(p)) debouncer.trigger(); });
    say('watching', watchRoot, '— ws://' + full.host + ':' + addr.port);
    // Prime: do an initial build+push so a host that connects immediately gets a bundle.
    await rebuildAndPush();
    return addr;
  }

  async function stop() {
    debouncer.cancel();
    if (watcher) watcher.close();
    await ws.close();
  }

  return {
    start, stop, rebuildAndPush,
    ws, debouncer,
    // test hooks
    getLastBuildId: () => lastBuildId,
    isBuilding: () => building,
    config: cfg,
    onChange: (p) => { if (isWatchedPath(p)) debouncer.trigger(); },
  };
}

// ---------------------------------------------------------------------------
// CLI entry
// ---------------------------------------------------------------------------

async function main(argv) {
  let opts;
  try { opts = parseArgs(argv); }
  catch (e) { console.error(e.message); process.exit(2); return; }

  if (!fs.existsSync(opts.appDir)) {
    console.error('app dir not found: ' + opts.appDir);
    process.exit(2); return;
  }

  const server = createDevServer(opts);

  if (opts.once) {
    // Bring the server up, do one build+push, then exit. Handy for scripted smoke tests.
    await server.ws.listen();
    const frame = await server.rebuildAndPush();
    await server.ws.close();
    process.exit(frame && frame.type !== 'error' ? 0 : 1);
    return;
  }

  await server.start();
  const shutdown = () => { server.stop().then(() => process.exit(0)); };
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}

if (require.main === module) {
  main(process.argv.slice(2));
}

module.exports = {
  parseArgs,
  loadAppConfig,
  makeDebouncer,
  isWatchedPath,
  runBuild,
  defaultRunner,
  readArtifacts,
  sha256Hex,
  selectPushFrame,
  wsAccept,
  encodeTextFrame,
  encodeCloseFrame,
  decodeFrame,
  createWsServer,
  watchTree,
  createDevServer,
  main,
  WATCHED_EXT,
};
