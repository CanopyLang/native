#!/usr/bin/env node
// run-command.js — proof of the AND-3 __fabric_command seam: the imperative-op ABI that
// reconciles to ONE seam with iOS-8's __fabric_callMethod.
//
// The render seam (createView/updateProps/…) is declarative; some operations can't be
// expressed as props — focus/blur a text input, measure a frame, scroll to an offset. AND-3
// adds __fabric_command(handle, name, argsJson): the walker fires it, the host runs the op,
// and the RESULT comes back ASYNC over the SAME event path a gesture uses —
// __canopy_dispatchEvent(handle, "__commandResult", result). This test drives the REAL
// _Native_command walker function + _Native_dispatchEvent against the extended mock Fabric
// (byte-compatible with CanopyHost.java's trivial echo) and asserts:
//
//   A. firing a command emits exactly one __fabric_command op to the host with the right shape
//   B. the result is genuinely ASYNC (nothing before the vsync hop; the result after it)
//   C. the async __commandResult round-trips back into the registered JS callback
//   D. the seam is OPTIONAL — a host lacking __fabric_command does not throw
//
// Device-gated remainder (AND-4 + emulator): the real Android JNI→Java echo + the on-device
// focus/measure/scrollTo ops. This is the closest device-free equivalent — same JSI calls,
// same event path, in-memory backing store.

'use strict';

require('./mini-runtime'); // installs F2..F9, _Platform_initialize, etc. (parity with run.js)
const native = require('../package/external/native.js');
const { createMockFabric } = require('./mock-fabric');

// ---- tiny assertion harness ------------------------------------------------
let passed = 0, failed = 0; const fails = [];
function check(name, cond, detail) {
    if (cond) { passed++; console.log(`  \x1b[32m✓\x1b[0m ${name}`); }
    else { failed++; fails.push(name); console.log(`  \x1b[31m✗\x1b[0m ${name}${detail ? '  — ' + detail : ''}`); }
}
function section(t) { console.log(`\n\x1b[1m${t}\x1b[0m`); }

// ---- wire the mock host into the global JSI surface ------------------------
const mock = createMockFabric();
Object.assign(globalThis, mock.fabric);                  // __fabric_createView … __fabric_command
native.installEventDispatcher(globalThis._Utils_Tuple0); // sets __canopy_dispatchEvent

// A view to target the command at (a text input is the canonical focus/measure target).
const inputHandle = globalThis.__fabric_createView('RCTSinglelineTextInputView', {});

// =========================================================================
section('A. Firing a command emits ONE __fabric_command op with the right shape');
mock.clearLog();
let received = null;
native._Native_command(inputHandle, 'focus', { select: true }, function (result) { received = result; });

const cmds = mock.log.filter(m => m.op === 'command');
check('exactly ONE __fabric_command op reached the host', cmds.length === 1, `${cmds.length} ops`);
check('the command targets the input handle', cmds.length === 1 && cmds[0].handle === inputHandle,
    cmds.length === 1 ? `handle ${cmds[0].handle}, wanted ${inputHandle}` : '');
check('the op name is "focus"', cmds.length === 1 && cmds[0].name === 'focus', cmds.length === 1 ? cmds[0].name : '');
check('the args were marshalled through', cmds.length === 1 && cmds[0].args && cmds[0].args.select === true,
    cmds.length === 1 ? JSON.stringify(cmds[0].args) : '');

// =========================================================================
section('B. The result is genuinely ASYNC (not delivered inline)');
check('callback NOT invoked synchronously (no result before the vsync hop)', received === null,
    received === null ? '' : JSON.stringify(received));

// =========================================================================
section('C. The async __commandResult round-trips back into the JS callback');
mock.flushFrames(); // advance one vsync — the host hops the result back
check('callback WAS invoked after the async hop', received !== null);
check('result carries the op name back (echo contract)', received && received.name === 'focus',
    received ? JSON.stringify(received) : '');
check('result carries the args back', received && received.args && received.args.select === true,
    received ? JSON.stringify(received) : '');

// a second command on the same handle must overwrite the one-shot callback (no stale fan-out)
section('C2. A second command re-targets the same handle cleanly');
mock.clearLog();
let received2 = null;
native._Native_command(inputHandle, 'blur', {}, function (r) { received2 = r; });
mock.flushFrames();
check('second command delivered to the NEW callback', received2 !== null && received2.name === 'blur',
    received2 ? JSON.stringify(received2) : '');
check('the first callback was not invoked again (one-shot re-target)', received.name === 'focus');

// =========================================================================
section('D. The seam is OPTIONAL — a host without __fabric_command does not throw');
const savedCommand = globalThis.__fabric_command;
delete globalThis.__fabric_command;
let threw = false;
try { native._Native_command(inputHandle, 'measure', {}, function () {}); }
catch (e) { threw = true; }
check('no throw when the host lacks __fabric_command', !threw);
globalThis.__fabric_command = savedCommand;

// ---------------------------------------------------------------------------
section(`Result: ${failed === 0 ? '\x1b[32mPASS' : '\x1b[31mFAIL'}\x1b[0m  (${passed} passed, ${failed} failed)`);
if (failed) { console.log('failed checks:\n  - ' + fails.join('\n  - ')); }
process.exit(failed === 0 ? 0 : 1);
