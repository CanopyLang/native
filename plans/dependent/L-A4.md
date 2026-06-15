# L-A4 — Paywall: Play Billing entitlement, gate restore/export

| | |
|---|---|
| **Track** | lumen |
| **Status** | partial |
| **Effort** | ~1.75 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | L-A2 (todo) |
| **Open blockers** | L-A2 (todo) |
| **Source plan** | plans/11-lumen-critical-path.md |

Wire Play Billing one-time product -> persist entitlement via Storage.Secure -> gate restore/export in update, verified against a Play internal-test product.

**Notes:** Only the Billing 'user_cancelled' wire fix landed this session (part of L-A4); full entitlement persistence + gating + real purchase remain. Blocked on L-A2 (real app/screens). Effort 1.5-2ew averaged.
