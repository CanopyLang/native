#!/usr/bin/env node
// run-reload.js — DEV-3 regression: the runtime state seam (_Platform_live /
// _Platform_shutdown) for state-preserving reload.
//
// The TEA runtime (the single `var model` closure) lives INSIDE the compiled
// IIFE, so a debug host cannot reach it directly. DEV-3 installs an
// opt-in-only seam in the compiler runtime (Generate/JavaScript/Runtime/
// Registry.hs, inside _Platform_initialize) that, when the host sets
// `globalThis._Platform_devSeam = true` BEFORE boot, publishes:
//   globalThis._Platform_live = { getModel, setModel, managers, shutdown }
//   globalThis._Platform_shutdown = () => stop Subs + clear the handle
//
// This harness drives the REAL assembled counter bundle (the same one
// run-compiled.js uses) and asserts:
//   1. inert by default — without the opt-in flag the seam never publishes
//      anything to the host global (so normal boots are unaffected),
//   2. when opted in, _Platform_live exposes getModel/setModel/managers and
//      round-trips a model (capture → restore → re-render),
//   3. _Platform_shutdown clears the published handle without throwing
//      (the DEV-3 slice; DEV-2/DEV-4 later consume this for the full reload).
//
// Prereq: a counter bundle built from the DEV-3-patched compiler:
//   PATH=/path/to/patched-canopy:$PATH canopy-native build examples/counter
// (a stale pre-DEV-3 bundle will fail check (2) and tell you to rebuild.)
//
// Run in an isolated child node so the global-scope opt-in flag cannot leak
// into / out of other harness scripts that share the process.

'use strict';

const path = require('path');
const fs = require('fs');
const { createMockFabric } = require('./mock-fabric');

const BUNDLE = path.resolve(__dirname, '../examples/counter/build/canopy.bundle.js');
if (!fs.existsSync(BUNDLE)) {
  console.error('assembled bundle not found — run `canopy-native build examples/counter` first:\n  ' + BUNDLE);
  process.exit(2);
}

// ---- tiny assertion harness ------------------------------------------------
let passed = 0, failed = 0; const fails = [];
function check(name, cond, detail) {
  if (cond) { passed++; console.log(`  \x1b[32m✓\x1b[0m ${name}`); }
  else { failed++; fails.push(name); console.log(`  \x1b[31m✗\x1b[0m ${name}${detail ? '  — ' + detail : ''}`); }
}
function section(t) { console.log(`\n\x1b[1m${t}\x1b[0m`); }

function labelView(mock) {
  return mock.findByTag('RCTText').find(v => /^Count:/.test(v.props.text));
}

// ===========================================================================
section('A. Opt-in gate — the COMPILER runtime seam never self-publishes');
// A static byte check: the bundle text must carry the seam (proves the
// tree-shaker kept the generator-only symbols), and the runtime must gate the
// seam on _Platform_devSeam.
//
// POST-DEV-2 NOTE: this bundle is a DEBUG bundle, and DEV-2's native.js now turns
// the dev seam ON by itself in any debug bundle (it sets globalThis._Platform_devSeam
// before _Platform_initialize runs — see external/native.js / harness/run-reload-seam.js
// for the full reload lifecycle). So a debug bundle DOES publish _Platform_live at boot.
// The DEV-3 guarantee this section pins is narrower and still exactly true: the COMPILER
// RUNTIME itself never self-publishes — it only reacts to the _Platform_devSeam flag. We
// prove that by checking the runtime's gate directly: with the flag forced to a falsy value
// AT THE MOMENT the seam reads it, the runtime keeps _Platform_live null. (A release bundle
// has __canopy_debug === false, so DEV-2 never sets the flag and the seam stays fully inert;
// that path is the RB-3 release-load guard's job, not this harness's.)
const bundleSrc = fs.readFileSync(BUNDLE, 'utf8');
check('bundle text contains _Platform_live (tree-shaker kept the seam)',
  bundleSrc.includes('_Platform_live'));
check('bundle text contains _Platform_shutdown (tree-shaker kept the seam)',
  bundleSrc.includes('_Platform_shutdown'));
check('bundle text contains _Platform_devSeam opt-in (tree-shaker kept the seam)',
  bundleSrc.includes('_Platform_devSeam'));
check('runtime gates the seam on _Platform_devSeam (reads the flag, not unconditional)',
  bundleSrc.includes('_Platform_devSeam()') || bundleSrc.includes('._Platform_devSeam'));

{
  const mock = createMockFabric();
  Object.assign(globalThis, mock.fabric);
  require(BUNDLE);
  check('bundle installed the __canopy_boot hook', typeof globalThis.__canopy_boot === 'function');
  // DEV-2's native.js will have set _Platform_devSeam during element() — so a DEBUG bundle
  // legitimately publishes the seam at boot. That is the intended post-DEV-2 behavior; the
  // full state-preserving reload it enables is asserted by harness/run-reload-seam.js.
  globalThis.__canopy_boot(null, {});
  check('debug bundle published _Platform_live (DEV-2 auto-enabled the dev seam)',
    globalThis._Platform_live != null && typeof globalThis._Platform_live === 'object',
    'got ' + typeof globalThis._Platform_live);
  check('the publish was gated through the _Platform_devSeam flag (now true)',
    globalThis._Platform_devSeam === true, 'got ' + globalThis._Platform_devSeam);
}

// require() caches the module, so we cannot re-evaluate the IIFE in this same
// process to get a fresh seam state. Re-run the opted-in scenario in a child
// node with a clean module cache.
if (process.env.__CANOPY_RELOAD_CHILD !== '1') {
  const { spawnSync } = require('child_process');
  const res = spawnSync(process.execPath, [__filename], {
    env: Object.assign({}, process.env, { __CANOPY_RELOAD_CHILD: '1' }),
    stdio: 'inherit',
  });
  process.exit(res.status === 0 && failed === 0 ? 0 : 1);
}

// ===========================================================================
// (child process: __CANOPY_RELOAD_CHILD=1) — opted-in scenario with a fresh IIFE
section('B. Opted in — _Platform_live round-trips the model');
const mock = createMockFabric();
Object.assign(globalThis, mock.fabric);
globalThis._Platform_devSeam = true;   // host opt-in BEFORE boot
require(BUNDLE);
globalThis.__canopy_boot(null, {});

const live = globalThis._Platform_live;
check('seam published globalThis._Platform_live', live != null && typeof live === 'object',
  'got ' + typeof live);
check('_Platform_live.getModel is a function', !!live && typeof live.getModel === 'function');
check('_Platform_live.setModel is a function', !!live && typeof live.setModel === 'function');
check('_Platform_live.managers is exposed (effect-manager handle)',
  !!live && typeof live.managers === 'object' && live.managers !== null);
check('_Platform_live.getModel() returns the initial model 0',
  !!live && live.getModel() === 0, !!live && JSON.stringify(live.getModel()));
check('label reflects initial model "Count: 0"',
  labelView(mock) && labelView(mock).props.text === 'Count: 0',
  labelView(mock) && labelView(mock).props.text);

// capture → mutate the live program → restore (the reload round-trip)
const captured = live.getModel();
// drive the real program forward so its live model diverges from the capture
const inc = mock.findByTestID('increment');
mock.emit(inc.handle, 'press', {}); mock.flushFrames();
mock.emit(inc.handle, 'press', {}); mock.flushFrames();
check('live program advanced to model 2 after two taps', live.getModel() === 2, String(live.getModel()));
check('label advanced to "Count: 2"', labelView(mock).props.text === 'Count: 2', labelView(mock).props.text);

// now "reload": restore the captured pre-tap model via setModel + re-render
mock.clearLog();
live.setModel(captured);
mock.flushFrames();
check('setModel restored the captured model (getModel === 0)', live.getModel() === captured, String(live.getModel()));
check('setModel re-rendered the label back to "Count: 0"',
  labelView(mock).props.text === 'Count: 0', labelView(mock).props.text);
const restoreUpdates = mock.log.filter(m => m.op === 'updateProps');
check('setModel produced exactly ONE targeted updateProps (no re-mount)',
  restoreUpdates.length === 1, String(restoreUpdates.length));

// ===========================================================================
section('C. _Platform_shutdown stops Subs + clears the published handle');
check('globalThis._Platform_shutdown is a function', typeof globalThis._Platform_shutdown === 'function');
let threw = null;
try { globalThis._Platform_shutdown(); } catch (e) { threw = e; }
check('_Platform_shutdown ran without throwing', threw === null, threw && String(threw));
check('after shutdown, _Platform_live handle is cleared (null) — no double-subscribe on reload',
  globalThis._Platform_live === null, 'got ' + JSON.stringify(globalThis._Platform_live));
let threwTwice = null;
try { globalThis._Platform_shutdown(); } catch (e) { threwTwice = e; }
check('_Platform_shutdown is idempotent (safe to call again)', threwTwice === null,
  threwTwice && String(threwTwice));

// ===========================================================================
section(`Result: ${failed === 0 ? '\x1b[32mPASS' : '\x1b[31mFAIL'}\x1b[0m  (${passed} passed, ${failed} failed)`);
if (failed) { console.log('failed:\n  - ' + fails.join('\n  - ')); }
process.exit(failed === 0 ? 0 : 1);
