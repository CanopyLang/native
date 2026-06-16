# Per-device perf baselines (DF-1)

This directory holds the **per-device-class** frame-metrics baselines the device-farm perf gate
(`harness/perf-report.js --baseline`) compares each nightly real-device trace against.

Each file is one real device's recorded "good" fling, in the `perf-report.js` dump shape, named by the
farm's device id:

- Android (Firebase Test Lab): `<model>.json` — e.g. `oriole.json` (Pixel 6 / arm64).
- iOS (BrowserStack): `<device-slug>.json` — e.g. `iphone-15.json`.

## Why per-device and why relative

A perf trace is only comparable to another trace from the **same hardware**: an x86_64 emulator number
is an upper bound on jank, never a floor, and a Pixel number is not comparable to an iPhone number.
So the gate is **relative to a per-device baseline** (jank% gated additively in points, frame-time
relatively as a multiple), never an absolute millisecond. This mirrors `perf-report.js`'s own gate and
`perf-bar.js`'s RN-relative discipline.

## How a baseline is recorded (the DF-1 §7 flip step)

A baseline is **not hand-edited** — it is recorded from the **first green** real-device run:

```sh
# Android — from the frame-metrics.json the Firebase run pulled off the device:
node harness/perf-report.js df-out/android/frame-metrics.json \
  --update-baseline harness/perf-baselines/oriole.json

# iOS — from the frame-summary.json distilled from the BrowserStack App Performance series:
node harness/perf-report.js df-out/ios/frame-summary.json \
  --update-baseline harness/perf-baselines/iphone-15.json
```

Until a device's baseline exists, the driver prints the ledger to **seed** it (and does not fail the
trace) — see `docs/device-farm.md` §7. Commit the baseline once the first clean run is pinned; from
then on a regression on that device class fails the gate.
