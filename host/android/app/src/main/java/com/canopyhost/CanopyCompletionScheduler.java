// CanopyCompletionScheduler.java — AND-9: coalesce + backpressure Cmd/Sub completions.
//
// THE PROBLEM (plans/dependent/AND-9.md, plans/10 §AND-9): the native postToJs hop parks each
// completion in g_callbacks and calls CanopyHostJni.scheduleOnJs(id). The previous body posted ONE
// Runnable onto the main Looper PER completion — `JS_HANDLER.post(() -> runJsCallback(id))`. A
// high-frequency stream (a sensor Sub, a download-progress stream, a scroll position feed) then
// floods the main Looper with one Runnable per event. Because the direct-views host runs JS ON the
// UI/main thread (every __fabric_* mount touches android.view), that backlog competes directly with
// frame production: 1000 sensor events become 1000 separately-dispatched main-Looper turns, each
// re-entering Hermes (runJsCallback → guardJsCall → update/view), thrashing the very thread that
// draws the next frame.
//
// THE WIN (per the notes: "Direct-views requires UI-thread mounts, so the win is coalescing not a
// 2nd thread"): batch the parked completion ids that arrive within ONE frame into a SINGLE main-
// Looper post that drains them all in FIFO order. A burst of N completions becomes 1 post + 1 drain
// running N runJsCallback calls. The Looper backlog stays bounded at exactly ONE pending drain
// Runnable regardless of stream rate, and — crucially — NO completion is dropped: the FINAL value
// of every stream is always drained.
//
// OPT-IN LATEST-WINS BACKPRESSURE (per streaming module): a stream whose intermediate frames are
// disposable (sensor samples, scroll offsets, progress %) can request `scheduleLatest(streamKey,id)`.
// When a newer event for the same key arrives while an older one is still parked-and-undrained, the
// older id is SUPERSEDED (its callback is dropped — runJsCallback is never invoked for that stale
// frame, so the runtime is not re-entered for a value already overtaken). The newest enqueued id
// always survives, so the terminal value of the stream is never lost. Modules that do NOT opt in
// (the default `schedule(id)` path) keep every completion, in order — Cmd one-shots, billing
// results, anything where every value matters stay exact.
//
// THREADING: schedule()/scheduleLatest() are called from native postToJs, which runs on whatever
// worker thread produced the completion — so the enqueue side is synchronized. drain() runs the
// poster's Runnable, which the host posts onto the main/JS Looper, so runJsCallback executes on the
// JS thread exactly as before. The class itself is platform-neutral (no Looper/JNI import): the host
// injects a `poster` (post a Runnable to the next frame) and a `runner` (invoke runJsCallback(id) on
// the JS thread). That keeps the whole coalescing policy device-free unit-testable on the JVM
// (CanopyCompletionSchedulerTest) while CanopyHostJni wires it to the real main Looper.

package com.canopyhost;

import java.util.ArrayDeque;
import java.util.HashMap;

public final class CanopyCompletionScheduler {

  /** Posts a drain Runnable onto the frame/JS Looper. The host supplies Handler::post. */
  public interface Poster {
    void post(Runnable r);
  }

  /** Runs one parked completion by id on the JS thread. The host supplies runJsCallback. */
  public interface Runner {
    void run(long id);
  }

  private final Poster poster;
  private final Runner runner;

  // FIFO of parked completion ids awaiting a drain. Guarded by `lock`. Insertion order is the
  // delivery order — a coalesced burst still resolves completions oldest-first, exactly as the
  // per-id posts did, so Cmd ordering is preserved.
  private final ArrayDeque<Long> queue = new ArrayDeque<>();

  // Latest-wins bookkeeping: streamKey -> the id currently parked for that key. A superseded id is
  // recorded in `superseded` so the drain skips it (the runtime is never re-entered for a stale
  // frame). Both guarded by `lock`.
  private final HashMap<String, Long> latestByKey = new HashMap<>();
  private final java.util.HashSet<Long> superseded = new java.util.HashSet<>();

  // True iff a drain Runnable is already posted-and-not-yet-started. The poster fires only on the
  // empty->pending transition, so the Looper backlog is bounded at ONE drain Runnable no matter how
  // many completions stream in. Guarded by `lock`.
  private boolean drainPosted = false;

  private final Object lock = new Object();

  // Counters (read by tests / a perf dump): how many completions were enqueued, how many main-Looper
  // posts that produced, how many runJsCallback invocations the drains ran, and how many were
  // dropped by latest-wins backpressure. enqueued == ran + superseded always holds after a drain.
  private long enqueuedCount = 0;
  private long postCount = 0;
  private long ranCount = 0;
  private long supersededCount = 0;

  public CanopyCompletionScheduler(Poster poster, Runner runner) {
    this.poster = poster;
    this.runner = runner;
  }

  /** Default path: keep every completion, in order. Coalesces the main-Looper posts only. */
  public void schedule(long id) {
    boolean needPost;
    synchronized (lock) {
      queue.addLast(id);
      enqueuedCount++;
      needPost = !drainPosted;
      if (needPost) { drainPosted = true; postCount++; }
    }
    if (needPost) { poster.post(this::drain); }
  }

  /** Opt-in latest-wins: a newer event for `streamKey` supersedes an older still-parked one. The
   *  newest enqueued id always survives, so the stream's terminal value is never dropped. */
  public void scheduleLatest(String streamKey, long id) {
    boolean needPost;
    synchronized (lock) {
      Long prior = latestByKey.put(streamKey, id);
      if (prior != null) {
        // The prior id for this key has not drained yet (the map only holds undrained ids — drain
        // clears every key once it consumes the batch). Mark it superseded so the drain SKIPS it: a
        // value already overtaken by a newer same-key frame must never re-enter the runtime. We do
        // NOT dispatch the prior id (that is the whole point of backpressure); its parked native
        // callback in the C1 hop's g_callbacks is reclaimed by that hop's own teardown lifecycle —
        // this Java policy only guarantees the stale frame is never DELIVERED.
        superseded.add(prior);
        supersededCount++;
      }
      queue.addLast(id);
      enqueuedCount++;
      needPost = !drainPosted;
      if (needPost) { drainPosted = true; postCount++; }
    }
    if (needPost) { poster.post(this::drain); }
  }

  // Drain every id parked so far, oldest-first, in ONE Looper turn. Snapshot the queue under the
  // lock, clear the pending flag, then run the snapshot OUTSIDE the lock (runJsCallback re-enters
  // Hermes and may itself park new completions — which must be free to re-arm a fresh drain).
  private void drain() {
    ArrayDeque<Long> batch;
    java.util.HashSet<Long> skip;
    synchronized (lock) {
      batch = new ArrayDeque<>(queue);
      queue.clear();
      skip = new java.util.HashSet<>(superseded);
      superseded.clear();
      // Every parked id (every key's current id) is in THIS batch, so after the drain no key has an
      // un-drained id. Forget them all: the NEXT event for any key is then treated as fresh and does
      // not try to supersede an already-consumed id.
      latestByKey.clear();
      drainPosted = false;
    }
    for (Long id : batch) {
      if (skip.contains(id)) { continue; } // superseded by a newer same-key frame — never re-enter JS
      ranCount++;
      runner.run(id);
    }
  }

  // ---- introspection (tests + an optional perf dump) ----------------------------------------------

  public long enqueuedCount() { synchronized (lock) { return enqueuedCount; } }
  public long postCount()     { synchronized (lock) { return postCount; } }
  public long ranCount()      { synchronized (lock) { return ranCount; } }
  public long supersededCount(){ synchronized (lock) { return supersededCount; } }

  /** Current depth of the un-drained backlog (the Looper carries at most ONE drain Runnable). */
  public int pendingCount()   { synchronized (lock) { return queue.size(); } }
}
