#!/usr/bin/env node
// run.js — headless proof of the canopy/native architecture.
//
// Boots the REAL external/native.js walker + `element` seam against a mock Fabric and
// the counter app, then asserts the docs/architecture.md §8 pass criteria:
//
//   A. The rendered tree is REAL native views (RCTView/RCTText/…) — never a WebView,
//      never a DOM/React element.
//   B. A tap runs Canopy `update` and the label re-renders via a SINGLE targeted
//      Fabric `updateProps` — no createView, no insert/remove, no subtree re-mount.
//   C. Counting works across taps; Reset works.
//
// This is the closest local equivalent of "inspect it in the Xcode/Android view
// hierarchy" — same JSI calls, in-memory backing store.

'use strict';

require('./mini-runtime'); // installs F2..F9, _Platform_initialize, _Json_runHelp, …
const native = require('../package/external/native.js');
const { createMockFabric } = require('./mock-fabric');
const { app } = require('./counter-view');

// ---- tiny assertion harness ------------------------------------------------
let passed = 0, failed = 0;
const fails = [];
function check(name, cond, detail) {
    if (cond) { passed++; console.log(`  \x1b[32m✓\x1b[0m ${name}`); }
    else { failed++; fails.push(name); console.log(`  \x1b[31m✗\x1b[0m ${name}${detail ? '  — ' + detail : ''}`); }
}
function section(t) { console.log(`\n\x1b[1m${t}\x1b[0m`); }

// ---- wire the mock host into the global JSI surface ------------------------
const mock = createMockFabric();
Object.assign(globalThis, mock.fabric);          // __fabric_createView, etc.
native.installEventDispatcher(globalThis._Utils_Tuple0); // sets __canopy_dispatchEvent

// ---- boot the program (mirror of how the RN host boots Hermes) -------------
const flagDecoder = { tag: 'succeed', value: undefined };
const programBuilder = native.element(app.init)(app.view)(app.update)(app.subscriptions);
programBuilder(flagDecoder)(/* debugMetadata */ null)({ flags: undefined }); // no node → host root

// ---------------------------------------------------------------------------
section('A. Native view tree (not a WebView / DOM)');
const allTags = mock.findByTag.bind(mock);
const tree = mock.renderTree();
process.stdout.write('\n' + tree + '\n');

const rootChildren = mock.findByTag('RCTRootView');
check('a Fabric root surface was created and attached', rootChildren.length === 1 && mock.rootHandle != null);

const labels = mock.findByTag('RCTText');
check('three RCTText views exist (label + 2 button captions)', labels.length === 3, `got ${labels.length}`);

const views = mock.findByTag('RCTView');
check('RCTView containers exist (column + 2 buttons)', views.length >= 3, `got ${views.length}`);

// every created view must be a real native component, never a web surface
const everyCreate = mock.log; // full log still holds the create ops from boot
const createdTags = new Set(everyCreate.filter(m => m.op === 'createView').map(m => m.tag));
const allNative = [...createdTags].every(t => /^RCT/.test(t));
check('every created view is a native RCT* component', allNative, [...createdTags].join(', '));
check('no WebView / DOM tag was created', ![...createdTags].some(t => /WebView|div|span|html/i.test(t)));

// locate the live label view (the one showing the count)
function labelView() { return mock.findByTag('RCTText').find(v => /^Count:/.test(v.props.text)); }
check('label initially shows "Count: 0"', labelView() && labelView().props.text === 'Count: 0',
    labelView() && labelView().props.text);

// ---------------------------------------------------------------------------
section('B. A tap → Canopy update → ONE targeted updateProps (no re-mount)');
const labelHandleBefore = labelView().handle;
const incBtn = mock.findByTestID('increment');
check('increment button registered a native "press" event', incBtn && incBtn.events && incBtn.events.includes('press'));

mock.clearLog();
mock.emit(incBtn.handle, 'press', {});  // simulate the native gesture
mock.flushFrames();                     // advance one vsync

const since = mock.log;
const creates = since.filter(m => m.op === 'createView');
const inserts = since.filter(m => m.op === 'insertChild');
const removes = since.filter(m => m.op === 'removeChild');
const updates = since.filter(m => m.op === 'updateProps');

check('ZERO createView after tap (no re-mount)', creates.length === 0, `${creates.length} creates`);
check('ZERO removeChild after tap', removes.length === 0, `${removes.length} removes`);
check('ZERO structural insertChild after tap', inserts.length === 0, `${inserts.length} inserts`);
check('exactly ONE updateProps after tap', updates.length === 1, `${updates.length} updates: ` +
    JSON.stringify(updates.map(u => ({ tag: u.tag, props: u.props }))));
check('the single update targets the SAME label handle (identity preserved)',
    updates.length === 1 && updates[0].handle === labelHandleBefore,
    updates.length === 1 ? `updated handle ${updates[0].handle}, label was ${labelHandleBefore}` : '');
check('the update set text to "Count: 1"',
    updates.length === 1 && updates[0].props.text === 'Count: 1',
    updates.length === 1 ? JSON.stringify(updates[0].props) : '');
check('label view now reads "Count: 1"', labelView().props.text === 'Count: 1', labelView().props.text);

// ---------------------------------------------------------------------------
section('C. Counting + reset across taps');
mock.emit(incBtn.handle, 'press', {}); mock.flushFrames();
check('second tap → "Count: 2"', labelView().props.text === 'Count: 2', labelView().props.text);

const resetBtn = mock.findByTestID('reset');
mock.emit(resetBtn.handle, 'press', {}); mock.flushFrames();
check('reset tap → "Count: 0"', labelView().props.text === 'Count: 0', labelView().props.text);
check('label handle is STILL the same after 3 taps (never re-mounted)',
    labelView().handle === labelHandleBefore, `now ${labelView().handle}, was ${labelHandleBefore}`);

// ---------------------------------------------------------------------------
section(`Result: ${failed === 0 ? '\x1b[32mPASS' : '\x1b[31mFAIL'}\x1b[0m  (${passed} passed, ${failed} failed)`);
if (failed) { console.log('failed checks:\n  - ' + fails.join('\n  - ')); }
process.exit(failed === 0 ? 0 : 1);
