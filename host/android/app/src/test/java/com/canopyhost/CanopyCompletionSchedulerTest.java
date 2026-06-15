// CanopyCompletionSchedulerTest.java — JVM unit test for the AND-9 coalescing + backpressure policy.
//
// Runs on the host JVM via `:app:testDebugUnitTest` (no device). The AND-9 win is purely a Java
// scheduling policy (CanopyCompletionScheduler): a burst of native postToJs completions arriving
// within one frame must batch into ONE main-Looper post that drains them in order, and an opt-in
// latest-wins path must drop superseded intermediate frames while never losing a stream's FINAL
// value. The device behaviour (the actual main Looper, the JNI runJsCallback re-entry into Hermes)
// needs an emulator and is covered by the instrumented streaming flow; what IS unit-testable here,
// device-free, is the coalescing/backpressure algorithm itself — which is the entire AND-9 change.
//
// We drive the scheduler with a CONTROLLABLE poster (it does not run the drain immediately; the test
// flushes pending drains explicitly, modelling "the next frame fires") and an in-memory runner that
// records the ids it ran, in order. That lets us assert the load-bearing properties directly:
//   • coalescing: N completions in one frame -> exactly 1 post, all N ran, FIFO order, none dropped;
//   • bounded backlog: the poster is asked to post at most once per frame regardless of burst size;
//   • latest-wins: a newer same-key event supersedes an older undrained one, the newest always runs;
//   • the FINAL value of a backpressured stream is never dropped;
//   • cross-frame: a completion arriving after a drain re-arms a fresh post (next frame).

package com.canopyhost;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import java.util.ArrayList;
import java.util.List;
import org.junit.Test;

public final class CanopyCompletionSchedulerTest {

  // A frame-modelling poster: queues drain Runnables instead of running them, so the test decides
  // when "the next frame" fires (flush()). Counts how many posts the scheduler asked for — the
  // backlog-bound metric.
  private static final class FramePoster implements CanopyCompletionScheduler.Poster {
    final List<Runnable> pending = new ArrayList<>();
    int posts = 0;

    @Override public void post(Runnable r) { posts++; pending.add(r); }

    /** Fire every currently-pending drain (models the Looper running this frame's posts). A drain
     *  may itself post a follow-up; that lands in `pending` for the NEXT flush, not this one. */
    void flush() {
      List<Runnable> now = new ArrayList<>(pending);
      pending.clear();
      for (Runnable r : now) { r.run(); }
    }
  }

  // Records the order in which completion ids were actually run (= runJsCallback invocations).
  private static final class RecordingRunner implements CanopyCompletionScheduler.Runner {
    final List<Long> ran = new ArrayList<>();
    @Override public void run(long id) { ran.add(id); }
  }

  // ---- coalescing -------------------------------------------------------------------------------

  // A burst of completions arriving within ONE frame (before any drain runs) batches into exactly
  // ONE main-Looper post, and the single drain runs all of them in FIFO order. This is the core
  // AND-9 win: 1000 events -> 1 post, not 1000.
  @Test
  public void burstWithinOneFrameCoalescesToASinglePost() {
    FramePoster poster = new FramePoster();
    RecordingRunner runner = new RecordingRunner();
    CanopyCompletionScheduler s = new CanopyCompletionScheduler(poster, runner);

    for (long id = 1; id <= 1000; id++) { s.schedule(id); }

    assertEquals("a burst within one frame posts exactly once", 1, poster.posts);
    assertEquals("nothing has run before the frame fires", 0, runner.ran.size());

    poster.flush(); // the frame runs

    assertEquals("every completion ran", 1000, runner.ran.size());
    assertEquals("post count saved 999 main-Looper turns", 1, s.postCount());
    // FIFO order preserved — Cmd ordering must not be reshuffled by coalescing.
    for (int i = 0; i < 1000; i++) {
      assertEquals(Long.valueOf(i + 1), runner.ran.get(i));
    }
    assertEquals("no completion dropped", 1000, s.ranCount());
    assertEquals("backlog fully drained", 0, s.pendingCount());
  }

  // The Looper backlog is bounded at ONE pending drain Runnable no matter the stream rate: each
  // schedule before a drain does NOT add a post; only the empty->pending transition posts.
  @Test
  public void looperBacklogStaysBoundedAtOnePost() {
    FramePoster poster = new FramePoster();
    RecordingRunner runner = new RecordingRunner();
    CanopyCompletionScheduler s = new CanopyCompletionScheduler(poster, runner);

    for (long id = 1; id <= 50_000; id++) { s.schedule(id); }

    assertEquals("at most one drain Runnable is ever queued on the Looper", 1, poster.pending.size());
    assertEquals(1, poster.posts);
  }

  // A completion arriving AFTER a drain re-arms a fresh post (the next frame), so cross-frame
  // delivery still works — coalescing is per-frame, not once-ever.
  @Test
  public void completionAfterDrainRearmsNextFramePost() {
    FramePoster poster = new FramePoster();
    RecordingRunner runner = new RecordingRunner();
    CanopyCompletionScheduler s = new CanopyCompletionScheduler(poster, runner);

    s.schedule(1);
    s.schedule(2);
    poster.flush(); // frame 1 drains {1,2}
    assertEquals(2, runner.ran.size());

    s.schedule(3); // a new frame's completion
    assertEquals("a post-drain completion re-arms a fresh post", 2, poster.posts);
    poster.flush(); // frame 2 drains {3}
    assertEquals(3, runner.ran.size());
    assertEquals(Long.valueOf(3), runner.ran.get(2));
  }

  // ---- latest-wins backpressure -----------------------------------------------------------------

  // An opt-in stream that emits faster than the frame: only the NEWEST same-key frame in the window
  // runs; the superseded intermediates are dropped (the runtime is never re-entered for them). The
  // FINAL value is never dropped.
  @Test
  public void latestWinsDropsSupersededIntermediatesKeepsFinal() {
    FramePoster poster = new FramePoster();
    RecordingRunner runner = new RecordingRunner();
    CanopyCompletionScheduler s = new CanopyCompletionScheduler(poster, runner);

    // 100 sensor frames on ONE stream key arrive before the frame fires.
    for (long id = 1; id <= 100; id++) { s.scheduleLatest("sensor", id); }

    assertEquals("still only one post for the whole backpressured burst", 1, poster.posts);
    poster.flush();

    assertEquals("only the newest same-key frame ran", 1, runner.ran.size());
    assertEquals("and it is the FINAL value, never dropped", Long.valueOf(100), runner.ran.get(0));
    assertEquals("99 intermediates were superseded", 99, s.supersededCount());
    assertEquals("100 enqueued = 1 ran + 99 superseded", 100, s.enqueuedCount());
  }

  // Latest-wins is PER key: two interleaved streams each keep their own newest frame.
  @Test
  public void latestWinsIsPerStreamKey() {
    FramePoster poster = new FramePoster();
    RecordingRunner runner = new RecordingRunner();
    CanopyCompletionScheduler s = new CanopyCompletionScheduler(poster, runner);

    s.scheduleLatest("accel", 1);
    s.scheduleLatest("gyro", 2);
    s.scheduleLatest("accel", 3); // supersedes accel#1
    s.scheduleLatest("gyro", 4);  // supersedes gyro#2

    poster.flush();

    assertEquals("each stream keeps exactly its newest frame", 2, runner.ran.size());
    assertTrue("accel's newest (3) ran", runner.ran.contains(3L));
    assertTrue("gyro's newest (4) ran", runner.ran.contains(4L));
    assertFalse("accel's superseded (1) did not run", runner.ran.contains(1L));
    assertFalse("gyro's superseded (2) did not run", runner.ran.contains(2L));
    assertEquals(2, s.supersededCount());
  }

  // A fresh same-key event in a LATER frame does not supersede an already-drained one — the prior
  // frame's value ran, the new frame's value also runs.
  @Test
  public void sameKeyAcrossFramesBothRun() {
    FramePoster poster = new FramePoster();
    RecordingRunner runner = new RecordingRunner();
    CanopyCompletionScheduler s = new CanopyCompletionScheduler(poster, runner);

    s.scheduleLatest("progress", 10);
    poster.flush(); // frame 1: 10 runs
    s.scheduleLatest("progress", 11);
    poster.flush(); // frame 2: 11 runs (does NOT supersede the already-consumed 10)

    assertEquals(2, runner.ran.size());
    assertEquals(Long.valueOf(10), runner.ran.get(0));
    assertEquals(Long.valueOf(11), runner.ran.get(1));
    assertEquals("nothing superseded across distinct frames", 0, s.supersededCount());
  }

  // Default schedule() and opt-in scheduleLatest() interleave correctly in one frame: the ordered
  // (Cmd one-shot) completions all run; only the opt-in stream collapses to its newest.
  @Test
  public void mixedDefaultAndLatestInOneFrame() {
    FramePoster poster = new FramePoster();
    RecordingRunner runner = new RecordingRunner();
    CanopyCompletionScheduler s = new CanopyCompletionScheduler(poster, runner);

    s.schedule(1);                  // an ordered Cmd result
    s.scheduleLatest("scroll", 2);  // a backpressured stream frame
    s.scheduleLatest("scroll", 3);  // supersedes 2
    s.schedule(4);                  // another ordered Cmd result

    poster.flush();

    assertTrue("ordered completion 1 ran", runner.ran.contains(1L));
    assertTrue("ordered completion 4 ran", runner.ran.contains(4L));
    assertTrue("scroll's newest (3) ran", runner.ran.contains(3L));
    assertFalse("scroll's superseded (2) did not run", runner.ran.contains(2L));
    assertEquals("1 superseded total", 1, s.supersededCount());
    // FIFO among the survivors: 1 before 3 before 4 (enqueue order, with 2 skipped).
    assertEquals(Long.valueOf(1), runner.ran.get(0));
    assertEquals(Long.valueOf(3), runner.ran.get(1));
    assertEquals(Long.valueOf(4), runner.ran.get(2));
  }

  // A drain that itself enqueues a new completion (modelling runJsCallback parking a follow-up Cmd)
  // does not lose it: it lands in the next frame's post.
  @Test
  public void reentrantScheduleDuringDrainLandsNextFrame() {
    FramePoster poster = new FramePoster();
    final CanopyCompletionScheduler[] box = new CanopyCompletionScheduler[1];
    final List<Long> ran = new ArrayList<>();
    CanopyCompletionScheduler.Runner reentrant = id -> {
      ran.add(id);
      if (id == 1L) { box[0].schedule(99L); } // a follow-up parked from within the drain
    };
    CanopyCompletionScheduler s = new CanopyCompletionScheduler(poster, reentrant);
    box[0] = s;

    s.schedule(1);
    poster.flush(); // frame 1 runs {1}, which parks 99
    assertEquals(1, ran.size());
    assertTrue("the re-entrant completion re-armed a post", poster.pending.size() >= 1);

    poster.flush(); // frame 2 runs {99}
    assertEquals(2, ran.size());
    assertEquals(Long.valueOf(99), ran.get(1));
  }
}
