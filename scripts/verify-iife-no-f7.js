#!/usr/bin/env node
// verify-iife-no-f7.js — CI-2 acceptance gate: prove the IIFE bundle the native host ships does
// NOT throw a ReferenceError (the `F7 is not defined` / `_Platform_export is not defined`
// tree-shaker regression CMP-1 fixed — see docs/compiler-fixes.md §1).
//
// It loads the REAL assembled bundle (preamble + compiled IIFE + boot hook) produced by the pinned
// compiler under the SAME mock Fabric the renderer harness uses, then BOOTS it. A dropped arity
// helper (F2..F9), program-export call (_Platform_export), or kernel id surfaces as a ReferenceError
// at module-eval or at __canopy_boot — both are caught here and fail the build with a clear message.
//
// Usage:  CANOPY_BUNDLE=<path/to/canopy.bundle.js> node scripts/verify-iife-no-f7.js
'use strict';

const path = require('path');
const fs = require('fs');
const { createMockFabric } = require(path.resolve(__dirname, '../harness/mock-fabric'));

const BUNDLE = process.env.CANOPY_BUNDLE;
if (!BUNDLE) { console.error('set CANOPY_BUNDLE to the assembled bundle path'); process.exit(2); }
if (!fs.existsSync(BUNDLE)) { console.error('bundle not found: ' + BUNDLE); process.exit(2); }

function fail(msg) { console.error('  \x1b[31mFAIL\x1b[0m ' + msg); process.exit(1); }
function pass(msg) { console.log('  \x1b[32mOK\x1b[0m   ' + msg); }

// Install the mock host globals BEFORE evaluating the bundle (the IIFE binds them at eval time).
const mock = createMockFabric();
Object.assign(globalThis, mock.fabric);

// 1. Evaluate the bundle. A dropped runtime symbol that the top-level references throws here.
try {
  require(path.resolve(BUNDLE));
} catch (e) {
  if (e instanceof ReferenceError) {
    fail('bundle eval threw ReferenceError: ' + e.message +
         '\n       => the pinned compiler dropped a runtime symbol (F7/arity/export). ' +
         'The pin is missing the CMP-1 tree-shaker root-scan fix.');
  }
  fail('bundle eval threw: ' + (e && e.stack ? e.stack : e));
}
if (typeof globalThis.__canopy_boot !== 'function') {
  fail('bundle did not install __canopy_boot — not a valid native host bundle');
}
pass('bundle evaluated with no ReferenceError; __canopy_boot installed');

// 2. Boot it. Most emitted-but-tree-shaken refs (e.g. F7 used by _Json_map6, _Platform_export
//    appended after root collection) only fire on the boot/update path — this is the real proof.
try {
  globalThis.__canopy_boot(null, {});
} catch (e) {
  if (e instanceof ReferenceError) {
    fail('__canopy_boot threw ReferenceError: ' + e.message +
         '\n       => a generator-emitted symbol was tree-shaken out (the F7 regression).');
  }
  fail('__canopy_boot threw: ' + (e && e.stack ? e.stack : e));
}
if (typeof globalThis.__canopy_dispatchEvent !== 'function') {
  fail('boot did not install __canopy_dispatchEvent — the program did not start');
}

// 3. Sanity: the program actually mounted a native tree (a no-op boot would also "not throw").
const created = mock.log.filter(m => m.op === 'createView');
if (created.length === 0) fail('boot created zero views — program did not render');

pass('booted; ' + created.length + ' native views mounted; no F7/ReferenceError on the boot path');
console.log('\x1b[1mF7 GATE: PASS\x1b[0m — the pinned compiler\'s IIFE bundle does not throw "F7 is not defined".');
process.exit(0);
