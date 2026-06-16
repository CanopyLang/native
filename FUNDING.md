# Funding & sustainability — canopy/native

A bus-factor-1 project that asks teams to bet a production app on it must answer "who pays to keep this
alive?" honestly. This is the plan, not a guarantee.

## Why funding is the gating risk (not the tech)

The reliability + compatibility roadmap ([`plans/MASTER-PLAN.md`](plans/MASTER-PLAN.md)) is ~119
engineer-weeks. The parts that *cannot* be done by an unfunded solo dev are concrete and few:

- **Real-device + store validation** — paid Apple Developer account ($99/yr), a Play account ($25
  one-time), physical arm64 devices, and a **cloud device farm** (Firebase Test Lab / BrowserStack,
  metered per-minute). This is the denominator for the crash-free-session metric, so it gates the
  headline reliability claim.
- **CI minutes** — macOS runners bill ~10× Linux; `ios-build` + iOS Appium + nightly device-farm +
  reproducible double-builds add up. Free-tier GitHub Actions will not cover a required-everywhere
  matrix at steady state.
- **A second maintainer** — the only real fix for bus-factor 1 (see [`GOVERNANCE.md`](GOVERNANCE.md)).

Everything else (the compiler, the host, the gates, the docs, the AI-codegen toolchain) is solo-doable.

## Revenue hypotheses (ordered by realism, all unproven)

1. **Managed build + OTA service** (an EAS-analog): hosted signed builds + an OTA channel with staged
   rollout/rollback. First paid SKU candidate — usage-based, mirrors the proven Expo EAS model.
   *Cost model input:* macOS build minutes + edge bandwidth for OTA payloads.
2. **Private package registry + capability marketplace**: host third-party `gen-capability` packages
   (CAP-1/4) behind a paid tier once the ecosystem exists.
3. **AI-codegen service**: a hosted MCP "compiler-as-verifier" endpoint (AAG-1/2) — agents write
   `.can`, the service compiles/repairs. Differentiated because the strict compiler is the verifier.
4. **Support/SLA contracts** for teams shipping on the reliability guarantee.

**First paid SKU (the one to validate first): the managed OTA channel** — it has the clearest analog
(EAS Update is in every Expo plan), the lowest infra cost to prototype (signed manifest + a static
bucket + the existing red-box rollback), and it directly monetizes the zero-churn-upgrade edge.

## Sponsorship

Until a service exists, sponsorship (GitHub Sponsors / Open Collective) funds the account/device/CI
costs above. A sponsor or backing org that holds a copy of the signing keys is also the bus-factor
succession anchor (GOVERNANCE.md).

## Honest status

There is **no revenue and no committed funding today**. This document exists so the funding gap is an
explicit, sized line item — not a surprise — and so the first dollar has a designated target (the OTA
SKU + the device/account beachhead).
