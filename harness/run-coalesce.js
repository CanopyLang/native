#!/usr/bin/env node
// run-coalesce.js — device-free guard for the AND-9 Cmd/Sub completion coalescing + backpressure.
//
// The AND-9 win lives on the Java side (CanopyCompletionScheduler): the native postToJs hop parks a
// completion and calls scheduleOnJs(id). Previously that posted ONE Runnable onto the main Looper
// PER completion, so a high-frequency stream (sensor/progress/scroll Sub) flooded the UI thread with
// one main-Looper turn per event — each re-entering Hermes. The fix coalesces a burst arriving
// within one frame into ONE post that drains them all in order, plus an opt-in latest-wins
// backpressure per stream.
//
// That Java policy is unit-tested directly on the JVM (CanopyCompletionSchedulerTest, run via
// `:app:testDebugUnitTest`). This Node harness is the CI-side EXECUTABLE SPEC of the same algorithm:
// a faithful port of the scheduler's coalescing/backpressure semantics, asserting the acceptance
// criteria the plan names — "1000 events <1s, no dropped FINAL value, bounded Looper backlog, fewer
// runJsCallback invocations". It runs in plain node (no Android), so `scripts/ci-test.sh` gates the
// AND-9 invariants per commit without an emulator, exactly as run-lazy.js gates the lazy fix. The JS
// model and the Java class MUST stay in lockstep; a divergence here is a signal the policy drifted.

'use strict';

let passed = 0, failed = 0; const fails = [];
function check(name, cond, detail) {
    if (cond) { passed++; console.log(`  \x1b[32m✓\x1b[0m ${name}`); }
    else { failed++; fails.push(name); console.log(`  \x1b[31m✗\x1b[0m ${name}${detail ? '  — ' + detail : ''}`); }
}
function section(t) { console.log(`\n\x1b[1m${t}\x1b[0m`); }

// ============================================================================
// Reference model of CanopyCompletionScheduler (Java) — same policy, in JS.
//   • poster(drain): the host posts ONE drain Runnable per frame onto the main Looper. Here the
//     test drives frames explicitly via flush(), so poster just records the pending drain.
//   • runner(id):   runJsCallback(id) — re-enter Hermes for one parked completion. Here it records
//     the id+order so we can assert FIFO + no-drop.
// ============================================================================

function makeScheduler(poster, runner) {
    const queue = [];                 // FIFO of parked ids awaiting a drain
    const latestByKey = new Map();    // streamKey -> current undrained id
    let superseded = new Set();       // ids a newer same-key frame overtook (skip on drain)
    let drainPosted = false;          // at most ONE pending drain Runnable (bounded backlog)
    const stats = { enqueued: 0, posts: 0, ran: 0, superseded: 0 };

    function drain() {
        const batch = queue.splice(0, queue.length); // snapshot + clear
        const skip = superseded; superseded = new Set();
        latestByKey.clear();                          // every key's id is in this batch
        drainPosted = false;
        for (const id of batch) {
            if (skip.has(id)) { continue; }           // overtaken intermediate — never re-enter JS
            stats.ran++;
            runner(id);
        }
    }

    function arm() {
        if (!drainPosted) { drainPosted = true; stats.posts++; poster(drain); }
    }

    return {
        // default: keep every completion, in order; coalesce the posts only.
        schedule(id) { queue.push(id); stats.enqueued++; arm(); },
        // opt-in latest-wins: a newer same-key frame supersedes an older undrained one.
        scheduleLatest(key, id) {
            const prior = latestByKey.get(key);
            if (prior !== undefined) { superseded.add(prior); stats.superseded++; }
            latestByKey.set(key, id);
            queue.push(id); stats.enqueued++; arm();
        },
        pending() { return queue.length; },
        stats,
    };
}

// A frame-modelling poster: queues drains; flush() fires the current frame's drains. A drain may
// re-arm a follow-up that lands in the NEXT flush.
function makeFramePoster() {
    let pending = [];
    return {
        post(drain) { pending.push(drain); },
        depth() { return pending.length; },
        flush() { const now = pending; pending = []; for (const d of now) { d(); } },
    };
}

// ============================================================================
section('AND-9 · coalescing: a burst within one frame batches into a single post');
// ============================================================================
{
    const poster = makeFramePoster();
    const ran = [];
    const s = makeScheduler(poster.post.bind(poster), (id) => ran.push(id));

    const N = 1000;
    const t0 = process.hrtime.bigint();
    for (let id = 1; id <= N; id++) { s.schedule(id); }
    check('a 1000-event burst posts exactly once (not 1000)', s.stats.posts === 1, `posts=${s.stats.posts}`);
    check('nothing runs before the frame fires', ran.length === 0);
    check('Looper carries at most ONE pending drain', poster.depth() === 1, `depth=${poster.depth()}`);

    poster.flush();
    const elapsedMs = Number(process.hrtime.bigint() - t0) / 1e6;

    check('every completion ran (no dropped value)', ran.length === N, `ran=${ran.length}`);
    check('fewer runJsCallback *posts* than events (1 vs 1000)', s.stats.posts < N);
    let fifo = true; for (let i = 0; i < N; i++) { if (ran[i] !== i + 1) { fifo = false; break; } }
    check('FIFO order preserved across the coalesced batch', fifo);
    check('the FINAL value (1000) is present', ran[ran.length - 1] === N);
    check('1000 events processed well under 1s', elapsedMs < 1000, `${elapsedMs.toFixed(2)}ms`);
}

// ============================================================================
section('AND-9 · bounded backlog: post count stays O(frames), not O(events)');
// ============================================================================
{
    const poster = makeFramePoster();
    const s = makeScheduler(poster.post.bind(poster), () => {});
    for (let id = 1; id <= 50000; id++) { s.schedule(id); }
    check('50k events still produce a single pending drain', poster.depth() === 1);
    check('50k events produced exactly 1 post', s.stats.posts === 1, `posts=${s.stats.posts}`);
}

// ============================================================================
section('AND-9 · latest-wins backpressure: drop superseded intermediates, keep the FINAL');
// ============================================================================
{
    const poster = makeFramePoster();
    const ran = [];
    const s = makeScheduler(poster.post.bind(poster), (id) => ran.push(id));

    for (let id = 1; id <= 100; id++) { s.scheduleLatest('sensor', id); }
    check('the whole backpressured burst still posts once', s.stats.posts === 1);
    poster.flush();

    check('only the newest same-key frame ran', ran.length === 1, `ran=${ran.length}`);
    check('and it is the FINAL value (100), never dropped', ran[0] === 100);
    check('99 intermediates superseded', s.stats.superseded === 99, `superseded=${s.stats.superseded}`);
    check('enqueued == ran + superseded (no leak)', s.stats.enqueued === s.stats.ran + s.stats.superseded);
}

// ============================================================================
section('AND-9 · latest-wins is per-key + interleaves with ordered completions');
// ============================================================================
{
    const poster = makeFramePoster();
    const ran = [];
    const s = makeScheduler(poster.post.bind(poster), (id) => ran.push(id));

    s.schedule(1);                 // an ordered Cmd one-shot
    s.scheduleLatest('accel', 2);
    s.scheduleLatest('gyro', 3);
    s.scheduleLatest('accel', 4);  // supersedes accel#2
    s.schedule(5);                 // another ordered Cmd one-shot
    s.scheduleLatest('gyro', 6);   // supersedes gyro#3
    poster.flush();

    check('both ordered completions ran (every Cmd value matters)', ran.includes(1) && ran.includes(5));
    check("accel's newest (4) ran, its superseded (2) did not", ran.includes(4) && !ran.includes(2));
    check("gyro's newest (6) ran, its superseded (3) did not", ran.includes(6) && !ran.includes(3));
    check('2 superseded total', s.stats.superseded === 2, `superseded=${s.stats.superseded}`);
    // survivors in enqueue order: 1, 4, 5, 6
    check('survivors keep FIFO order', JSON.stringify(ran) === JSON.stringify([1, 4, 5, 6]), JSON.stringify(ran));
}

// ============================================================================
section('AND-9 · cross-frame: same-key events in distinct frames both run');
// ============================================================================
{
    const poster = makeFramePoster();
    const ran = [];
    const s = makeScheduler(poster.post.bind(poster), (id) => ran.push(id));

    s.scheduleLatest('progress', 10);
    poster.flush();                       // frame 1: 10 runs
    s.scheduleLatest('progress', 11);
    check('a post-drain completion re-arms a fresh post', s.stats.posts === 2);
    poster.flush();                       // frame 2: 11 runs

    check('both frames delivered (no false supersede across frames)', JSON.stringify(ran) === JSON.stringify([10, 11]));
    check('nothing superseded across distinct frames', s.stats.superseded === 0);
}

// ============================================================================
section('AND-9 · re-entrant park during drain lands in the next frame');
// ============================================================================
{
    const poster = makeFramePoster();
    const ran = [];
    let sref;
    sref = makeScheduler(poster.post.bind(poster), (id) => {
        ran.push(id);
        if (id === 1) { sref.schedule(99); } // a follow-up Cmd parked from within the drain
    });

    sref.schedule(1);
    poster.flush();                          // frame 1 runs {1}, which parks 99
    check('the re-entrant completion re-armed a post', poster.depth() >= 1);
    poster.flush();                          // frame 2 runs {99}
    check('re-entrant follow-up delivered next frame', JSON.stringify(ran) === JSON.stringify([1, 99]));
}

// ============================================================================
console.log();
if (failed === 0) {
    console.log(`\x1b[32mAND-9 coalesce/backpressure guard: ${passed} checks passed.\x1b[0m`);
    process.exit(0);
} else {
    console.log(`\x1b[31mAND-9 coalesce/backpressure guard: ${failed} FAILED (${fails.join(', ')}), ${passed} passed.\x1b[0m`);
    process.exit(1);
}
