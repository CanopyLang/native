#!/usr/bin/env node
// run-compiled.js — the strongest local proof: drive the ACTUAL Canopy-compiler output
// (examples/counter/build/app.iife.js) against the mock Fabric.
//
// Unlike run.js (which uses a mini-runtime double), this loads the real IIFE bundle —
// the real core/runtime.js scheduler, the real tree-shaken external/native.js walker,
// and the real compiled Main — and asserts the §8 criteria end-to-end. If this passes,
// the compiler accepts the package AND the emitted JS drives Fabric correctly.
//
// Prereq: `cd examples/counter && canopy make src/Main.can --output=build/app.iife.js
//          --output-format=iife`  (or `canopy-native build examples/counter`).

'use strict';

const path = require('path');
const fs = require('fs');
const { createMockFabric } = require('./mock-fabric');

// The full assembled bundle (preamble + compiled IIFE + boot hook) produced by
// `canopy-native build examples/counter`. This is exactly what the RN host ships.
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

// ---- install the mock host BEFORE evaluating the bundle --------------------
const mock = createMockFabric();
Object.assign(globalThis, mock.fabric);   // __fabric_createView, etc.

// ---- evaluate the real assembled bundle (preamble defines the ABI + boot hook) ----
require(BUNDLE);
check('bundle installed the __canopy_boot hook', typeof globalThis.__canopy_boot === 'function');

// ---- boot the program the way the native host does: __canopy_boot(rootTag, flags) ----
// rootTag = null → the walker creates its own RCTRootView surface.
globalThis.__canopy_boot(null, {});
check('event dispatcher self-installed at boot', typeof globalThis.__canopy_dispatchEvent === 'function');

// ---------------------------------------------------------------------------
section('A. Real compiled program → native view tree');
process.stdout.write('\n' + mock.renderTree() + '\n');

function labelView() { return mock.findByTag('RCTText').find(v => /^Count:/.test(v.props.text)); }
check('a Fabric root was created + attached', mock.rootHandle != null);
check('RCTText label shows "Count: 0"', labelView() && labelView().props.text === 'Count: 0',
  labelView() && JSON.stringify(labelView().props.text));
const created = new Set(mock.log.filter(m => m.op === 'createView').map(m => m.tag));
check('every created view is a native RCT* component', [...created].every(t => /^RCT/.test(t)), [...created].join(', '));

// ---------------------------------------------------------------------------
section('B. Real gesture → real scheduler → ONE targeted updateProps');
const labelHandleBefore = labelView().handle;
const inc = mock.findByTestID('increment');
check('increment button is a native view with a press event', !!inc && Array.isArray(inc.events) && inc.events.includes('press'));

mock.clearLog();
mock.emit(inc.handle, 'press', {});  // dispatches into the REAL runtime
mock.flushFrames();

const since = mock.log;
const creates = since.filter(m => m.op === 'createView');
const updates = since.filter(m => m.op === 'updateProps');
const structural = since.filter(m => m.op === 'insertChild' || m.op === 'removeChild');

check('ZERO createView after tap (no re-mount)', creates.length === 0, `${creates.length}`);
check('ZERO structural insert/remove after tap', structural.length === 0, `${structural.length}`);
check('exactly ONE updateProps after tap', updates.length === 1,
  `${updates.length}: ` + JSON.stringify(updates.map(u => ({ tag: u.tag, props: u.props }))));
check('the update set the label text to "Count: 1"',
  updates.length === 1 && updates[0].props.text === 'Count: 1',
  updates.length === 1 ? JSON.stringify(updates[0].props) : '');
check('the same label handle was updated (identity preserved)',
  updates.length === 1 && updates[0].handle === labelHandleBefore);

// ---------------------------------------------------------------------------
section('C. Count + reset through the real update loop');
mock.emit(inc.handle, 'press', {}); mock.flushFrames();
check('second tap → "Count: 2"', labelView().props.text === 'Count: 2', labelView().props.text);
const reset = mock.findByTestID('reset');
mock.emit(reset.handle, 'press', {}); mock.flushFrames();
check('reset → "Count: 0"', labelView().props.text === 'Count: 0', labelView().props.text);
check('label never re-mounted across taps', labelView().handle === labelHandleBefore);

// ---------------------------------------------------------------------------
section(`Result: ${failed === 0 ? '\x1b[32mPASS' : '\x1b[31mFAIL'}\x1b[0m  (${passed} passed, ${failed} failed)`);
if (failed) { console.log('failed:\n  - ' + fails.join('\n  - ')); }
process.exit(failed === 0 ? 0 : 1);
