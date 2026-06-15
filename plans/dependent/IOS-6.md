# IOS-6 — Full Part-5 validation ledger

| | |
|---|---|
| **Track** | ios |
| **Status** | todo |
| **Effort** | ~4 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | IOS-5 (todo) |
| **Open blockers** | IOS-5 (todo) |
| **Source plan** | plans/10-competitor-master-plan.md |

Drive every Part-5 gate (ScrollView momentum, controlled TextInput, Image, Switch, Modal, anim driver, capabilities, streaming) via simulator + XCUITest until the ledger is green — the parity definition of done.

**Notes:** Predicted rework: modal keyWindow traversal, per-corner CAShapeLayer mask, blob premultiplied-alpha, leaf sizeThatFits vs Yoga measure modes.
