# IOS-1 — Provision Mac + green doctor, run to first compile

| | |
|---|---|
| **Track** | ios |
| **Status** | todo |
| **Effort** | ~0.5 engineer-weeks |
| **Classification** | INDEPENDENT — no unmet dependency, safe to assign to a parallel agent now |
| **Depends on** | none |
| **Open blockers** | none — ready to start now |
| **Source plan** | plans/10-competitor-master-plan.md |

Fill .remote-build.env and drive remote-build.sh doctor/bootstrap/gen/build until iOS reaches BUILD SUCCEEDED, confirming hermes-engine + Yoga podspecs are present.

**Notes:** Fall to vendored Path-B hermes.xcframework if the 0.76.9 pod tarball 404s. Gated on a reachable Mac.
