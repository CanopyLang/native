#!/usr/bin/env node
// run-reload-typehash.js — DEV-8: true state-preserving Fast Refresh + Model type-hash fallback.
//
// DEV-2 (run-reload-seam.js) gave us the WALKER half of a state-preserving reload:
// __canopy_captureState / __canopy_teardown / __canopy_remount let a debug host tear a program
// down and re-mount onto the SAME Fabric root over ONE Hermes runtime, restoring the live TEA
// model so the user lands back where they were. DEV-2 always restored the captured model — which
// is correct ONLY when the new bundle's Model type is the SAME shape as the old one. When an edit
// changes the Model type (adds/removes/retypes a field), feeding the new update/view the old
// model decodes/indexes a structurally-wrong value and crashes on the very next frame.
//
// DEV-8 closes that gap with the compiler's structural Model type-hash. The compiler stamps a
// deterministic `__canopy_model_typehash` on the host global (a hash of the Model TYPE's shape,
// not its value); native.js's reload seam now:
//   • captureState() stamps the OLD bundle's hash into the carrier { model, typehash }, read while
//     the old bundle's global is still in scope (before the host re-evals the new bundle);
//   • remount(state) compares the captured hash with the NEW bundle's hash:
//       - EQUAL (or both null — a pre-DEV-8 compiler) → the Model shape is unchanged, so restore
//         the captured model (the DEV-2 win, now provably type-safe);
//       - DIFFERENT → keep the freshly-booted INIT model (no setModel), and post a 'Model changed'
//         notice on globalThis.__canopy_reloadNotice for the host to toast. A clean, crash-free
//         reset — never a hard fault.
//
// COMPILER DEP (honest note): the compiler emission of __canopy_model_typehash is a SEPARATE lane
// (compiler-owned) and has NOT landed yet — the real counter bundle carries no such global. So this
// harness INJECTS the hash onto the global at the two moments the compiler will (before capture =
// the old bundle's hash; after re-eval/re-boot = the new bundle's hash). That is faithful: native.js
// reads the hash from EXACTLY that global, so injecting it exercises the real preserve-vs-reset
// decision against the REAL assembled walker + bundle. When the compiler lands the emission, the
// only change is that the global is set by the bundle instead of by this harness — the native.js
// logic under test is identical. We additionally prove the BACKWARD-COMPAT path (no hash emitted at
// all → preserve, exactly as DEV-2 did) so a pre-DEV-8 bundle never regresses.
//
// Drives the REAL assembled debug bundle (same one run-reload-seam.js uses) through the full reload
// loop over ONE runtime, twice (compatible + incompatible), plus the backward-compat path:
//   A. setup — boot, advance the model, confirm the seam + functions are installed
//   B. COMPATIBLE reload (same Model type-hash) → state PRESERVED, no 'Model changed' notice
//   C. INCOMPATIBLE reload (different Model type-hash) → state RESET to init + 'Model changed' notice
//   D. captureState stamps the live type-hash into the carrier (read while the old global is in scope)
//   E. BACKWARD-COMPAT — no __canopy_model_typehash on either side → preserve (the DEV-2 behavior)
//
// Prereq: a counter DEBUG bundle built from the DEV-3-patched compiler + DEV-2/DEV-8 native.js:
//   canopy-native build examples/counter

'use strict';

const path = require('path');
const fs = require('fs');
const vm = require('vm');
const { createMockFabric } = require('./mock-fabric');

const BUNDLE = path.resolve(__dirname, '../examples/counter/build/canopy.bundle.js');
if (!fs.existsSync(BUNDLE)) {
  console.error('assembled bundle not found — run `canopy-native build examples/counter` first:\n  ' + BUNDLE);
  process.exit(2);
}
const SRC = fs.readFileSync(BUNDLE, 'utf8');

// ---- tiny assertion harness ------------------------------------------------
let passed = 0, failed = 0; const fails = [];
function check(name, cond, detail) {
  if (cond) { passed++; console.log(`  \x1b[32m✓\x1b[0m ${name}`); }
  else { failed++; fails.push(name); console.log(`  \x1b[31m✗\x1b[0m ${name}${detail ? '  — ' + detail : ''}`); }
}
function section(t) { console.log(`\n\x1b[1m${t}\x1b[0m`); }

// the mock does not expose its view map directly; reconstruct the set from every tag we use
function allViews(mock) {
  const out = [];
  for (const tag of ['RCTRootView', 'RCTView', 'RCTText', 'RCTRawText']) out.push(...mock.findByTag(tag));
  return out;
}
// Walk the LIVE (attached) tree from the root and return the "Count: N" label view, so we never
// read a stale detached view the mock still keeps in its map after a teardown's removeChild.
function liveLabel(mock) {
  const byHandle = new Map(allViews(mock).map(v => [v.handle, v]));
  const seen = new Set();
  function walk(handle) {
    if (handle == null || seen.has(handle)) return null;
    seen.add(handle);
    const v = byHandle.get(handle);
    if (!v) return null;
    if (v.tag === 'RCTText' && typeof v.props.text === 'string' && /^Count:/.test(v.props.text)) return v;
    for (const c of v.children) { const r = walk(c); if (r) return r; }
    return null;
  }
  return walk(mock.rootHandle);
}
function liveByTestID(mock, id) {
  const byHandle = new Map(allViews(mock).map(v => [v.handle, v]));
  const seen = new Set();
  function walk(handle) {
    if (handle == null || seen.has(handle)) return null;
    seen.add(handle);
    const v = byHandle.get(handle);
    if (!v) return null;
    if (v.props && v.props.testID === id) return v;
    for (const c of v.children) { const r = walk(c); if (r) return r; }
    return null;
  }
  return walk(mock.rootHandle);
}

// One full reload over the SAME runtime, threading a (oldHash → newHash) pair to model the compiler
// stamping __canopy_model_typehash. Returns the captured carrier + whether remount restored, so each
// scenario can assert preserve-vs-reset. `newHash`/`oldHash` of `undefined` means "do NOT set the
// global" (the backward-compat / pre-DEV-8 path); otherwise the value is stamped on the global at the
// moment the compiler would (oldHash before capture, newHash after re-eval+re-boot).
function reloadOnce(mock, rootTag, oldHash, newHash) {
  // The compiler stamps the OLD bundle's Model type-hash on the global; native.js reads it inside
  // captureState. Set it now (or delete it for the no-hash path) so capture sees exactly what a real
  // old bundle would have published.
  if (oldHash === undefined) delete globalThis.__canopy_model_typehash;
  else globalThis.__canopy_model_typehash = oldHash;

  const captured = globalThis.__canopy_captureState();
  globalThis.__canopy_teardown();

  // host reset before the in-process re-eval (the compiler's _Platform_export rejects a duplicate
  // Elm.Main on the same runtime) — exactly what the Android/iOS host does.
  globalThis.Elm = undefined;
  if (globalThis.scope) globalThis.scope.Elm = undefined;

  // clear any notice from a prior scenario so we assert THIS reload's notice (or absence of one)
  delete globalThis.__canopy_reloadNotice;

  vm.runInThisContext(SRC, { filename: 'canopy.bundle.js (reload)' });

  // The NEW bundle publishes ITS Model type-hash. Set it AFTER re-eval+boot (the compiler would emit
  // it as the bundle evaluates). Set before remount so the gate sees the new shape.
  if (newHash === undefined) delete globalThis.__canopy_model_typehash;
  else globalThis.__canopy_model_typehash = newHash;

  globalThis.__canopy_boot(rootTag, {});
  // Measure the REMOUNT step in isolation: clear the log after the re-boot (which legitimately
  // re-creates the program's own subtree once) so `remountLog` reflects ONLY what restoring the
  // model did. A compatible restore must be a targeted re-render (zero createView, no structural
  // insert/remove of the unchanged subtree) — the §8 reload criterion.
  mock.clearLog();
  const restored = globalThis.__canopy_remount(captured);
  mock.flushFrames();
  const remountLog = mock.log.slice();
  return { captured, restored, remountLog };
}

// ===========================================================================
section('A. Setup — boot the debug bundle, advance the model, confirm the seam is installed');

const mock = createMockFabric();
Object.assign(globalThis, mock.fabric);
// no _Platform_devSeam set: native.js auto-enables it in this DEBUG bundle
vm.runInThisContext(SRC, { filename: 'canopy.bundle.js' });
check('bundle installed the __canopy_boot hook', typeof globalThis.__canopy_boot === 'function');
globalThis.__canopy_boot(null, {});
const rootTag = mock.rootHandle;

check('__canopy_captureState installed', typeof globalThis.__canopy_captureState === 'function');
check('__canopy_remount installed', typeof globalThis.__canopy_remount === 'function');
check('initial label is "Count: 0"', liveLabel(mock) && liveLabel(mock).props.text === 'Count: 0',
  liveLabel(mock) && liveLabel(mock).props.text);

// advance the live model so a PRESERVED reload is visibly different from a RESET one
const inc = mock.findByTestID('increment');
mock.emit(inc.handle, 'press', {}); mock.flushFrames();
mock.emit(inc.handle, 'press', {}); mock.flushFrames();
mock.emit(inc.handle, 'press', {}); mock.flushFrames();
check('three taps advanced the live model to 3', globalThis._Platform_live.getModel() === 3,
  String(globalThis._Platform_live.getModel()));
check('label advanced to "Count: 3"', liveLabel(mock).props.text === 'Count: 3', liveLabel(mock).props.text);

// ===========================================================================
section('B. COMPATIBLE reload (same Model type-hash) → model state is PRESERVED, no notice');

// identical structural hash on both sides: the Model type did not change shape across the edit.
const r1 = reloadOnce(mock, rootTag, 'modelhash:counter:v1', 'modelhash:counter:v1');
check('remount reported it RESTORED the model (compatible hash)', r1.restored === true, String(r1.restored));
check('live model preserved across the compatible reload (still 3)',
  globalThis._Platform_live.getModel() === 3, String(globalThis._Platform_live.getModel()));
check('label preserved across the compatible reload ("Count: 3")',
  liveLabel(mock).props.text === 'Count: 3', liveLabel(mock).props.text);
check('NO "Model changed" notice posted on a compatible reload',
  globalThis.__canopy_reloadNotice == null, JSON.stringify(globalThis.__canopy_reloadNotice));
// the MODEL RESTORE itself (measured in isolation by reloadOnce) is a pure targeted re-render of the
// unchanged subtree: ZERO createView, ZERO structural insert/remove, exactly ONE updateProps (the
// label text). This is the §8 reload criterion — the re-boot rebuilt the subtree once, but landing
// the user back at the preserved model adds no re-mount on top of that.
const r1RestoreCreates = r1.remountLog.filter(m => m.op === 'createView').length;
const r1RestoreStructural = r1.remountLog.filter(m => m.op === 'insertChild' || m.op === 'removeChild').length;
const r1RestoreUpdates = r1.remountLog.filter(m => m.op === 'updateProps').length;
check('model restore created ZERO new views (the §8 reload criterion)', r1RestoreCreates === 0,
  String(r1RestoreCreates));
check('model restore did ZERO structural insert/remove (no re-mount of the subtree)',
  r1RestoreStructural === 0, String(r1RestoreStructural));
check('model restore landed via exactly ONE targeted updateProps', r1RestoreUpdates === 1,
  String(r1RestoreUpdates) + ': ' + JSON.stringify(r1.remountLog.filter(m => m.op === 'updateProps').map(u => u.props)));
// the reloaded program is live: a tap advances FROM the preserved value
mock.clearLog();
const incB = liveByTestID(mock, 'increment');
check('the live increment button is reachable from the re-booted root', incB != null);
mock.emit(incB.handle, 'press', {}); mock.flushFrames();
check('a tap advances the PRESERVED state "Count: 3" -> "Count: 4"',
  liveLabel(mock).props.text === 'Count: 4', liveLabel(mock).props.text);

// ===========================================================================
section('C. INCOMPATIBLE reload (different Model type-hash) → state RESET to init + "Model changed"');

// model is at 4 now; an incompatible reload must DROP it and land on the new program's init (0).
check('pre-reload live model is 4', globalThis._Platform_live.getModel() === 4,
  String(globalThis._Platform_live.getModel()));
mock.clearLog();
// DIFFERENT structural hash: the Model type changed shape (e.g. a field added). Restoring the old
// model would be unsafe, so native.js must keep the fresh init model + post the notice.
const r2 = reloadOnce(mock, rootTag, 'modelhash:counter:v1', 'modelhash:counter:v2-INCOMPATIBLE');
check('remount reported it did NOT restore (incompatible hash → fresh init)', r2.restored === false,
  String(r2.restored));
check('live model RESET to the new program init (0), not the dropped 4',
  globalThis._Platform_live.getModel() === 0, String(globalThis._Platform_live.getModel()));
check('label RESET to "Count: 0" (incompatible state was discarded, no crash)',
  liveLabel(mock).props.text === 'Count: 0', liveLabel(mock).props.text);
const notice = globalThis.__canopy_reloadNotice;
check('a reload notice was posted for the host to toast', notice != null && typeof notice === 'object',
  JSON.stringify(notice));
check('the notice kind is "modelChanged"', notice && notice.kind === 'modelChanged', notice && notice.kind);
check('the notice carries a "Model changed" message', notice && /Model changed/i.test(notice.message),
  notice && notice.message);
// the reset program is fully live: a tap advances from the fresh 0
mock.clearLog();
const incC = liveByTestID(mock, 'increment');
mock.emit(incC.handle, 'press', {}); mock.flushFrames();
check('the reset program is live: a tap advances "Count: 0" -> "Count: 1"',
  liveLabel(mock).props.text === 'Count: 1', liveLabel(mock).props.text);

// ===========================================================================
section('D. captureState stamps the live Model type-hash into the carrier (read off the old global)');

// the live model is 1 now; set a hash on the global and confirm captureState reads + carries it.
globalThis.__canopy_model_typehash = 'modelhash:probe:v9';
const probe = globalThis.__canopy_captureState();
check('captureState returned a carrier', probe != null && typeof probe === 'object', JSON.stringify(probe));
check('carrier carries the live model (1)', probe && probe.model === 1, probe && JSON.stringify(probe.model));
check('carrier stamps the CURRENT global type-hash', probe && probe.typehash === 'modelhash:probe:v9',
  probe && probe.typehash);
// a carrier captured with NO hash on the global stamps null (the pre-DEV-8 shape round-trips)
delete globalThis.__canopy_model_typehash;
const probeNoHash = globalThis.__canopy_captureState();
check('captureState with no hash on the global stamps typehash: null',
  probeNoHash && probeNoHash.typehash === null, probeNoHash && JSON.stringify(probeNoHash.typehash));

// ===========================================================================
section('E. BACKWARD-COMPAT — no type-hash emitted on either side → PRESERVE (the DEV-2 behavior)');

// advance the model again so a preserve is visible
mock.clearLog();
const incE = liveByTestID(mock, 'increment');
mock.emit(incE.handle, 'press', {}); mock.flushFrames();   // 1 -> 2
mock.emit(incE.handle, 'press', {}); mock.flushFrames();   // 2 -> 3
check('model advanced to 3 before the backward-compat reload',
  globalThis._Platform_live.getModel() === 3, String(globalThis._Platform_live.getModel()));
mock.clearLog();
// undefined on BOTH sides = the compiler never emits the hash (a pre-DEV-8 bundle). Both hashes
// resolve to null → equal → preserve. No regression from DEV-2.
const r3 = reloadOnce(mock, rootTag, undefined, undefined);
check('remount RESTORED with no hash on either side (null === null → preserve)', r3.restored === true,
  String(r3.restored));
check('carrier had typehash: null (pre-DEV-8 shape)', r3.captured && r3.captured.typehash === null,
  r3.captured && JSON.stringify(r3.captured.typehash));
check('live model preserved across the no-hash reload (still 3)',
  globalThis._Platform_live.getModel() === 3, String(globalThis._Platform_live.getModel()));
check('label preserved ("Count: 3")', liveLabel(mock).props.text === 'Count: 3', liveLabel(mock).props.text);
check('NO "Model changed" notice on the backward-compat path',
  globalThis.__canopy_reloadNotice == null, JSON.stringify(globalThis.__canopy_reloadNotice));

// ===========================================================================
section(`Result: ${failed === 0 ? '\x1b[32mPASS' : '\x1b[31mFAIL'}\x1b[0m  (${passed} passed, ${failed} failed)`);
if (failed) { console.log('failed:\n  - ' + fails.join('\n  - ')); }
process.exit(failed === 0 ? 0 : 1);
