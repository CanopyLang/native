# CMP-4 — Native codegen test suite + golden bundle

| | |
|---|---|
| **Track** | compiler |
| **Status** | todo |
| **Effort** | ~2 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | CMP-1 (todo), CMP-2 (todo) |
| **Open blockers** | CMP-1 (todo), CMP-2 (todo) |
| **Source plan** | plans/10-competitor-master-plan.md |

Build test/Integration/Native/ that compiles a multi-screen .can app to IIFE (dev + --optimize), snapshots bundle structure, and evaluates under headless Hermes/QuickJS in CI — the gate every later compiler change must pass.

**Notes:** Wire into package.yaml.
