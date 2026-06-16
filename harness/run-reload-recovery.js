#!/usr/bin/env node
// run-reload-recovery.js — DEV-11: error overlay in the loop + reload-FAILURE recovery.
//
// DEV-2 (run-reload-seam.js) + DEV-8 (run-reload-typehash.js) gave us a state-preserving reload that
// works when the new bundle is GOOD. DEV-11 closes the FAILURE case: a reload whose new bundle throws
// on eval / boot / first render must NOT leave the user on a fatal red-box with a dead program — it
// must keep the prior good state recoverable, so the dev loop lands the user back where they were once
// a good bundle arrives again. native.js owns the JS half of that recovery; this harness drives it.
//
// The reload-failure recovery primitives native.js publishes at boot (alongside the DEV-2 seam):
//   • __canopy_captureState()    — now ALSO records the live model as the last-known-good snapshot,
//                                  taken while the OLD good program is still on screen (the ideal
//                                  moment, before teardown);
//   • __canopy_hasLastGood()     — Bool: is a good snapshot available to recover to;
//   • __canopy_recoverLastGood() — restore the last-good snapshot into the live program (type-hash
//                                  gated, exactly like remount), returning whether it recovered;
//   • __canopy_snapshotGood()    — re-snapshot the current live state (called by remount on a
//                                  SUCCESSFUL reload so the baseline advances);
//   • __canopy_setSourcemap(map) — install the WS `map` field onto __canopy_sourcemap + reset the
//                                  symbolicator cache, so a post-reload red-box resolves against the
//                                  reloaded program's own map (the "pipe the WS map" requirement).
//
// This harness drives the REAL assembled counter bundle over ONE runtime (exactly as a device host
// does with evaluateJavaScript) through:
//   A. setup — boot, advance the model, confirm the recovery functions are installed
//   B. captureState records the last-known-good snapshot (the pre-teardown good state)
//   C. a FAILED reload (the new "bundle" throws) leaves the prior good tree UP and the snapshot intact
//   D. recovery — re-eval the GOOD (last-good) bundle, re-boot, recoverLastGood() restores the state
//   E. a SUCCESSFUL reload advances the last-good baseline (recoverLastGood would now restore THAT)
//   F. setSourcemap pipes a fresh map and re-points the symbolicator at it (auto-dismiss alignment)
//   G. release-safety — with no live program the recovery seam is inert (no snapshot leaks)
//
// Prereq: a counter DEBUG bundle built from the DEV-2/DEV-8 native.js:
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
// Walk the LIVE (attached) tree from the root and return the "Count: N" label view — never a stale
// detached view the mock still keeps in its map after a teardown's removeChild.
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

// The native host's pre-re-eval reset: clear the Elm registry so the compiler's _Platform_export does
// not reject a duplicate Elm.Main on the same runtime (the same step run-reload-seam.js models).
function hostReset() {
  globalThis.Elm = undefined;
  if (globalThis.scope) { globalThis.scope.Elm = undefined; }
}

// ===========================================================================
section('A. Boot the debug bundle + the DEV-11 recovery seam is installed');

const mock = createMockFabric();
Object.assign(globalThis, mock.fabric);
vm.runInThisContext(SRC, { filename: 'canopy.bundle.js' });
check('bundle installed the __canopy_boot hook', typeof globalThis.__canopy_boot === 'function');
globalThis.__canopy_boot(null, {});

check('__canopy_captureState installed', typeof globalThis.__canopy_captureState === 'function');
check('__canopy_recoverLastGood installed (DEV-11)', typeof globalThis.__canopy_recoverLastGood === 'function');
check('__canopy_hasLastGood installed (DEV-11)', typeof globalThis.__canopy_hasLastGood === 'function');
check('__canopy_snapshotGood installed (DEV-11)', typeof globalThis.__canopy_snapshotGood === 'function');
check('__canopy_setSourcemap installed (DEV-11)', typeof globalThis.__canopy_setSourcemap === 'function');

const rootTag = mock.rootHandle;
check('initial label is "Count: 0"', liveLabel(mock) && liveLabel(mock).props.text === 'Count: 0',
  liveLabel(mock) && liveLabel(mock).props.text);
check('no last-good snapshot before the first reload (nothing captured yet)',
  globalThis.__canopy_hasLastGood() === false, String(globalThis.__canopy_hasLastGood()));

// Advance the live model so it diverges from init — this is the "good" state we must recover to.
const inc = mock.findByTestID('increment');
mock.emit(inc.handle, 'press', {}); mock.flushFrames();
mock.emit(inc.handle, 'press', {}); mock.flushFrames();
mock.emit(inc.handle, 'press', {}); mock.flushFrames();
check('three taps advanced the live model to 3', globalThis._Platform_live.getModel() === 3,
  String(globalThis._Platform_live.getModel()));
check('label advanced to "Count: 3"', liveLabel(mock).props.text === 'Count: 3', liveLabel(mock).props.text);

// ===========================================================================
section('B. captureState records the last-known-good snapshot (pre-teardown good state)');

const captured = globalThis.__canopy_captureState();
check('captureState returned the live carrier (model 3)', captured && captured.model === 3,
  captured && JSON.stringify(captured));
check('captureState recorded a last-good snapshot is now available',
  globalThis.__canopy_hasLastGood() === true, String(globalThis.__canopy_hasLastGood()));

// ===========================================================================
section('C. A FAILED reload leaves the prior good tree UP + the snapshot intact (no fatal wipe)');

// The host's reload sequence is: captureState (done) -> teardown -> host re-eval(newBundle). DEV-11's
// posture is that the dev client does NOT tear down on the failure path: when the new bundle is known-
// bad (a compile error surfaced as {type:error}, or the eval throws), the prior good NATIVE tree stays
// mounted under the red-box. We model that here by NOT calling teardown and asserting the good tree is
// still on screen + the snapshot is still recoverable, so the dev loop can recover when a good bundle
// arrives. (A throw mid-eval is the host-guarded path; the JS-observable invariant we own is that the
// last-good snapshot survives a failed reload, which it does because nothing cleared it.)
let evalThrew = null;
try {
  // a "new bundle" that throws on eval — exactly what guardJsCall catches as a fatal red-box.
  vm.runInThisContext('throw new Error("compile/eval error in the new bundle");',
    { filename: 'canopy.bundle.js (reload)' });
} catch (e) { evalThrew = e; }
check('the bad bundle threw on eval (the failure the host red-boxes)', evalThrew !== null);
check('the prior good program is STILL live after the failed eval (not torn down)',
  globalThis._Platform_live != null && globalThis._Platform_live.getModel() === 3,
  globalThis._Platform_live && String(globalThis._Platform_live.getModel()));
check('the prior good tree is STILL on screen ("Count: 3")',
  liveLabel(mock) && liveLabel(mock).props.text === 'Count: 3', liveLabel(mock) && liveLabel(mock).props.text);
check('the last-good snapshot SURVIVED the failed reload (recoverable)',
  globalThis.__canopy_hasLastGood() === true, String(globalThis.__canopy_hasLastGood()));

// ===========================================================================
section('D. Recovery — re-eval the GOOD bundle, re-boot, recoverLastGood() restores the good state');

// The dev client retains the last-GOOD bundle bytes; when the user fixes the error (or to recover from
// a failed reload), the host re-evals THAT good bundle, re-boots onto the same root, then recovers.
// First we must tear the (still-live) old program down so the re-eval's Elm.Main is accepted, exactly
// as the real reload does. teardown after a failed reload is fine — the snapshot already survived it.
globalThis.__canopy_teardown();
check('teardown stopped the old program (_Platform_live === null)', globalThis._Platform_live === null);
check('the last-good snapshot SURVIVED teardown too (the recovery baseline persists)',
  globalThis.__canopy_hasLastGood() === true, String(globalThis.__canopy_hasLastGood()));

hostReset();
vm.runInThisContext(SRC, { filename: 'canopy.bundle.js (good reload)' });
globalThis.__canopy_boot(rootTag, {});
check('the recovered program re-booted at its init model (Count: 0)',
  liveLabel(mock) && liveLabel(mock).props.text === 'Count: 0', liveLabel(mock) && liveLabel(mock).props.text);

mock.clearLog();
const recovered = globalThis.__canopy_recoverLastGood();
mock.flushFrames();
check('recoverLastGood reported it restored the snapshot', recovered === true, String(recovered));
check('recoverLastGood restored the live model to the last-good 3',
  globalThis._Platform_live.getModel() === 3, String(globalThis._Platform_live.getModel()));
check('recoverLastGood re-rendered the label back to "Count: 3" (user lands where they were)',
  liveLabel(mock).props.text === 'Count: 3', liveLabel(mock).props.text);
const recoverCreates = mock.log.filter(m => m.op === 'createView');
check('recovery created ZERO new views for the unchanged subtree (targeted, not a re-mount)',
  recoverCreates.length === 0, String(recoverCreates.length));

// the recovered program is fully live: a tap drives it forward from the restored model
mock.clearLog();
const inc2 = liveByTestID(mock, 'increment');
check('the live increment button is reachable from the recovered root', inc2 != null);
mock.emit(inc2.handle, 'press', {}); mock.flushFrames();
check('the recovered program is live: a tap advances "Count: 3" -> "Count: 4"',
  liveLabel(mock).props.text === 'Count: 4', liveLabel(mock).props.text);

// ===========================================================================
section('E. A SUCCESSFUL reload advances the last-good baseline (recover would restore THAT)');

// model is now 4 (the live good state). A successful reload via the DEV-2 path must re-snapshot this
// as the new last-good, so a later failed reload recovers to 4, not the stale 3.
const cap4 = globalThis.__canopy_captureState();        // captures + snapshots 4
check('captureState snapshotted the advanced good model (4)', cap4 && cap4.model === 4,
  cap4 && JSON.stringify(cap4));
globalThis.__canopy_teardown();
hostReset();
vm.runInThisContext(SRC, { filename: 'canopy.bundle.js (reload 2)' });
globalThis.__canopy_boot(rootTag, {});
const remounted = globalThis.__canopy_remount(cap4);    // remount re-snapshots good on success
mock.flushFrames();
check('the successful reload restored the model (4)', remounted === true && globalThis._Platform_live.getModel() === 4,
  String(remounted) + '/' + String(globalThis._Platform_live.getModel()));
// Prove the baseline advanced: a recover NOW (with the live program) restores 4, not the earlier 3.
globalThis._Platform_live.setModel(99);                 // perturb the live model
mock.flushFrames();
const recovered4 = globalThis.__canopy_recoverLastGood();
mock.flushFrames();
check('recoverLastGood after a successful reload restores the ADVANCED baseline (4, not 3)',
  recovered4 === true && globalThis._Platform_live.getModel() === 4,
  String(recovered4) + '/' + String(globalThis._Platform_live.getModel()));

// ===========================================================================
section('F. setSourcemap pipes the WS map into __canopy_sourcemap + re-points the symbolicator');

// A reload bundle the dev loop pushes is raw compiler JS that does NOT re-stamp the trailing
// __canopy_sourcemap global; the map travels as the WS `map` field instead. setSourcemap installs it
// and resets the symbolicator cache so a post-reload red-box resolves against the NEW map. We prove
// the new map takes effect even though an OLD map was already cached (the cache-reset is the bug DEV-11
// fixes: without it, the new bundle's frames symbolicate against the old line table).
const oldMap = JSON.stringify({
  version: 3, file: 'canopy.bundle.js', sources: ['Old.can'], sourcesContent: [''], names: [],
  mappings: ';;AAAA',   // genLine 2 -> Old.can:1
});
const newMap = JSON.stringify({
  version: 3, file: 'canopy.bundle.js', sources: ['New.can'], sourcesContent: [''], names: [],
  mappings: ';;AAAA',   // genLine 2 -> New.can:1
});
globalThis.__canopy_setSourcemap(oldMap);
const sym1 = globalThis.__canopy_symbolicate('at f (canopy.bundle.js:3:1)');
check('symbolicate resolves against the first piped map (Old.can:1)', sym1.includes('Old.can:1'), sym1);
// Now pipe a DIFFERENT map (the post-reload map). Without the cache reset the old index would persist.
globalThis.__canopy_setSourcemap(newMap);
const sym2 = globalThis.__canopy_symbolicate('at f (canopy.bundle.js:3:1)');
check('a freshly piped map RE-POINTS the symbolicator (New.can:1, cache reset worked)',
  sym2.includes('New.can:1') && !sym2.includes('Old.can'), sym2);
// A null/empty map clears the global so a stale map never symbolicates the next error (an --optimize
// reload carries no map).
globalThis.__canopy_setSourcemap(null);
const sym3 = globalThis.__canopy_symbolicate('at f (canopy.bundle.js:3:1)');
check('piping a null map clears it → the stack is returned unchanged (no stale symbolication)',
  sym3 === 'at f (canopy.bundle.js:3:1)', sym3);

// ===========================================================================
section('G. Release-safety — with no live program the recovery seam is inert');

globalThis.__canopy_teardown();      // tear the program down for good
check('no live program after teardown (_Platform_live === null)', globalThis._Platform_live === null);
let recoverNoLive = null, recoverNoLiveRet;
try { recoverNoLiveRet = globalThis.__canopy_recoverLastGood(); } catch (e) { recoverNoLive = e; }
check('recoverLastGood with no live program is a no-op returning false (no throw)',
  recoverNoLive === null && recoverNoLiveRet === false,
  recoverNoLive ? String(recoverNoLive) : 'ret=' + recoverNoLiveRet);
let snapNoLive = null, snapNoLiveRet;
try { snapNoLiveRet = globalThis.__canopy_snapshotGood(); } catch (e) { snapNoLive = e; }
check('snapshotGood with no live program is a no-op returning false (nothing leaks)',
  snapNoLive === null && snapNoLiveRet === false,
  snapNoLive ? String(snapNoLive) : 'ret=' + snapNoLiveRet);
check('a snapshotGood no-op left the PRIOR good snapshot intact (did not clobber it with null)',
  globalThis.__canopy_hasLastGood() === true, String(globalThis.__canopy_hasLastGood()));

// ===========================================================================
section(`Result: ${failed === 0 ? '\x1b[32mPASS' : '\x1b[31mFAIL'}\x1b[0m  (${passed} passed, ${failed} failed)`);
if (failed) { console.log('failed:\n  - ' + fails.join('\n  - ')); }
process.exit(failed === 0 ? 0 : 1);
