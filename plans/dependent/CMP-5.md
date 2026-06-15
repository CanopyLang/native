# CMP-5 — canopy make --target native: NativeBundle emitter

| | |
|---|---|
| **Track** | compiler |
| **Status** | todo |
| **Effort** | ~3 engineer-weeks |
| **Classification** | DEPENDENT — blocked until its prerequisites land |
| **Depends on** | CMP-1 (todo), CMP-7A (todo) |
| **Open blockers** | CMP-1 (todo), CMP-7A (todo) |
| **Source plan** | plans/10-competitor-master-plan.md |

New Generate.JavaScript.NativeBundle that emits the assembled bundle (hermes preamble, __canopy_boot, ABI fallbacks) with the map aligned to the final byte layout, killing the brittle Bundle.hs string-splice + map re-shift.

**Notes:** Owner must ratify seam: compiler owns JS+map+boot+.hbc; host owns manifest/assets/codegen/deploy.
