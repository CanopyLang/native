# Plan split for parallel agents

> Generated from the live plans (10 master · 11 lumen · 12 autolinking) by decomposing every work item and resolving its dependency graph. **Legacy plans 00–09 are superseded by plan 10** (scanned; unique leftovers listed at the bottom for triage).

Two folders, one file per work item:

- **`plans/independent/`** — every item with **no unmet dependency**: safe to hand to a parallel agent **right now**. (22 items)
- **`plans/dependent/`** — items blocked by ≥1 unfinished prerequisite (its open blockers are listed in the file). (69 items)

An item is *independent* iff every one of its `deps` is already **done** (or it has none). A dep that is itself todo/partial, or an external blocker (e.g. "a Mac"), makes an item *dependent*.

## Already shipped this session (excluded from the folders)

git tree · release security fail-closed (AND-1) · lazy/`__refs` memoization + run-lazy.js (RND-1/2) · Before/After host-layout fix (L-A1) · iOS RestoreEngine weak-symbol + ImageModule import · signed R8 release + APK splits (AND-2) · Billing `user_cancelled` wire fix · E2E lumen-restore specs (authored) · remote provision/test scripts · **autolinking engine + host wiring + canopy/ping proof**. (13 mapped items marked done.)

## ▶ Independent — start now, in parallel (grouped by track)

### android  (5)
| id | item | track | wk | open blockers |
|---|---|---|---|---|
| `AND-10` | Crash symbolication + release map archival | android | 1 | — |
| `AND-11` | Android instrumented-test + CI harness | android | 2 | — |
| `AND-3` | __fabric_command ABI seam | android | 1.5 | — |
| `AND-6` | Image: cache/lifecycle/error states/headers | android | 2 | — |
| `AND-8` | Reduce per-mutation JSON marshalling | android | 2 | — |

### autolinking  (2)
| id | item | track | wk | open blockers |
|---|---|---|---|---|
| `AUTO-B-REG-IOS` | Generate iOS caps[]-equivalent registrant array fragment | autolinking | 1 | — |
| `AUTO-VIEWTAG` | View-tag codegen: generate CanopyViewRegistry.register calls | autolinking | 1 | — |

### ci  (1)
| id | item | track | wk | open blockers |
|---|---|---|---|---|
| `CI-1` | Keystore scrub + compiler version-control decision | ci | 0.5 | — |

### compiler  (3)
| id | item | track | wk | open blockers |
|---|---|---|---|---|
| `CMP-1` | Land+test IIFE tree-shaker root-scan | compiler | 1.5 | — |
| `CMP-2` | Land+test effect-manager reachability | compiler | 1.5 | — |
| `CMP-3` | Land+test installed-version resolver | compiler | 1 | — |

### devloop  (2)
| id | item | track | wk | open blockers |
|---|---|---|---|---|
| `DEV-3` | Runtime state seam in runtime.js | devloop | 1.5 | — |
| `DEV-9` | Sub-second incremental rebuild | devloop | 2 | — |

### ios  (2)
| id | item | track | wk | open blockers |
|---|---|---|---|---|
| `IOS-1` | Provision Mac + green doctor, run to first compile | ios | 0.5 | — |
| `L-I1` | iOS first compile + Hermes/JSI runtime wired | ios | 3 | — |

### lumen  (2)
| id | item | track | wk | open blockers |
|---|---|---|---|---|
| `L-A0` | Re-confirm probe gates on a fresh emulator after the security + lazy fixes | lumen | 0.2 | — |
| `L-A2` | Assemble the real Lumen app on the live capability set + screens | lumen | 4 | — |

### perf  (1)
| id | item | track | wk | open blockers |
|---|---|---|---|---|
| `RND-3` | Deterministic JS-CPU timing harness | perf | 1 | — |

### remote  (2)
| id | item | track | wk | open blockers |
|---|---|---|---|---|
| `RB-3` | Release-validation safety gate (remote) | remote | 0.5 | — |
| `RB-4` | One-command provision-and-test <IP> | remote | 1 | — |

### stability  (2)
| id | item | track | wk | open blockers |
|---|---|---|---|---|
| `RNV-1` | vendor.lock.json + provenance | stability | 1 | — |
| `RNV-5` | Freeze the RN coupling surface as a contract doc | stability | 1 | — |

## ⛔ Dependent — blocked (unblock the prerequisites first)

### android  (4)
| id | item | track | wk | open blockers |
|---|---|---|---|---|
| `AND-4` | focus/blur, measure, scrollTo/scrollToIndex | android | 2 | AND-3 |
| `AND-5` | TextInput controlled-input parity | android | 1.5 | AND-4 |
| `AND-7` | ScrollView + Modal polish | android | 1.5 | AND-4 |
| `AND-9` | Coalesce/backpressure Cmd/Sub completions | android | 2 | AND-8 |

### autolinking  (4)
| id | item | track | wk | open blockers |
|---|---|---|---|---|
| `AUTO-C-IOS` | Generate iOS xcodegen/Podfile includes + Info.plist permissions | autolinking | 1 | AUTO-B-REG-IOS |
| `AUTO-D-CPP-STREAMING` | Phase D: extract C++/streaming modules (Billing, Streaming, RestoreEngine) | autolinking | 1 | AUTO-D-JNI |
| `AUTO-D-JNI` | Phase D: extract pure-JNI in-host modules into canopy/* packages | autolinking | 2 | AUTO-B-REG-IOS, AUTO-C-IOS |
| `AUTO-E-DELETE` | Phase E: delete hardcoded boot blocks + rewrite CONVENTIONS §6 + evolve gen-capability | autolinking | 0.5 | AUTO-D-JNI, AUTO-D-CPP-STREAMING |

### ci  (9)
| id | item | track | wk | open blockers |
|---|---|---|---|---|
| `CI-2` | Reproducible patched compiler | ci | 1.5 | CI-1 |
| `CI-3` | Build the bundle FROM SOURCE in CI | ci | 1.5 | CI-2 |
| `CI-4` | Stack/Gradle/Pods caching | ci | 1 | CI-2, CI-3 |
| `CI-5` | Vendored-.so storage (LFS vs fetch-script) | ci | 0.5 | CI-1 |
| `CI-6` | Flip iOS CI to required + remote-Mac fallback | ci | 1 | CI-3 |
| `CI-7` | Reconcile canonical CI app + unify gates | ci | 0.5 | CI-2, CI-3 |
| `DF-1` | Device-farm strategy (real arm64 + real iOS) | ci | 2 | E2E-1 |
| `E2E-1` | Appium smoke flow on a CI emulator | ci | 1.5 | CI-3 |
| `E2E-2` | iOS XCUITest e2e | ci | 1.5 | E2E-1 |

### compiler  (11)
| id | item | track | wk | open blockers |
|---|---|---|---|---|
| `CMP-10` | Hermes stdlib gaps: Intl/regex/Date shims | compiler | 4 | CMP-4 |
| `CMP-11` | RN-target version stamp in the bundle | compiler | 1.5 | CMP-8 |
| `CMP-12` | Compact mutation encoding | compiler | 3 | CMP-4, CMP-8b |
| `CMP-4` | Native codegen test suite + golden bundle | compiler | 2 | CMP-1, CMP-2 |
| `CMP-5` | canopy make --target native: NativeBundle emitter | compiler | 3 | CMP-1, CMP-7A |
| `CMP-6` | Fix source-map generated-line base for IIFE/native | compiler | 2 | CMP-1 |
| `CMP-7A` | Def-level column-precise source maps (Stage A) | compiler | 1 | CMP-6 |
| `CMP-7B` | Sub-line/column source maps (Stage B) | compiler | 4 | CMP-6 |
| `CMP-8` | Hermes .hbc emission + versioned bundle container | compiler | 3 | CMP-5, CMP-8b |
| `CMP-8b` | Minimal native bundle: DCE + prod source map | compiler | 2.5 | CMP-2, CMP-5 |
| `CMP-9` | Fast Refresh codegen for the native IIFE | compiler | 5 | CMP-5, CMP-7A |

### devloop  (9)
| id | item | track | wk | open blockers |
|---|---|---|---|---|
| `DEV-10` | Reload-diff perf gate | devloop | 0.5 | DEV-8 |
| `DEV-11` | Error overlay in the loop + reload-failure recovery | devloop | 1 | DEV-6, DEV-8 |
| `DEV-12` | iOS dev-loop parity | devloop | 2 | DEV-4, DEV-6 |
| `DEV-2` | JS reload seam in native.js | devloop | 2 | DEV-3 |
| `DEV-4` | In-process reload entry point (Android) | devloop | 1.5 | DEV-2 |
| `DEV-5` | Dev server: watcher + incremental rebuild + WS push | devloop | 2.5 | DEV-9 |
| `DEV-6` | Host dev client (debug-only WS) | devloop | 1.5 | DEV-4, DEV-5 |
| `DEV-7` | Connect-by-IP (Wi-Fi / remote box) | devloop | 1 | DEV-6 |
| `DEV-8` | True state-preserving Fast Refresh + Model type-hash fallback | devloop | 2 | DEV-4, DEV-2 |

### ios  (15)
| id | item | track | wk | open blockers |
|---|---|---|---|---|
| `IOS-10` | iOS Release archive (signing/ATS/entitlements) | ios | 2 | IOS-6 |
| `IOS-11` | TestFlight pipeline | ios | 1.5 | IOS-10 |
| `IOS-12` | iOS hot-path marshalling | ios | 2.5 | IOS-5 |
| `IOS-2` | Triage first-compile error classes | ios | 3 | IOS-1 |
| `IOS-4` | Confirm/harden Hermes/Yoga xcframework ABI match | ios | 1 | IOS-1 |
| `IOS-5` | First-light: real bundle boots, render+tap | ios | 1 | IOS-2, IOS-4 |
| `IOS-6` | Full Part-5 validation ledger | ios | 4 | IOS-5 |
| `IOS-7` | Close iOS<->Android capability divergence | ios | 3 | IOS-6 |
| `IOS-8` | Shared imperative ABI (__fabric_callMethod) | ios | 3 | IOS-6 |
| `IOS-9` | Shared cross-platform test-vector suite | ios | 2.5 | IOS-6 |
| `L-I2` | Capability parity on iOS | ios | 2.5 | L-I1 |
| `L-I3` | RestoreEngine on iOS (Core ML / ANE) | ios | 2.5 | L-I1 |
| `L-I4` | Before/After on iOS + parity vectors | ios | 1.75 | L-I1 |
| `L-I5` | StoreKit 2 paywall + signing/provisioning + TestFlight | ios | 2.5 | L-I2 |
| `L-I6` | E2E parity on iPhone | ios | 1 | L-A6, L-I2 |

### lumen  (3)
| id | item | track | wk | open blockers |
|---|---|---|---|---|
| `L-A4` | Paywall: Play Billing entitlement, gate restore/export | lumen | 1.75 | L-A2 |
| `L-A5` | Asset + memory budget pass | lumen | 1.5 | L-A2 |
| `L-A6` | E2E: lumen-restore flow green on emulator | lumen | 1 | L-A2 |

### perf  (8)
| id | item | track | wk | open blockers |
|---|---|---|---|---|
| `RND-10` | Stress/fuzz suite | perf | 1.2 | RND-3 |
| `RND-11` | Per-commit perf regression gate | perf | 0.8 | RND-9, RND-10 |
| `RND-4` | On-device frame instrumentation (Android) | perf | 1.2 | RND-3 |
| `RND-5` | Head-to-head RN 0.76.9 benchmark app | perf | 2 | RND-4 |
| `RND-6` | Make Native.List genuinely skip off-window work | perf | 1 | RND-4 |
| `RND-7` | Eliminate per-mutation JSON (batch -> maybe binary) | perf | 2.5 | RND-3, RND-4 |
| `RND-8` | (Conditional) Move JS off the UI thread | perf | 2 | RND-7 |
| `RND-9` | Ratify + prove the 'competitive' perf bar | perf | 0.8 | RND-5, RND-6 |

### stability  (6)
| id | item | track | wk | open blockers |
|---|---|---|---|---|
| `RNV-2` | Boot-time + CI Hermes/JSI ABI gate | stability | 1.5 | RNV-1 |
| `RNV-3` | Scripted idempotent revendor.sh (both platforms) | stability | 2 | RNV-1 |
| `RNV-4` | Re-bind Hermes through the stable C-vtable ABI | stability | 4 | RNV-2, RNV-3 |
| `RNV-6` | Decouple cadence: pin Hermes+Yoga ourselves | stability | 3 | RNV-3, RNV-4 |
| `RNV-7` | Ship real .hbc so bytecode-version is the gated contract | stability | 2 | RNV-2, RNV-3 |
| `RNV-8` | Wire re-vendor + ABI gate into CI | stability | 1.5 | RNV-1, RNV-2, RNV-3, RNV-5 |

## Legacy plans 00–09 — unique items to triage (not yet filed)

These appeared in the older phase plans and did NOT clearly map to a live (10/11/12) item. Confirm each is not already covered before scheduling:

| id | item | one-line |
|---|---|---|
| `A11Y-M5-REDUCEMOTION` | Reduced-motion honoring in the animation driver | Single flag read in CanopyHost ctor + refreshed via Sub; CanopyAnimDriver.start snaps current=to + emits start+end when set, honoring owned- |
| `A11Y-M7-TESTGATE` | a11y testing depth + audit gate | Extend run-a11y.js coverage + an automated a11y audit gate in CI across both hosts. |
| `CAP-M5-DEVICE` | Geolocation + Biometrics + Sensors + Deep/universal links | 4 capabilities (3 streaming Subs): FusedLocation, BiometricPrompt, SensorManager, intent-filter/App-Links. |
| `CAP-M7-MEDIA` | Camera + Audio + Video + Background | CameraX/MediaRecorder/ExoPlayer(MediaPlayer)/WorkManager; camera preview + video surface are render-seam views (coordinate with Render plan) |
| `CAP-M8-IOS-PORT` | iOS port of all capability backings + WorkerPool + receipt validation | Fill all <Name>Module.swift stubs, port registrations to iOS boot, shared canopy::WorkerPool, server-side receipt validation, WorkManager ba |
| `DX-JS-ERRORBOUND` | JS error-boundary + unhandled-rejection coverage | Broaden _Native_safeDraw into _Native_guard around init/update/Cmd-Sub continuations + animator, route to __canopy_onError, register Hermes  |
| `DX-OTA` | OTA updates + rollback (CodePush/EAS-Update equivalent) | canopy-native publish (signed Ed25519 update.json + sha-named HBC), CanopyUpdater.java check/verify/download/atomic-swap, rollback-on-boot-f |
| `ESC-M0-ABI` | Freeze + publish the public extension ABI | host/shared/cpp/CanopyAbi.h (CANOPY_ABI_VERSION + NativeModule/CanopyViewFactory), globalThis.__canopy_abi_version in native.js, docs/extens |
| `ESC-M2-CUSTOM` | Native.hostComponent API + real __2_CUSTOM JS render path | Native.hostComponent API in Native.can; implement native.js:238 custom render/diff so VirtualDom.custom subtrees render instead of empty. Mo |
| `ESC-M3-MODULEREG` | App-provided NativeModule registration (no boot edits) | registerExternalModule + a generated module-registrations.inc the boot #includes; iOS reuses +registerModuleNamed:. |
| `ESC-M4-SDK` | canopy-native-sdk package + gen-library scaffolder | Published SDK package (Native.HostComponent/Native.Module/Native.Abi); canopy-native gen-library <Name> emitting .can + Android factory/modu |
| `LAYOUT-COLOR` | Color foundation (CanopyColor.java) — fix invisible-UI bug | New CanopyColor.java (#hex 3/4/6/8 + rgb/rgba/hsl/hsla/named/transparent), repoint all host color call-sites, remove the bridge 8-hex reorde |
| `MB-M1-FINGERPRINT` | build --release -> store-ready artifacts + runtimeVersion fingerprint | Tool drives optimized bundle -> hermesc HBC -> signed .aab + archived sourcemap; bakes a canopy.runtimeVersion fingerprint (module list + AB |
| `MB-M2-SUBMIT` | Automated store submission (Play + App Store) | canopy-native submit + release.yml on rc-* tags uploads AAB to Play (service-account) and IPA to ASC (.p8 via remote-build.sh archive->expor |
| `NAV-M0-STACK` | Navigator core in pure .can (stack over NavStack + transition) | navigation/src/Native/Navigation/Stack.can: Config/Screen records, stack renderer with plain Native.view header row, translateX slide via ex |
| `NAV-M2-NATIVE-HEADER` | Native header + CanopyStackHost/CanopyScreen + transitions (Android) | Host-owned 60fps slide via CanopyAnimDriver, native header bar, real per-route native subtrees (named CanopyStackHost nodes). iOS authored o |
| `NAV-M3-TABDRAWER` | Tab + drawer navigators | CanopyTabBarHost (badges/icons/focus) + CanopyDrawerHost (edge-swipe/scrim); nested navigators = composed NavStacks. iOS authored only. |
| `NAV-M4-GESTUREBACK` | Gesture-back: iOS interactive swipe + Android predictive back | Finger-tracked pop at 60fps host-side; commits a pop only on release. Android runnable now; iOS authored. |
| `OBS-M3-SIGNAL` | Native-signal + unhandled-rejection capture | CanopySignal.cpp/.h async-signal-safe handler (write/unwind/dladdr, persist-then-upload-next-boot, chain prior handler) for SIGSEGV/SIGABRT  |
| `PKG-PREAMBLE` | native.js/preamble correctness: setTimeout delay + webcompat shims | Fix Bundle.hs:48 setTimeout delay bug (ignores _ms), splice webcompat.js, ship pure-JS shims (TextEncoder/Decoder, atob/btoa, URL, Blob, For |
| `TEST-T1-TESTING` | Native.Testing .can module (un-phantom the test engine) | New src/Native/Testing.can binding the 7 engine fns (testRootTag/RootText/ChildTags/Create+UpdateCountForUpdate/TextAfterUpdate/StyleValue), |
