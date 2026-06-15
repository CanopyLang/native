# The canopy/native competitive performance bar (RND-9)

*Ratified 2026-06-15 by the owner. Source: `plans/10-competitor-master-plan.md` §1 acceptance bar +
`plans/dependent/RND-9.md`. This document is the human-readable companion to the machine-enforced
bar; the numbers live in [`harness/perf-bar.json`](../harness/perf-bar.json) and the gate is
[`harness/perf-bar.js`](../harness/perf-bar.js).*

---

## 1. What "competitive" means, numerically

"A credible React Native competitor" is unfalsifiable without a numeric, RN-referenced bar. RND-9
ratifies one. Every gate except the no-op frame is a **multiple of React Native 0.76.9 on the same
device** — never an absolute millisecond, because absolute timings are hardware-dependent and an
x86_64 emulator is an *upper bound* on real-device jank, never a floor. A relative bar is the only
honest head-to-head.

| gate | ratified bar | kind | blocking? |
|---|---|---|---|
| **list jank** | ≤ **1.2×** RN jank% **and** ≤ **5%** dropped | RN-multiple + absolute cap | yes |
| **tap-to-paint** | ≤ RN median **+ 4 ms** | RN + ms | yes |
| **cold TTI** | ≤ **1.3×** RN | RN-multiple | advisory until CMP-8 `.hbc` |
| **peak RSS** | ≤ **1.5×** RN | RN-multiple | yes |
| **no-op frame** | **= 0** host mutations | absolute, hard | yes (always, RN-independent) |

The multipliers carry **owner sign-off** (`perf-bar.json` → `ratified`). The rationale for each is
recorded inline in `perf-bar.json` and summarized here:

- **list jank ≤ 1.2× RN, ≤ 5% dropped.** 20% headroom over RN absorbs that Canopy mounts real
  platform views directly (no Fabric shadow tree) and pays a *different* per-frame cost; beyond 1.2×
  the architecture would no longer be competitive. The absolute 5%-dropped cap is an RN-independent
  floor: a list cannot "pass" by being 1.2× of an already-janky RN.
- **tap-to-paint ≤ RN + 4 ms.** Canopy does a targeted single-prop scalar update (the AND-8 fast
  path, **zero** JSON marshalling) where RN does a `setState` re-render, so this is expected to be
  ≤ RN, not merely within budget; +4 ms (a quarter of one 60 Hz frame) is slack for frame-pipeline
  measurement noise.
- **cold TTI ≤ 1.3× RN.** RN ships Hermes bytecode (`.hbc`); Canopy ships plain JS today (parsed at
  boot), so 30% headroom covers the parse delta **until CMP-8's `.hbc` emitter closes it**. This row
  is therefore *advisory* (reported, not blocking) until the ledger's `canopy.device.bundleKind`
  becomes `hbc`; flip `gates.coldTtiMultiple.blocking` to `true` then.
- **peak RSS ≤ 1.5× RN.** Both link Hermes + Yoga; Canopy additionally holds the native view tree
  directly. 50% headroom is generous because RSS is the least architecture-discriminating and
  noisiest metric.
- **no-op frame = 0 mutations.** THE hard, structural, **device-free** pass/fail — the one gate fully
  provable in CI with no device and no RN. A frame that changes nothing in the model must emit zero
  host mutations. This is the `lazy`/`__refs` short-circuit (RND-1) + windowing (RND-6) invariant the
  whole RND track exists to protect; it is binary and non-negotiable.

---

## 2. How the bar is enforced

```
harness/perf-bar.json     the RATIFIED bar (owner-signed multipliers + rationale) — source of truth
harness/perf-ledger.json  the COMMITTED ledger: real canopy device + walker numbers + the RN reference
harness/perf-bar.js       the gate: evaluates the ledger against the bar, prints the head-to-head,
                          exits non-zero on a BLOCKING failure. --selftest proves the logic device-free.
```

`harness/perf-bar.js` is wired into `scripts/ci-test.sh` as step **15/15** (a `--selftest` of the gate
logic, then the gate itself against the committed ledger). It is the harness-owned counterpart to
`bench/rn-comparison/scripts/compare-report.js`: `compare-report.js` merges two **live** per-side
metrics files on a device; `perf-bar.js` gates the **committed** ledger so the bar travels with the
repo and CI enforces it with no device and no RN.

```sh
npm --prefix harness run perf-bar            # gate the committed ledger vs the ratified bar
npm --prefix harness run perf-bar:selftest   # device-free proof of the gate logic
node harness/perf-bar.js --json              # machine-readable verdict
```

### The honesty rule (which rows block, and when)

A row **blocks the build** iff it is `blocking`, judgeable, **and** either RN-independent **or** the
RN reference is verified:

- **no-op frame** and **dropped-frame cap** are RN-independent → **always enforced**, here and now.
- **list jank / tap-to-paint / cold TTI / peak RSS** are RN-*relative*. RN 0.76.9 is **not installed
  in this sandbox**, so the ledger's `rn` block is an *authored projection* (`verified:false`). While
  unverified these rows are **reported but do not block** — a soft reference must never gate a build.
  They light up automatically the moment a real `rn.json` replaces the projection
  (`node harness/perf-bar.js --record-rn <rn.json>`).

The cold-TTI row additionally stays advisory until CMP-8 ships `.hbc` (see §1).

---

## 3. The recorded numbers (committed ledger)

`harness/perf-ledger.json`, captured **2026-06-15** on the live x86_64 emulator and the device-free
walker. The current verdict (`node harness/perf-bar.js`):

| gate | canopy | RN 0.76.9 | result |
|---|---|---|---|
| no-op frame mutations | **0** | n/a | **PASS** (hard, enforced) |
| list dropped frames (≤5%) | **1.79%** | n/a | **PASS** (absolute cap, enforced) |
| list jank (≤1.2× RN) | 1.79% | 2.5%* | 0.72× — pass·advisory |
| tap-to-paint (≤ RN +4ms) | 16 ms | 16 ms* | +0.0 ms — pass·advisory |
| cold TTI (≤1.3× RN) | 519 ms | 450 ms* | 1.15× — pass·advisory (also contingent on `.hbc`) |
| peak RSS (≤1.5× RN) | 71 MB | 130 MB* | 0.55× — pass·advisory |

\* RN values are an **authored projection** from the byte-identical `rn/App.js` sibling, deliberately
conservative (RN's favour) so a canopy PASS is never manufactured by a soft reference. They are **not
measured here** and are tagged `rn.verified=false`.

**Device source** (`canopy.device`, `verified:true`): `bench/rn-comparison/scripts/bench-compare.sh
--side canopy` on `emulator-5554` (`org.canopy.echo`). x86_64 → upper bound on real-device jank.

**Walker source** (`canopy.walker`, `verified:true`, `device:false`):
`bench/rn-comparison/harness/bench-walker.js` driving the real `package/external/native.js` walker
against the mock Fabric. The no-op-frame = 0 gate is proven **here** (structural, not timing): a
one-row windowed scroll touches **3** host ops with **0** re-creates; a tap is **1** scalar update
with **0** JSON; a same-window re-render emits **0** mutations.

> **Emulator caveat.** Every device number above is x86_64-emulator — an **upper bound** on
> real-device jank, never a floor (no GPU-compositor parity, host-scheduler noise). Re-run on real
> arm64 for shippable figures. The caveat is embedded in `perf-ledger.json` and printed by the gate.

---

## 4. Re-recording the ledger

The ledger is a committed artifact, kept reproducible by re-recording from fresh captures (never
hand-edited):

```sh
# canopy device numbers — needs an emulator/device + the Canopy host installed
bench/rn-comparison/scripts/bench-compare.sh --side canopy --out-dir /tmp/b
node harness/perf-bar.js --record-device /tmp/b/canopy.json

# canopy structural / walker numbers — device-free, runs anywhere
node bench/rn-comparison/harness/bench-walker.js --json > /tmp/walker.json
node harness/perf-bar.js --record-walker /tmp/walker.json

# the RN reference — on a box with the RN 0.76.9 toolchain + the SAME device
bench/rn-comparison/scripts/bench-compare.sh --side rn --rn-dir <scaffold> --out-dir /tmp/b
node harness/perf-bar.js --record-rn /tmp/b/rn.json     # flips rn.verified=true → RN rows start blocking
```

Re-record `canopy.device` per CI device/abi class: an x86_64-emulator row must never be compared to
an arm64-device RN row (the gate carries the abi tag and warns on a cross-class compare).

---

## 5. Status — what ran here vs what is gated-but-pending

| piece | ran here? | evidence |
|---|---|---|
| ratified bar committed (owner-signed multipliers) | ✅ | `harness/perf-bar.json` |
| committed ledger with **real** canopy numbers | ✅ | `harness/perf-ledger.json` (device + walker, both `verified:true`) |
| gate logic (`--selftest`, 12 cases) | ✅ PASS | hard no-op gate, absolute cap, RN-relative breaches, advisory semantics |
| gate vs committed ledger | ✅ PASS | every blocking gate green; RN-relative rows pass advisory |
| wired into `scripts/ci-test.sh` | ✅ step 15/15 | selftest + gate run per commit |
| RN 0.76.9 **measured** | ❌ not installed | `rn` block is an authored projection (`verified:false`); `--record-rn` lights it up |
| cold-TTI as a **blocking** gate | ❌ pending CMP-8 | advisory until the `.hbc` emitter ships (then flip `blocking:true`) |

**Follow-ups:** (1) run `--record-rn` on a box with the RN 0.76.9 toolchain to flip the RN-relative
rows from advisory to blocking with measured numbers; (2) re-record `canopy.device` on real arm64
hardware for shippable (non-emulator) figures; (3) once CMP-8 lands `.hbc`, set
`gates.coldTtiMultiple.blocking = true` and re-record the (now bytecode) canopy TTI.
