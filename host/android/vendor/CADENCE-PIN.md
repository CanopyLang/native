# RNV-6 — Decouple cadence: pin Hermes + Yoga ourselves

**Decision record + the pin-2×/year policy.** Machine-readable companion:
[`cadence-pin.json`](cadence-pin.json) (this directory). Driven by
[`scripts/revendor.sh cadence`](../../../scripts/revendor.sh).

> This record lives under `host/android/vendor/` (the vendor pin lives with the binaries it
> pins). The one-paragraph cross-link into the authoritative RN-coupling contract belongs in
> [`docs/rn-coupling.md`](../../../docs/rn-coupling.md) §"Hermes" — add it there when that file's
> owner lands the cadence note; the load-bearing content is here so it ships with RNV-6.

---

## The decision

**Stop riding the React-Native release train for Hermes and Yoga. Pin each to its OWN upstream
coordinate and re-review those pins 2×/year.**

Why this is correct and low-risk: `canopy/native` does **not** use RN's Fabric runtime,
`RCTBridge`, TurboModules, or RN's native-module infra (proven by
[`scripts/check-rn-coupling.sh`](../../../scripts/check-rn-coupling.sh) — zero forbidden
symbols). The *entire* RN coupling surface is **Hermes** (the JS engine, via one factory
`canopy::makeRuntime()`), **JSI** (a small value-marshalling subset), and **Yoga** (flexbox).
None of those three need to come from an RN *release*; each ships standalone. Coupling our bump
cadence to RN's was incidental, not required.

| Surface | Independent upstream coordinate | Decoupled today? |
|---|---|---|
| **Yoga (Android)** | `com.facebook.yoga:yoga:3.2.1` (Maven Central, facebook/yoga) | **Yes** — already its own coordinate in `host/android/app/build.gradle:139`, *not* `react-android`. |
| **Yoga (iOS)** | `github.com/facebook/yoga` via SPM (`host/ios/Package.swift`) | **Mechanism ready** — pod path primary, SPM fallback pins facebook/yoga directly (Mac-gated). |
| **Hermes (Android)** | `facebook/hermes` GitHub releases — `hermes-runtime-android-v<X>.tar.gz` | **Vehicle ready, not yet active** (see "The Hermes spike" below). |
| **Hermes (iOS)** | `facebook/hermes` GitHub releases — `hermes-runtime-darwin-v<X>.tar.gz` | Mechanism ready; Mac-gated. |

**Yoga is fully decouplable today** and Android already proves it. **Hermes' decouple vehicle is
proven and scripted** (`scripts/revendor.sh cadence --fetch-hermes`), but is **deliberately not the
active binary yet** — see the spike.

---

## The Hermes spike (the empirical core of RNV-6)

RNV-6 asked: *spike standalone-Hermes-release vs AAR extraction, and verify the standalone
`libhermes` exports the C-ABI vtable* (`get_hermes_abi_vtable`, the durable RNV-4 backend (B)).

**What was actually measured** (downloaded the real upstreams and ran `nm -D --defined-only … |
grep get_hermes_abi_vtable`, the same probe as
[`scripts/check-hermes-cabi.sh`](../../../scripts/check-hermes-cabi.sh) step [2/2]):

| Hermes prebuilt | Source | Exports `get_hermes_abi_vtable`? |
|---|---|---|
| `hermes-android` 0.76.9 | RN AAR (current vendored) | **No** |
| `hermes-android` 0.77.2 / 0.78.3 / 0.79.6 / 0.81.4 / 0.82.1 | RN AARs | **No** (all) |
| `hermes-runtime-android-v0.11.0` | **facebook/hermes standalone GitHub release** | **No** |

**Finding (honest, load-bearing): NO publicly-distributed Hermes prebuilt exports the C-ABI
vtable** — not RN's AARs across six minor versions, and not the standalone `facebook/hermes`
runtime. The C-ABI (`HermesABIRuntimeWrapper` / `get_hermes_abi_vtable`, defined by
`hermes_vtable.cpp`) is compiled in **only when Hermes is built from source with the C-ABI option
enabled**. There is also **no** separately-published `hermesabi` Maven artifact.

### What that means for RNV-4 backend (B)

The durable C-vtable backend (`-DCANOPY_HERMES_CABI`, the file-swap-behind-a-frozen-C-boundary
lever) **cannot be made the default from a prebuilt** — neither RN's nor the standalone runtime
supplies the vtable export. It is gated on a **from-source Hermes build** (or the day an upstream
prebuilt flips the flag). This does not regress anything: the RNV-4 seam is already wired and
**backend (A)** (`facebook::hermes::makeHermesRuntime()`) is correct and green today; the flip is
a one-line default change in `host/shared/cpp/CanopyHermes.cpp` the moment the probe goes green.
`scripts/check-hermes-cabi.sh` runs that probe on every CI run and prints the exact flip
instruction when a vendored `libhermes` starts exporting the vtable — so this stays a *live*,
self-announcing gate, not a forgotten note.

### Why the standalone Hermes pin is recorded but NOT the active binary

`hermes-runtime-android-v0.11.0` (Jan 2022) is the newest standalone `facebook/hermes` release
that ships a ready-to-link Android runtime, but it is **older** than RN 0.76.9's Hermes and would
**regress the HBC bytecode version** that [`scripts/check-abi.sh`](../../../scripts/check-abi.sh)
pins end-to-end. So the *vehicle* is proven and scripted, but the *active* Hermes binary stays the
ABI-matched one under `host/android/vendor/lib` (whatever `check-abi.sh` proves matched) until a
from-source build gives us both a current bytecode version **and** the C-ABI export.

`scripts/revendor.sh cadence --fetch-hermes [<tag>]` pulls the standalone runtime into a staging
tree and re-runs the C-ABI probe, so the decouple path is exercisable on demand without disturbing
the active vendored binary.

---

## The pin-2×/year policy

- **Cadence:** review the independent Hermes + Yoga pins **twice a year** (next: **2026-12-15**).
- **Continuous signal, periodic decision:** the `bump-check` cron
  ([`scripts/bump-check.sh`](../../../scripts/bump-check.sh)) already files an issue whenever a
  newer stable upstream appears. That is the *signal*; this 2×/year review is the *human decision*
  on whether to actually adopt — we are explicitly **not** auto-bumping on every upstream release.
- **Adoption is ABI-gated, always.** A pin only moves when the whole chain re-greens:
  `scripts/revendor.sh fetch <v>` (or `cadence --fetch-hermes <tag>`) → `revendor.sh lock` →
  `scripts/check-abi.sh` (bytecode ⇄ baked C++ pin ⇄ boot gate) → `scripts/check-vendor-pins.sh`.
  The C++ pin in `host/shared/cpp/CanopyAbiGate.h` moves in lockstep or CI goes red.
- **`scripts/revendor.sh cadence`** is the single entry point: it validates `cadence-pin.json`,
  reports the review-by date, prints the active vs. independent pins, and (with `--fetch-hermes`)
  exercises the standalone-Hermes pull + C-ABI probe.

---

## How to run it

```sh
scripts/revendor.sh cadence                 # validate the pin + report cadence/policy (offline; CI-safe)
scripts/revendor.sh cadence --fetch-hermes  # pull the standalone facebook/hermes runtime + probe the vtable
scripts/revendor.sh cadence --fetch-hermes v0.12.0   # ...for a specific Hermes tag
scripts/check-hermes-cabi.sh                # the live C-ABI capability probe on the ACTIVE vendored libhermes
scripts/check-abi.sh                        # the end-to-end Hermes ABI gate (must stay green across a bump)
```
