#!/usr/bin/env node
// run-echo.js — the C1 first-light proof: drive the ACTUAL Canopy-compiler output for
// examples/echo (the real core/runtime.js scheduler + the real external/native-module.js
// ABI binding + the real compiled Main) against a mock Fabric AND a mock native-module
// host, and assert the native-effect round-trip end-to-end:
//
//     update → Echo.send (Cmd) → Native.Module.call → __canopy_call
//       → [worker thread does the work] → ctx.complete → [postToJs hop]
//       → __canopy_resolve(callId, …) → decoder → sendToApp → update → re-render
//
// This is the effect-system analog of run-compiled.js (which proves the render path).
// If this passes, the C1 ABI's JS half is correct: the async completion genuinely
// re-enters the TEA loop and lands in `update` as a single targeted updateProps — and
// the error taxonomy (module-not-found / rejected / decode) is wired through the full
// real stack. The only thing it does NOT exercise is the C++ thread hop itself, which
// needs a device (per plan C1 §6); that is the mock-native-modules jsQueue's job to model.
//
// Prereq: `cd examples/echo && canopy-native build`  (produces build/canopy.bundle.js).

'use strict';

const path = require('path');
const fs = require('fs');
const { createMockFabric } = require('./mock-fabric');
const { createMockNativeModules } = require('./mock-native-modules');

const BUNDLE = path.resolve(__dirname, '../examples/echo/build/canopy.bundle.js');
if (!fs.existsSync(BUNDLE)) {
  console.error('assembled bundle not found — run `cd examples/echo && canopy-native build` first:\n  ' + BUNDLE);
  process.exit(2);
}

// ---- tiny assertion harness ------------------------------------------------
let passed = 0, failed = 0; const fails = [];
function check(name, cond, detail) {
  if (cond) { passed++; console.log(`  \x1b[32m✓\x1b[0m ${name}`); }
  else { failed++; fails.push(name); console.log(`  \x1b[31m✗\x1b[0m ${name}${detail ? '  — ' + detail : ''}`); }
}
function section(t) { console.log(`\n\x1b[1m${t}\x1b[0m`); }

// Boot a FRESH program instance against fresh mocks. Re-evaluating the bundle gives a
// clean slate (fresh _Native_eventRegistry + _NM_pending + Elm), exactly like a cold
// app launch. `register(nm)` installs whichever mock modules the subtest wants.
function boot(register) {
  const mock = createMockFabric();
  const nm = createMockNativeModules();
  if (register) { register(nm); }
  // A real app evaluates the bundle ONCE; here we re-require per subtest to get a clean
  // program. Clear the host-installed ABI globals so each cold boot rebinds them to THIS
  // evaluation's fresh pending table (the lazy __canopy_resolve install is idempotent, so
  // a leftover global from a previous subtest would otherwise route completions to the
  // wrong table — a harness-only artifact that cannot happen on a single-boot device).
  delete globalThis.__canopy_resolve;
  delete globalThis.__canopy_dispatchEvent;
  Object.assign(globalThis, mock.fabric, nm.abi);   // __fabric_* + __canopy_call/__canopy_cancel
  delete require.cache[require.resolve(BUNDLE)];
  require(BUNDLE);                                    // installs __canopy_resolve + __canopy_boot
  globalThis.__canopy_boot(null, {});                // fresh program instance
  return { mock, nm };
}

async function settle(mock) {
  for (let i = 0; i < 8; i++) { mock.flushFrames(); await new Promise(r => setImmediate(r)); }
  mock.flushFrames();
}

const textOf = (mock, id) => { const v = mock.findByTestID(id); return v ? v.props.text : undefined; };

async function main() {
  check('bundle file exists', fs.existsSync(BUNDLE));

  // =========================================================================
  section('A. The happy path — async Echo round-trip into update');
  {
    const { mock, nm } = boot(nm => nm.registerModule('Echo', {
      // the reference module: echo the decoded arg back as its JSON result
      send(argsValue, ctx) { ctx.complete('', JSON.stringify(argsValue)); }
    }));
    await settle(mock);

    check('event dispatcher self-installed at boot', typeof globalThis.__canopy_dispatchEvent === 'function');
    check('initial reply label = "Reply: —"', textOf(mock, 'reply') === 'Reply: —', textOf(mock, 'reply'));
    check('initial status label = "Status: idle"', textOf(mock, 'status') === 'Status: idle', textOf(mock, 'status'));

    const replyBefore = mock.findByTestID('reply').handle;
    const ping = mock.findByTestID('ping');
    check('Ping is a native view with a press event', !!ping && Array.isArray(ping.events) && ping.events.includes('press'));

    // press Ping → issues the Cmd. The native call must happen, but NOT yet resolve.
    mock.emit(ping.handle, 'press', {});
    await settle(mock);

    const calls = nm.log.filter(m => m.op === 'call');
    check('exactly ONE __canopy_call to Echo.send', calls.length === 1 && calls[0].module === 'Echo' && calls[0].method === 'send',
      JSON.stringify(calls));
    check('args marshalled as JSON string "ping"', calls.length === 1 && calls[0].argsJson === '"ping"', calls.length ? calls[0].argsJson : '');
    check('status is "pending" BEFORE the worker hop (genuinely async)', textOf(mock, 'status') === 'Status: pending', textOf(mock, 'status'));
    check('reply still "—" before the hop (no premature resolve)', textOf(mock, 'reply') === 'Reply: —', textOf(mock, 'reply'));
    check('one completion is parked on the worker→JS hop', nm.pendingJs === 1, `${nm.pendingJs}`);
    check('__canopy_resolve installed (lazily, by the first call)', typeof globalThis.__canopy_resolve === 'function');

    // now run the worker→JS-thread hop: the completion re-enters Hermes via __canopy_resolve
    mock.clearLog();
    nm.flushJs();
    await settle(mock);

    const updates = mock.log.filter(m => m.op === 'updateProps');
    const creates = mock.log.filter(m => m.op === 'createView');
    const replyUpdate = updates.filter(u => u.handle === replyBefore && u.props.text !== undefined);
    check('ZERO createView after the result (no re-mount)', creates.length === 0, `${creates.length}`);
    check('the reply label updated via a targeted updateProps', replyUpdate.length === 1, JSON.stringify(updates.map(u => ({ h: u.handle, p: u.props }))));
    check('reply label = "Reply: ping" (decoded result landed in update)', textOf(mock, 'reply') === 'Reply: ping', textOf(mock, 'reply'));
    check('status label = "Status: ok"', textOf(mock, 'status') === 'Status: ok', textOf(mock, 'status'));
    check('reply label handle unchanged (identity preserved across the effect)', mock.findByTestID('reply').handle === replyBefore);
  }

  // =========================================================================
  section('B. Module not found — __canopy_call returns -1 through the full stack');
  {
    const { mock, nm } = boot(/* register nothing — Echo is absent */);
    await settle(mock);
    const ping = mock.findByTestID('ping');
    mock.emit(ping.handle, 'press', {});
    await settle(mock);
    check('no completion parked (call was rejected synchronously)', nm.pendingJs === 0, `${nm.pendingJs}`);
    check('status reports module-not-found:Echo', textOf(mock, 'status') === 'Status: module-not-found:Echo', textOf(mock, 'status'));
    check('reply unchanged on error', textOf(mock, 'reply') === 'Reply: —', textOf(mock, 'reply'));
  }

  // =========================================================================
  section('C. Native rejection — error payload flows back as NM.Rejected');
  {
    const { mock, nm } = boot(nm => nm.registerModule('Echo', {
      send(_args, ctx) { ctx.complete(JSON.stringify({ code: 'rejected', message: 'boom' }), ''); }
    }));
    await settle(mock);
    mock.emit(mock.findByTestID('ping').handle, 'press', {});
    await settle(mock);
    nm.flushJs();
    await settle(mock);
    const status = textOf(mock, 'status');
    check('status reports a rejected error carrying the native message', /rejected/.test(status) && /boom/.test(status), status);
  }

  // =========================================================================
  section('D. Decode mismatch — a non-string result fails the caller decoder');
  {
    const { mock, nm } = boot(nm => nm.registerModule('Echo', {
      send(_args, ctx) { ctx.complete('', JSON.stringify(12345)); }   // number, not the String the decoder wants
    }));
    await settle(mock);
    mock.emit(mock.findByTestID('ping').handle, 'press', {});
    await settle(mock);
    nm.flushJs();
    await settle(mock);
    const status = textOf(mock, 'status');
    check('status reports a decode error (result did not match Decode.string)', /decode/.test(status), status);
    check('reply unchanged on decode failure', textOf(mock, 'reply') === 'Reply: —', textOf(mock, 'reply'));
  }

  section(`Result: ${failed === 0 ? '\x1b[32mPASS' : '\x1b[31mFAIL'}\x1b[0m  (${passed} passed, ${failed} failed)`);
  if (failed) { console.log('failed:\n  - ' + fails.join('\n  - ')); }
  process.exit(failed === 0 ? 0 : 1);
}

main().catch(e => { console.error(e); process.exit(1); });
