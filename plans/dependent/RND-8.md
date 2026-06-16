# RND-8 — (Conditional) Move JS off the UI thread

| | |
|---|---|
| **Track** | perf |
| **Status** | done (flag-gated; device-validated on the emulator) |
| **Effort** | ~2 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | RND-7 (todo) |
| **Open blockers** | RND-7 (todo) |
| **Source plan** | plans/10-competitor-master-plan.md |

Add a dedicated JS thread owning the runtime with __fabric_* marshalling view writes to the UI thread — only if RND-7 batching alone misses the perf bar.

**Notes:** Large architectural change. Descope to advisory if batching meets RND-9.

**Implemented (flag-gated, OFF by default — debug.canopy.jsthread / CANOPY_JS_THREAD):**
- Builds directly on RND-7's binary batch: a frame is already ONE flat byte buffer — the only form
  cheap+safe to copy across the thread boundary. No JS-side change was needed (native.js's batch flush
  already produces the buffer); RND-8 is purely a host re-wiring + an additive shared-C++ seam.
- `host/shared/cpp/CanopyFabric.{h,cpp}`: an additive `BatchSink` on `installCanopyFabric` +
  `canopyApplyBinaryBatch`. When a sink is installed, `__fabric_applyBatch` hands the frame's binary
  buffer to it (off-thread) instead of replaying inline; null sink = inline replay, byte-for-byte
  unchanged (iOS / single-thread / mock). iOS-portable (`check-portable-cpp.sh` green).
- `host/android/app/src/main/jni/CanopyHostJni.cpp`: in off-UI mode the runtime is created+owned on a
  dedicated "CanopyJS" thread; the `batchSinkToUi` sink copies each frame's buffer into a UI-side table
  and posts `applyBatchOnUi`; `runUiBatch` replays it on the UI thread via `canopyApplyBinaryBatch`.
  A boot-time gate fails LOUD if the flag is on but the bundle does not batch (a per-mutation bundle
  cannot run off the UI thread).
- `CanopyHostJni.java`: the `HandlerThread`/`RUNTIME_HANDLER` plumbing; boot/emitEvent/setRestoreEngineModel
  /reload marshalled onto the runtime thread; completions posted to `RUNTIME_HANDLER`; the marshalled
  view writes + red-box/toast stay on the main Looper. `CanopyHost.command` (the one un-batched seam)
  marshals to the UI thread.
- Tests: `harness/run-jsthread.js` (device-free, in `ci-test.sh`) proves the JS thread makes ZERO direct
  view writes, a drained run is byte-identical to the inline binary path, frames decorrelate from the UI
  drain rate, and one cross-thread message per non-empty frame. On-device: emulator boot + taps work in
  BOTH modes; the CanopyJS thread exists and owns the runtime; default (single-thread) mode is unchanged.

**Advisory verdict (per the plan's "descope to advisory if batching meets RND-9"):** the seam is landed,
correct, and validated, but kept OFF by default — RND-7 batching already collapses the frame to one host
call, and the off-UI-thread move should only be FLIPPED ON once on-device timing (a physical arm64,
DF-1) shows batching alone misses the RND-9 bar. The flag makes that a one-line operational change, not a
re-architecture.
