# Governance — canopy/native

canopy/native is, today, a **single-maintainer** project (bus-factor 1). That is its single biggest
adoption risk, and this document confronts it directly instead of pretending otherwise — because the
correctness/reliability thesis is worthless to a team that can't trust the project will outlive one
person. The model here is deliberately lightweight but real.

## Decision-making (now)

- The maintainer is the BDFL for technical direction.
- **Material changes go through an RFC** (see [`rfcs/0000-template.md`](rfcs/0000-template.md)): the
  load-bearing surfaces — the `__fabric_*` / `__canopy_*` JSI ABI, the reliability guarantee scope
  ([`docs/guarantee.md`](docs/guarantee.md)), the vendored RN/Hermes pin, the public Canopy API
  (`package/src/Native.can`), and anything that would weaken a CI gate — may not change without a
  merged RFC. This keeps the most dangerous changes deliberate and reviewable even with one maintainer.
- Everything else: a PR with green CI.

## Bus-factor mitigation (the actual succession plan)

The project is built so a second maintainer can take over with no tribal knowledge:

1. **Reproducible from a pin.** The whole bundle is built from a SHA-pinned compiler
   (`scripts/compiler-pin.env`) by `scripts/build-compiler-from-pin.sh`; REPRO-1 adds a byte-identical
   double-build gate. A new maintainer reproduces the exact artifact from the repo alone.
2. **Secrets are documented, not hoarded.** Every CI secret (`CANOPY_KEYSTORE_BASE64`, `APPLE_*`,
   `ASC_*`, the OTA signing key) is enumerated in [`docs/ci-secrets.md`](docs/ci-secrets.md) with how
   to regenerate it. The Android upload key uses Google Play App Signing (recoverable); the OTA key is
   a rotatable pinned *set* (see [`SECURITY.md`](SECURITY.md)).
3. **The gates are the spec.** `scripts/ci-test.sh` (30+ device-free gates) + the green `ios-build` /
   Android jobs encode the behavioural contract, so "what must stay true" is executable, not folklore.
4. **Provenance is recorded.** `host/vendor.lock.json` + the SBOM (`scripts/gen-sbom.sh`) mean the
   native supply chain is reconstructable.

If the maintainer becomes unavailable, the repo + `docs/ci-secrets.md` + a copy of the signing keys
held by the project's funder/owner are sufficient to continue. **Honest limit:** there is no second
committer today; this plan reduces the *cost* of succession, it does not eliminate the risk. Resolving
it requires a second maintainer or a funded org (see [`FUNDING.md`](FUNDING.md)).

## Contributors

See [`CONTRIBUTING.md`](CONTRIBUTING.md). PRs must keep every existing CI gate green and add a gate for
new load-bearing behaviour. New contributors are credited; sustained contributors can be granted
review/merge rights by the maintainer.

## License

BSD-3-Clause (matches the Canopy packages). Contributions are accepted under the same license.

## Incident response

A production reliability incident (a crash-free-session gate breach, REL-4) or a security report
(SECURITY.md) follows: triage → mitigate (OTA hotfix path once DXL-4 lands, or a store update) →
post-mortem RFC. With bus-factor 1 there is no on-call rotation — this is stated plainly so adopters
size their own risk; it is the first thing a funding/co-maintainer arrangement should fix.
