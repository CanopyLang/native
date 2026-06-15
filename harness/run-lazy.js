#!/usr/bin/env node
// run-lazy.js — regression proof that `lazy`/thunk memoization actually short-circuits.
//
// The bug (audit, 2026-06): _Native_updateTNode force-unwrapped BOTH thunks unconditionally,
// so a `lazy func arg` subtree was re-forced + re-diffed every render even when `arg` was
// unchanged — `lazy` saved nothing. The fix mirrors virtual-dom.js: if both sides are the same
// kind of thunk/block with element-wise identical __refs, reuse the built node and skip the
// subtree entirely.
//
// The discriminator that distinguishes fixed from unfixed is NOT "zero mutations" (an unchanged
// subtree emits zero mutations either way — the diff just finds nothing). It is whether the
// thunk's render function is RE-INVOKED. Without the fix it is (force-unwrap calls it); with the
// fix it is not. So we count render-fn calls.
//
//   App: model {n, m}. A `lazy(renderSub, n)` subtree depends ONLY on n. Bumping m re-renders
//   the program (the m-label changes) but must NOT re-invoke renderSub. Bumping n must.

'use strict';

require('./mini-runtime');
const native = require('../package/external/native.js');
const { createMockFabric } = require('./mock-fabric');
const { builders } = require('./counter-view');
const { Native, A, Events } = builders;

let passed = 0, failed = 0; const fails = [];
function check(name, cond, detail) {
    if (cond) { passed++; console.log(`  \x1b[32m✓\x1b[0m ${name}`); }
    else { failed++; fails.push(name); console.log(`  \x1b[31m✗\x1b[0m ${name}${detail ? '  — ' + detail : ''}`); }
}
function section(t) { console.log(`\n\x1b[1m${t}\x1b[0m`); }

// ---- a lazy/thunk node: { $: __2_THUNK(5), __refs: [fn, ...args], __node: undefined } -------
// forceThunk applies fn curried over the args, exactly like _VirtualDom_forceThunk.
const THUNK = 5;
const lazy = (fn, arg) => ({ $: THUNK, __refs: [fn, arg], __node: undefined });

// The instrumented render function. Module-level ⇒ a STABLE reference across renders (so refs[0]
// is === between frames), which is the real contract `lazy` relies on.
let subRenders = 0;
function renderSub(n) {
    subRenders++;
    return Native.column([A.testID('lazysub')], [
        Native.text([A.testID('lazytext'), A.fontSize(14)], 'N=' + String(n)),
    ]);
}

const cmdNone = { $: '[]' }, subNone = { $: '[]' };
const Msg = { BumpN: { $: 'BumpN' }, BumpM: { $: 'BumpM' } };

const init = (_flags) => ({ a: { n: 0, m: 0 }, b: cmdNone });
const update = globalThis.F2((msg, model) => {
    switch (msg.$) {
        case 'BumpN': return { a: { n: model.n + 1, m: model.m }, b: cmdNone };
        case 'BumpM': return { a: { n: model.n, m: model.m + 1 }, b: cmdNone };
        default:      return { a: model, b: cmdNone };
    }
});
function view(model) {
    return Native.column([A.padding(10), A.flex(1)], [
        Native.text([A.testID('mtext'), A.fontSize(14)], 'M=' + String(model.m)),
        lazy(renderSub, model.n),
        Native.button([Events.onPress(Msg.BumpN), A.testID('bumpn'), A.padding(12)], 'N'),
        Native.button([Events.onPress(Msg.BumpM), A.testID('bumpm'), A.padding(12)], 'M'),
    ]);
}
const subscriptions = (_m) => subNone;

// ---- boot (mirror of run.js) -----------------------------------------------
const mock = createMockFabric();
Object.assign(globalThis, mock.fabric);
native.installEventDispatcher(globalThis._Utils_Tuple0);
const flagDecoder = { tag: 'succeed', value: undefined };
native.element(init)(view)(update)(subscriptions)(flagDecoder)(null)({ flags: undefined });

const lazyText = () => mock.findByTag('RCTText').find(v => /^N=/.test(v.props.text));
const mText = () => mock.findByTag('RCTText').find(v => /^M=/.test(v.props.text));

section('A. Initial render');
check('renderSub invoked exactly once at boot', subRenders === 1, `subRenders=${subRenders}`);
check('lazy subtree shows "N=0"', lazyText() && lazyText().props.text === 'N=0', lazyText() && lazyText().props.text);
check('m-label shows "M=0"', mText() && mText().props.text === 'M=0', mText() && mText().props.text);
const lazyHandle0 = lazyText() && lazyText().handle;

section('B. Bump m (lazy arg n UNCHANGED) → renderSub must NOT be re-invoked');
const before = subRenders;
mock.clearLog();
mock.emit(mock.findByTestID('bumpm').handle, 'press', {}); mock.flushFrames();
check('the program DID re-render (m-label updated to "M=1")', mText().props.text === 'M=1', mText().props.text);
check('renderSub was NOT re-invoked (lazy short-circuited)', subRenders === before,
    `subRenders went ${before} → ${subRenders} (the bug: thunk force-unwrapped + re-run)`);
check('lazy subtree text still "N=0"', lazyText().props.text === 'N=0', lazyText().props.text);
check('lazy subtree node was reused (same handle, never re-mounted)',
    lazyText().handle === lazyHandle0, `now ${lazyText().handle}, was ${lazyHandle0}`);
const updatesOnM = mock.log.filter(m => m.op === 'updateProps');
check('exactly ONE updateProps after bump-m (only the m-label)', updatesOnM.length === 1,
    `${updatesOnM.length}: ${JSON.stringify(updatesOnM.map(u => u.props))}`);

section('C. Bump n (lazy arg CHANGES) → renderSub re-invoked + subtree updates');
const before2 = subRenders;
mock.clearLog();
mock.emit(mock.findByTestID('bumpn').handle, 'press', {}); mock.flushFrames();
check('renderSub re-invoked exactly once (refs changed)', subRenders === before2 + 1,
    `subRenders went ${before2} → ${subRenders}`);
check('lazy subtree updated to "N=1"', lazyText().props.text === 'N=1', lazyText().props.text);
check('lazy subtree still not re-mounted (same handle)', lazyText().handle === lazyHandle0,
    `now ${lazyText().handle}, was ${lazyHandle0}`);

section(`Result: ${failed === 0 ? '\x1b[32mPASS' : '\x1b[31mFAIL'}\x1b[0m  (${passed} passed, ${failed} failed)`);
if (failed) { console.log('failed checks:\n  - ' + fails.join('\n  - ')); }
process.exit(failed === 0 ? 0 : 1);
