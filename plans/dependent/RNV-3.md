# RNV-3 — Scripted idempotent revendor.sh (both platforms)

| | |
|---|---|
| **Track** | stability |
| **Status** | todo |
| **Effort** | ~2 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | RNV-1 (todo) |
| **Open blockers** | RNV-1 (todo) |
| **Source plan** | plans/10-competitor-master-plan.md |

revendor.sh <rn-version> downloads/unzips matched Hermes/JSI/fbjni per ABI, refreshes headers + iOS pins + third_party/jsi, rewrites vendor.lock.json, and is idempotent (reproduces present .so byte-identical).

**Notes:** Android .so were hand-extracted with no recorded steps; every bump is archaeology. Bump CANOPY_ABI_VERSION only if our surface changed.
