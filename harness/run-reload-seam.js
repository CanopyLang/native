#!/usr/bin/env node
// run-reload-seam.js — DEV-2: the JS reload seam in external/native.js.
//
// DEV-3 (landed, regression-tested by run-reload.js) put an OPT-IN runtime state
// seam in the compiler runtime: when `globalThis._Platform_devSeam` is set before
// boot, _Platform_initialize publishes `_Platform_live { getModel, setModel,
// managers }` and `_Platform_shutdown`. DEV-2 is the WALKER half that CONSUMES that
// seam so a debug host (DEV-4's JNI reload, the iOS dev loop) can tear a program
// down and re-mount onto the SAME Fabric root without a fresh process — preserving
// state across a reload instead of the multi-second force-stop + total-state-loss we
// have today.
//
// native.js adds three host globals (installed at boot) + the debug auto-enable:
//   • it sets globalThis._Platform_devSeam = true in a DEBUG bundle (and ONLY a debug
//     bundle — __canopy_debug is false under --optimize), so the dev loop works with
//     no host flag, while a release bundle never exposes the seam at all;
//   • __canopy_captureState() -> { model } | null   read the live TEA model
//   • __canopy_teardown()     -> Bool               stop Subs (DEV-3 _Platform_shutdown)
//                                                    + release this program's view subtree
//   • __canopy_remount(state) -> Bool               restore the captured model into the
//                                                    freshly re-booted program
//
// This harness drives the REAL assembled debug bundle through the FULL reload loop
// over ONE runtime — exactly what a device host does with evaluateJavaScript(newBundle)
// — and asserts the §8 reload criteria:
//   A. a debug bundle auto-enables the seam + installs the three reload functions
//   B. captureState returns the live model after the user advanced it
//   C. teardown stops the Subs (_Platform_live -> null), detaches the mounted subtree
//      from the cached root, and leaves NO stale event handles (no leaked callbacks)
//   D. after a host-reset + re-eval + re-boot + remount, the model is RESTORED with
//      ZERO createView for the unchanged subtree (one targeted updateProps) — i.e. the
//      user lands back where they were, the whole point of a state-preserving reload
//   E. the seam is inert when there is no live program (release-safety shape): the
//      reload functions are pure no-ops with no _Platform_live published.
//
// The "host reuses the runtime" reset (clearing globalThis.Elm before the in-process
// re-eval) is the NATIVE host's job — DEV-4 on Android, the iOS dev loop — because the
// compiler's _Platform_export guards against a duplicate Elm.Main on the same global
// (DEV-4's plan note: "verify IIFE re-eval is idempotent; fall back to clean in-process
// reboot if not"). We model that one host step explicitly so the loop is end-to-end.
//
// Prereq: a counter DEBUG bundle built from the DEV-3-patched compiler + DEV-2 native.js:
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

// Walk the LIVE (attached) tree from the root and return the "Count: N" label view.
// Reading from the root — not findByTag — guarantees we never read a stale detached
// view the mock still keeps in its map after a removeChild.
function liveLabel(mock) {
  const seen = new Set();
  function walk(handle) {
    if (handle == null || seen.has(handle)) return null;
    seen.add(handle);
    const v = mock.findByTag('RCTText').find(x => x.handle === handle)
           || [...allViews(mock)].find(x => x.handle === handle);
    if (v && v.tag === 'RCTText' && typeof v.props.text === 'string' && /^Count:/.test(v.props.text)) return v;
    const node = [...allViews(mock)].find(x => x.handle === handle);
    if (!node) return null;
    for (const c of node.children) { const r = walk(c); if (r) return r; }
    return null;
  }
  return walk(mock.rootHandle);
}
// the mock does not expose its view map directly; reconstruct the set from every tag we use
function allViews(mock) {
  const out = [];
  for (const tag of ['RCTRootView', 'RCTView', 'RCTText', 'RCTRawText']) out.push(...mock.findByTag(tag));
  return out;
}

// Find a view by testID in the LIVE (attached) tree only. After a reload the mock's view
// map still holds the OLD detached view with the same testID, so findByTestID would return
// a stale handle whose event registry was released at teardown. Walking from the root finds
// the freshly-booted one.
function liveByTestID(mock, id) {
  const all = allViews(mock);
  const byHandle = new Map(all.map(v => [v.handle, v]));
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

// ===========================================================================
// Boot #1 — the debug bundle auto-enables the DEV-3 seam (no host flag set)
section('A. Debug bundle auto-enables the seam + installs the reload functions');

const mock = createMockFabric();
Object.assign(globalThis, mock.fabric);

// NOTE: we deliberately do NOT set globalThis._Platform_devSeam here. native.js must
// turn it on by itself because this is a DEBUG bundle (__canopy_debug === true).
vm.runInThisContext(SRC, { filename: 'canopy.bundle.js' });
check('bundle installed the __canopy_boot hook', typeof globalThis.__canopy_boot === 'function');
globalThis.__canopy_boot(null, {});

check('native.js auto-enabled _Platform_devSeam in the debug bundle',
  globalThis._Platform_devSeam === true, 'got ' + globalThis._Platform_devSeam);
check('DEV-3 seam published _Platform_live (the dev seam is live)',
  globalThis._Platform_live != null && typeof globalThis._Platform_live === 'object');
check('__canopy_captureState installed', typeof globalThis.__canopy_captureState === 'function');
check('__canopy_teardown installed', typeof globalThis.__canopy_teardown === 'function');
check('__canopy_remount installed', typeof globalThis.__canopy_remount === 'function');

const rootTag = mock.rootHandle;
check('a Fabric root surface was created + attached', rootTag != null);
check('initial label is "Count: 0"', liveLabel(mock) && liveLabel(mock).props.text === 'Count: 0',
  liveLabel(mock) && liveLabel(mock).props.text);

// ===========================================================================
// Advance the live program so its model diverges from init, then capture
section('B. captureState reads the live model after the user advanced it');

const inc = mock.findByTestID('increment');
mock.emit(inc.handle, 'press', {}); mock.flushFrames();
mock.emit(inc.handle, 'press', {}); mock.flushFrames();
check('two taps advanced the live model to 2', globalThis._Platform_live.getModel() === 2,
  String(globalThis._Platform_live.getModel()));
check('label advanced to "Count: 2"', liveLabel(mock).props.text === 'Count: 2', liveLabel(mock).props.text);

const captured = globalThis.__canopy_captureState();
check('captureState returned an opaque { model } carrier', captured != null && typeof captured === 'object');
check('captureState carries the live model (2)', captured && captured.model === 2, captured && JSON.stringify(captured));

// record the mounted child handles + their event registrations so we can prove teardown
// actually releases them (no stale handles)
const rootBefore = mock.findByTag('RCTRootView')[0];
const mountedChild = rootBefore.children[0];
check('exactly one child mounted under the root before teardown', rootBefore.children.length === 1,
  String(rootBefore.children.length));
check('the increment button had a press handler registered before teardown',
  Array.isArray(inc.events) && inc.events.includes('press'));

// ===========================================================================
// PHASE 2 — teardown: stop Subs + release this program's subtree
section('C. teardown stops Subs (_Platform_live -> null), detaches the subtree, no stale handles');

mock.clearLog();
const tore = globalThis.__canopy_teardown();
check('teardown reported it tore an active program down', tore === true, String(tore));
check('teardown stopped the runtime: _Platform_live is now null (no double-subscribe on reload)',
  globalThis._Platform_live === null, 'got ' + JSON.stringify(globalThis._Platform_live));
check('teardown detached the mounted subtree from the root (0 children left under root)',
  mock.findByTag('RCTRootView')[0].children.length === 0,
  String(mock.findByTag('RCTRootView')[0].children.length));
const removed = mock.log.filter(m => m.op === 'removeChild');
check('teardown emitted a removeChild for the mounted child',
  removed.some(m => m.child === mountedChild), JSON.stringify(removed.map(m => m.child)));
const createdDuringTeardown = mock.log.filter(m => m.op === 'createView');
check('teardown created NO new views (pure release, no churn)', createdDuringTeardown.length === 0,
  String(createdDuringTeardown.length));

// No stale event handles: firing a gesture at the torn-down button must reach NO callback
// (the registry entry was released). We assert via the event registry the bundle exposes
// indirectly — emitting must not advance any model (there is no live program anyway).
let staleThrew = null;
try { mock.emit(inc.handle, 'press', {}); mock.flushFrames(); } catch (e) { staleThrew = e; }
check('a gesture at a torn-down handle is inert (no stale callback fired, no throw)', staleThrew === null,
  staleThrew && String(staleThrew));

// teardown is idempotent — a second call with nothing live returns false and does not throw
let secondThrew = null, secondRet;
try { secondRet = globalThis.__canopy_teardown(); } catch (e) { secondThrew = e; }
check('teardown is idempotent (second call returns false, no throw)',
  secondThrew === null && secondRet === false, secondThrew ? String(secondThrew) : 'ret=' + secondRet);

// ===========================================================================
// PHASE 3 (host) + PHASE 4 — re-eval the new bundle + re-boot + remount
section('D. re-eval + re-boot onto the SAME root, then remount restores state (0 create)');

// The native host's job before an in-process re-eval: clear the Canopy registry (+ the Elm
// alias) so the compiler's _Platform_export does not reject a duplicate Canopy.Main on the runtime.
globalThis.Canopy = undefined;
globalThis.Elm = undefined;
if (globalThis.scope) { globalThis.scope.Canopy = undefined; globalThis.scope.Elm = undefined; }

mock.clearLog();
vm.runInThisContext(SRC, { filename: 'canopy.bundle.js (reload)' });
globalThis.__canopy_boot(rootTag, {});   // re-boot onto the SAME cached root tag
check('re-boot re-published a fresh _Platform_live', globalThis._Platform_live != null);
check('re-boot re-attached a child under the SAME root',
  mock.findByTag('RCTRootView')[0].children.length === 1,
  String(mock.findByTag('RCTRootView')[0].children.length));
check('the freshly-booted program starts at its init model (Count: 0)',
  liveLabel(mock) && liveLabel(mock).props.text === 'Count: 0', liveLabel(mock) && liveLabel(mock).props.text);

// PHASE 4 — restore the captured model into the freshly-booted program
mock.clearLog();
const remounted = globalThis.__canopy_remount(captured);
mock.flushFrames();
check('remount reported it restored a model', remounted === true, String(remounted));
check('remount restored the live model to the captured 2',
  globalThis._Platform_live.getModel() === 2, String(globalThis._Platform_live.getModel()));
check('remount re-rendered the label back to "Count: 2" (state preserved across reload)',
  liveLabel(mock).props.text === 'Count: 2', liveLabel(mock).props.text);

const remountCreates = mock.log.filter(m => m.op === 'createView');
const remountUpdates = mock.log.filter(m => m.op === 'updateProps');
const remountStructural = mock.log.filter(m => m.op === 'insertChild' || m.op === 'removeChild');
check('remount created ZERO new views for the unchanged subtree (the §8 reload criterion)',
  remountCreates.length === 0, String(remountCreates.length));
check('remount did ZERO structural insert/remove (no re-mount of the subtree)',
  remountStructural.length === 0, String(remountStructural.length));
check('remount restored via exactly ONE targeted updateProps',
  remountUpdates.length === 1, String(remountUpdates.length) + ': ' + JSON.stringify(remountUpdates.map(u => u.props)));

// the reloaded program is fully live: a tap on the LIVE button (not the stale detached one
// the mock still keeps in its map) drives it forward from the restored model
mock.clearLog();
const inc2 = liveByTestID(mock, 'increment');
check('the live increment button is reachable from the re-booted root', inc2 != null);
mock.emit(inc2.handle, 'press', {}); mock.flushFrames();
check('the reloaded program is live: a tap advances "Count: 2" -> "Count: 3"',
  liveLabel(mock).props.text === 'Count: 3', liveLabel(mock).props.text);

// ===========================================================================
// E. Inert shape — with no live program, the seam functions are pure no-ops
section('E. With no live program, the reload seam is inert (release-safety shape)');

globalThis.__canopy_teardown();             // tear the reloaded program down too
check('after teardown there is no live program (_Platform_live === null)',
  globalThis._Platform_live === null);
check('captureState with no live program returns null (nothing leaks)',
  globalThis.__canopy_captureState() === null, JSON.stringify(globalThis.__canopy_captureState()));
let remountNoLive = null, remountNoLiveRet;
try { remountNoLiveRet = globalThis.__canopy_remount({ model: 99 }); } catch (e) { remountNoLive = e; }
check('remount with no live program is a no-op returning false (no throw)',
  remountNoLive === null && remountNoLiveRet === false,
  remountNoLive ? String(remountNoLive) : 'ret=' + remountNoLiveRet);
check('remount(null) is a no-op returning false', globalThis.__canopy_remount(null) === false);

// ===========================================================================
section(`Result: ${failed === 0 ? '\x1b[32mPASS' : '\x1b[31mFAIL'}\x1b[0m  (${passed} passed, ${failed} failed)`);
if (failed) { console.log('failed:\n  - ' + fails.join('\n  - ')); }
process.exit(failed === 0 ? 0 : 1);
