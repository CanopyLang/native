# AUTO-D-CPP-STREAMING — Phase D: extract C++/streaming modules (Billing, Streaming, RestoreEngine)

| | |
|---|---|
| **Track** | autolinking |
| **Status** | todo |
| **Effort** | ~1 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | AUTO-D-JNI (todo) |
| **Open blockers** | AUTO-D-JNI (todo) |
| **Source plan** | plans/12-native-autolinking.md |

Extract the C++/streaming modules last (Billing's bespoke C++ module, the two StreamingJniModule instances for Lifecycle/AppShell, RestoreEngineModule) since they exercise C++/streaming codegen and model-bytes-after-boot wiring.

**Notes:** Tail of plan Phase D; explicitly sequenced after the pure-JNI extractions because it exercises the C++ and streaming codegen paths.
