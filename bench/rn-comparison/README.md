# RND-5 — Head-to-head RN 0.76.9 benchmark

A canonical benchmark **app** plus a **harness** that measures the *same* three workloads
on **canopy/native** and on a **byte-identical React Native 0.76.9** sibling, then emits a
side-by-side table. `"Competitive"` is undefined without an apples-to-apples reference — this
is that reference.

> **Status in this sandbox.** RN 0.76.9 is **not installed** here (only an unrelated Expo RN
> 0.81.5 lives elsewhere on disk, with no Android shell to build into an APK). So the **RN side
> is authored + scripted but not run here**; the **canopy/native side runs fully** — both the
> device-free walker harness and the on-device driver against the live x86_64 emulator. See
> [Honesty](#honesty--what-actually-ran-here).

The whole point of RND-5 is that the two sides **cannot silently diverge**: both apps read their
row count, row height, depth, colors and font sizes from the single [`spec.json`](spec.json). Change
a number there and the Canopy app, the RN app, and the perf-bar gate all move together.

---

## The canonical workloads ([`spec.json`](spec.json))

| workload    | what it stresses                       | Canopy                | RN 0.76.9          | driver                |
|-------------|----------------------------------------|-----------------------|--------------------|-----------------------|
| `list1000`  | virtualized scroll / per-frame jank    | `Native.List` (1000)  | `FlatList` (1000)  | scripted fling ×12    |
| `counter`   | tap-to-paint latency / per-frame cost  | targeted prop update  | `setState` re-render | scripted tap ×50    |
| `depth30`   | layout depth + cold mount/teardown     | 30 nested flex views  | 30 nested `<View>` | toggle subtree on/off |

Both list impls are **windowed** — the fair comparison is two windowing lists, not a windowed list
vs a 1000-view dump.

---

## Layout

```
bench/rn-comparison/
├── spec.json                     single source of truth (workloads + proposed perf gates)
├── canopy/                       the Canopy bench app (builds with canopy-native)
│   ├── src/Main.can              3 tab-selectable workloads, stable A.testID selectors
│   ├── canopy.json native.config.json
├── rn/                           the RN 0.76.9 sibling (portable sources only)
│   ├── App.js index.js app.json package.json
├── harness/
│   └── bench-walker.js           DEVICE-FREE canopy-side measurement (runs HERE today)
└── scripts/
    ├── init-rn-project.sh        scaffold a runnable RN 0.76.9 project around rn/*.js
    ├── bench-compare.sh          ON-DEVICE side-by-side driver (gfxinfo + meminfo)
    └── compare-report.js         merge two metrics files → table + perf-bar verdict
```

---

## Running it

### 1. Canopy side, device-free (runs anywhere — no device, no RN)

Drives the **real** `package/external/native.js` walker (the same code that runs on the phone)
through the in-memory mock Fabric, for the three workloads, and reports reconciler CPU + the
host-mutation **counts** that prove the structural wins (a 1-row scroll touches ~3 host ops, not
1000; a tap is one scalar update with zero JSON):

```sh
node bench/rn-comparison/harness/bench-walker.js            # human table
node bench/rn-comparison/harness/bench-walker.js --json     # canonical metrics
node bench/rn-comparison/harness/bench-walker.js --out /tmp/canopy-walker.json
```

This lane is tagged `lane:"walker-cpu"` / `device:false` so it can never be mistaken for a device
fps number. The ns are x86_64 + machine-dependent (same caveat as `harness/bench.js`).

### 2. Canopy side, on-device (needs an emulator/device + the Canopy host installed)

```sh
export PATH="$HOME/.local/bin:$ANDROID_HOME/platform-tools:$PATH"
bench/rn-comparison/scripts/bench-compare.sh --side canopy
```

Builds the Canopy bench app, pushes its bundle to the installed host (`org.canopy.echo`, the dev
hot-reload path), flings/taps each workload, and captures `dumpsys gfxinfo` (jank% + frame-time)
and `meminfo` (RSS) + cold TTI. Emits `/tmp/rnd5-bench/canopy.json`.

### 3. RN side — scaffold once on a box with the RN toolchain

```sh
bench/rn-comparison/scripts/init-rn-project.sh /tmp/canopy-bench-rn
#   → npx @react-native-community/cli init CanopyBenchRN --version 0.76.9
#   → overlays rn/App.js, index.js, app.json onto the scaffold + npm install
cd /tmp/canopy-bench-rn && npx react-native run-android      # install the debug APK
```

### 4. Full head-to-head + perf-bar verdict (same device, RN 0.76.9 installed)

```sh
bench/rn-comparison/scripts/bench-compare.sh --side both --rn-dir /tmp/canopy-bench-rn
```

Drives the identical fling/tap on **both** apps, captures the **same** gfxinfo/meminfo on each,
writes `canopy.json` + `rn.json`, and prints the side-by-side table with the
[proposed perf-bar](#the-proposed-perf-bar) verdict. Or merge existing files directly:

```sh
node bench/rn-comparison/scripts/compare-report.js /tmp/rnd5-bench/canopy.json /tmp/rnd5-bench/rn.json
```

---

## The proposed perf bar (`spec.json` → `gates`)

These are the **proposed** M5 multipliers from `plans/10-competitor-master-plan.md`; **RND-9** will
ratify them with owner sign-off. `compare-report.js` enforces them only when given **both** sides on
the **device-fps** lane — it refuses to gate a device-free walker number against an RN device number
(apples-to-oranges). They are multiples of the RN reference **on the same device**, never absolute ms.

| metric          | bar                          |
|-----------------|------------------------------|
| list jank       | ≤ 1.2× RN, and ≤ 5% dropped  |
| tap-to-paint    | ≤ RN median + 4 ms           |
| cold TTI        | ≤ 1.3× RN                    |
| peak RSS        | ≤ 1.5× RN                    |
| no-op frame     | 0 host mutations (hard)      |

---

## Honesty — what actually ran here

| piece                         | ran here?                  | evidence |
|-------------------------------|----------------------------|----------|
| Canopy bench app **compiles** | ✅ `canopy-native build`   | `canopy/build/canopy.bundle.js` (405 KB) + codegen |
| `bench-walker.js` (device-free) | ✅ all 3 workloads, guards PASS | one-row scroll = 3 host ops / 0 re-creates; tap = 1 scalar update / 0 JSON; depth-30 = 31 views |
| `bench-compare.sh --side canopy` | ✅ on the live x86_64 emulator | `canopy.json`: list fling **2.6% jank, 17 ms p95**, TTI 602 ms, RSS 75 MB |
| `compare-report.js` merge + gate | ✅ `--selftest` PASS (5/5) | within-bar→PASS, 3× jank→FAIL, 2× RSS→FAIL, tap +3ms→PASS, lane-mismatch→no-gate |
| RN 0.76.9 app **builds/runs**  | ❌ RN 0.76.9 not installed | authored (`rn/App.js`) + scripted (`init-rn-project.sh`); run on a box with the RN toolchain |
| **head-to-head verdict**       | ❌ needs the RN side        | the gate is wired + selftested; it lights up the moment an `rn.json` exists |

**Emulator caveat.** The on-device numbers come from an **x86_64 emulator**, which is an *upper
bound* on real-device jank (no GPU-compositor parity, host-scheduler noise) — never a floor. The
caveat is embedded in every emitted metrics file so a downstream reader can never mistake it for an
arm64 measurement. Re-run on real arm64 hardware for shippable figures. The `counter`/`depth30`
`jankPct` reads high (70-75%) because those are **discrete** tap/toggle repaints — gfxinfo flags
sparse non-continuous frames as "janky"; the meaningful continuous-scroll metric is `list1000`.
