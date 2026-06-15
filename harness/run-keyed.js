#!/usr/bin/env node
// run-keyed.js — proves the LIS move-minimization pass in the keyed reconciler.
//
// Drives the REAL external/native.js walker (_Native_render + _Native_updateTNode) against
// the mock Fabric, doing keyed reorders and asserting two things per scenario:
//   CORRECTNESS  — the host's actual child order equals the new key order (and equals the
//                  walker's own post-update view of the order).
//   MINIMALITY   — the number of insertChild ops equals N − |LIS|, i.e. only the nodes that
//                  truly changed relative order moved (plus fresh nodes).
//
// The mock Fabric's insertChild is remove-then-insert-at-index — byte-identical to the real
// Android/iOS host — so a pass here is a faithful proof of on-device behaviour.

'use strict';

require('./mini-runtime');
const native = require('../package/external/native.js');
const { createMockFabric } = require('./mock-fabric');
const T = native.tags; // { TEXT, NODE, KEYED_NODE, ... }

// ---- vnode builders (same shape the compiler emits / counter-view.js uses) -------------
// A row is an RCTText whose single TEXT kid makes the walker carry the id as a `text` prop
// (the textContent fast-path) — so each keyed child is one RCTText with props.text === id.
const vtext = (s) => ({ $: T.TEXT, __text: s });
const node = (tag, kids) => ({ $: T.NODE, __tag: tag, __facts: {}, __kids: kids, __namespace: undefined });
const row = (id) => node('RCTText', [vtext(id)]);
const keyed = (ids) => ({ $: T.KEYED_NODE, __tag: 'RCTView', __facts: {},
    __kids: ids.map((id) => ({ a: id, b: row(id) })) });

// ---- LIS reference (independent of the walker) to compute the expected minimal count ----
function lisLen(arr) {
    const tails = [];
    for (const v of arr) {
        if (v < 0) continue;
        let lo = 0, hi = tails.length;
        while (lo < hi) { const m = (lo + hi) >> 1; if (tails[m] < v) lo = m + 1; else hi = m; }
        tails[lo] = v;
    }
    return tails.length;
}
function expectedInserts(oldIds, newIds) {
    const oldIdx = new Map(oldIds.map((id, i) => [id, i]));
    const arr = newIds.map((id) => (oldIdx.has(id) ? oldIdx.get(id) : -1));
    const fresh = arr.filter((v) => v < 0).length;
    const moved = (arr.length - fresh) - lisLen(arr); // movers among the survivors
    return moved + fresh;
}

// ---- harness ---------------------------------------------------------------------------
let passed = 0, failed = 0; const fails = [];
const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);
function check(name, cond, detail) {
    if (cond) { passed++; console.log(`  \x1b[32m✓\x1b[0m ${name}`); }
    else { failed++; fails.push(name); console.log(`  \x1b[31m✗\x1b[0m ${name}${detail ? '  — ' + detail : ''}`); }
}

function scenario(title, oldIds, newIds) {
    console.log(`\n\x1b[1m${title}\x1b[0m   [${oldIds}] → [${newIds}]`);
    const mock = createMockFabric();
    Object.assign(globalThis, mock.fabric);
    const ev = {}; // rows carry no event facts → eventNode is unused

    // host child order, read live from the mock (container.children handles → their text prop)
    const orderNow = () => {
        const container = mock.findByTag('RCTView')[0];
        const tm = {};
        for (const t of mock.findByTag('RCTText')) tm[t.handle] = t.props.text;
        return { container, ids: container.children.map((h) => tm[h]) };
    };

    const xV = keyed(oldIds);
    const nNode = native._Native_render(xV, ev);
    check('initial order matches', eq(orderNow().ids, oldIds), JSON.stringify(orderNow().ids));

    mock.clearLog();
    const yV = keyed(newIds);
    const updated = native._Native_updateTNode(nNode, xV, yV, ev);

    const { container, ids: hostOrder } = orderNow();
    check('host child order == new key order', eq(hostOrder, newIds), 'host=' + JSON.stringify(hostOrder));

    const walkerOrder = updated.__kids.map((k) => k.__key);
    check('walker order == host order', eq(walkerOrder, hostOrder), 'walker=' + JSON.stringify(walkerOrder));

    const inserts = mock.log.filter((m) => m.op === 'insertChild' && m.parent === container.handle);
    const want = expectedInserts(oldIds, newIds);
    check(`insertChild count is minimal (${inserts.length} == N−|LIS| = ${want})`, inserts.length === want,
        `${inserts.length} inserts`);
}

scenario('rotate-by-1',      ['A','B','C','D','E'], ['E','A','B','C','D']);
scenario('full reverse',     ['A','B','C','D','E'], ['E','D','C','B','A']);
scenario('same order',       ['A','B','C'],         ['A','B','C']);
scenario('swap middle two',  ['A','B','C','D','E'], ['A','C','B','D','E']);
scenario('insert in middle', ['A','B','C'],         ['A','X','B','C']);
scenario('delete + reorder', ['A','B','C','D'],     ['D','B']);
scenario('append',           ['A','B','C'],         ['A','B','C','D','E']);
scenario('prepend',          ['A','B','C'],         ['Z','A','B','C']);
scenario('shuffle',          ['A','B','C','D','E','F'], ['C','A','F','B','E','D']);

console.log(`\n\x1b[1mResult: ${failed === 0 ? '\x1b[32mPASS' : '\x1b[31mFAIL'}\x1b[0m  (${passed} passed, ${failed} failed)`);
if (failed) console.log('failed:\n  - ' + fails.join('\n  - '));
process.exit(failed === 0 ? 0 : 1);
