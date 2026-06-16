# Canopy iOS — Part-5 Validation Ledger (IOS-6)

The single source of truth for the **iOS Part-5 validation status**, mirroring the Android
device-validated ledger. It enumerates every Part-5 gate (BUILD-AND-VALIDATE.md §5.1–§5.7), how each
is verified, and where. It builds on IOS-5 (first-light: real bundle boots, render + tap).

**The hard rule (BUILD-AND-VALIDATE.md):** *all compilation, Simulator boot, and behavioral
validation is [MAC-REQUIRED].* The iOS host cannot be compiled off macOS (Xcode/UIKit/Hermes/Yoga).
So every gate is verified by the strongest mechanism available off-Mac, with the on-device run
documented exactly.

## Three layers of verification

Each gate below is verified by one or more of:

| Layer | Where | Runs on | What it proves |
|---|---|---|---|
| **STRUCT** | `scripts/check-ios-validation-ledger.sh` | **Linux/CI** (pure grep) | the gate's load-bearing seam EXISTS in the host sources, mirrors Android, and is covered by the harness. Fails LOUD on drift. Wired as step 21 of `scripts/ci-test.sh`. |
| **UNIT** | `Tests/CanopyHostCoreTests/CanopyValidationLedgerTests.mm` + `CanopyEngineTests.mm` | **build host** (`xcodebuild test`, no Simulator UI) | the PURE logic legs (CSS color, diff-null reset, leaf measure modes, BeforeAfter wipe, ABI/blob/stream verdicts) are correct. |
| **XCUI** | `Tests/CanopyHostUITests/CanopyHostValidationTests.swift` | **[MAC-REQUIRED]** Simulator | the on-device behaviour — driven by `testID` → accessibilityIdentifier, the SAME contract as the Android Appium/Maestro flows (E2E-2). |
| **XCUI-Lumen** | `Tests/CanopyHostUITests/CanopyLumenRestoreUITests.swift` (L-I6) | **[MAC-REQUIRED · DEVICE-PREFERRED]** Simulator/iPhone | the WHOLE Lumen restore spine (pick→restore→compare→share→save→loop) — the SAME L-A6 spec, by `testID` → accessibilityIdentifier. Structurally gated device-free by `scripts/check-ios-lumen-e2e.sh` (step 30 of `ci-test.sh`); the Appium twin is `e2e/lumen-restore.mjs` (now platform-neutral). Run steps: BUILD-AND-VALIDATE.md §5.8. |

STRUCT + UNIT are **green on Linux today**. The XCUI suites (counter validation + L-I6 lumen-restore)
are **authored, Mac/device-gated** (never claimed run here); their device-free structural nets
(`check-ios-validation-ledger.sh`, `check-ios-lumen-e2e.sh`) are green on Linux.

## How to run the on-device ledger (Mac)

After `host/ios/BUILD-AND-VALIDATE.md` Parts 1–3 (vendor Hermes/Yoga, `xcodegen generate`, `pod
install`, embed a **real** `examples/counter` bundle at `CanopyHostApp/Resources/canopy.bundle.js`):

```bash
cd host/ios
# UNIT + XCUI together (the scheme runs both test bundles):
xcodebuild test \
  -workspace CanopyHost.xcworkspace \
  -scheme CanopyHost \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 15,OS=latest'

# only the Part-5 on-device ledger:
xcodebuild test ... -only-testing:CanopyHostUITests/CanopyHostValidationTests
# only the device-free legs (also runnable on a Mac without the Simulator UI):
xcodebuild test ... -only-testing:CanopyHostCoreTests/CanopyValidationLedgerTests
```

The richer component/capability gates are driven by `testID` against a **gallery/Lumen bundle** that
renders those surfaces. Until that bundle is the embedded one, the corresponding XCUI tests emit an
explicit `XCTSkip` (reported, never a silent pass), so the ledger never claims a gate it did not
actually drive. The render + event + Echo + Lifecycle spine is driven by the canonical
`examples/counter` bundle.

The structural gate alone (no Mac, no SDK):

```bash
bash scripts/check-ios-validation-ledger.sh
```

---

## The ledger

Legend — **Status:** ✅ verified by the marked layer · 🍎 Mac-gated on-device run authored, not run here.

### §5.1 Render gates

| Gate | STRUCT seam (host file) | UNIT | XCUI | Status |
|---|---|---|---|---|
| App boots → renders a native app (root pinned to `surface_`) | `CanopyHostViewController.mm` `createView("RCTRootView")` + `canopyBoot` | — | `test_5_1_render_bootsAndMountsNativeViews` | ✅STRUCT · 🍎XCUI |
| Boot-time Hermes ABI canary (IOS-4/RNV-2) before any JS | `-enforceHermesAbiGate` + `getBytecodeVersion` + `checkHermesAbi` | `CanopyEngineTests.testHermesAbiGate*` | (boot log) | ✅STRUCT ✅UNIT · 🍎XCUI |
| Yoga layout in **points**, no density multiply | `YGNodeCalculateLayout`/`YGNodeLayoutGet*`; **no** `dpToPx`/`getDisplayMetrics`/`densityDpi` | `testMeasure*` | `test_5_1_render_rootPinnedFullSizeInPoints` | ✅STRUCT ✅UNIT · 🍎XCUI |
| Color parsing (`#rgb/#rgba/#rrggbb/#rrggbbaa` CSS-last, rgb/rgba, hsl/hsla, named, transparent) | `@interface CanopyColor` + `parseHex/parseRgb/parseHsl` | `testColorHex*` / `testColorHsl*` | — | ✅STRUCT ✅UNIT |
| Styling (per-corner radius, shadow, transform, overflow) | `maskedCorners` + `CAShapeLayer` + `borderTopLeftRadius` + `shadow` + `transform` | — | (visual) | ✅STRUCT · 🍎 |
| Diff-null discipline (null → reset to default, not 0/"") | `isNull` + `NSNull` | `testDiffNull*` | — | ✅STRUCT ✅UNIT |

### §5.2 Event gates

| Gate | STRUCT seam | UNIT | XCUI | Status |
|---|---|---|---|---|
| Tap/press fires (exact `press` token → `emit_` on main) | `CanopyGestures` + `"press"` (exact) | — | `test_5_2_event_tapDispatchesTeaUpdate` | ✅STRUCT · 🍎XCUI |
| Gesture set `pan {dx,dy,vx,vy}` in points (no /density) | `UIPanGestureRecognizer` + `dx`/`vx` | — | (gallery) | ✅STRUCT · 🍎 |
| setEvents idempotency (recycled view drops its recognizer) | `setEvents` | — | (gallery) | ✅STRUCT · 🍎 |
| Second handler routes (general, not hardwired) | — | — | `test_5_2_event_secondHandlerResets` | 🍎XCUI |

### §5.3 Component gates

| Gate | STRUCT seam | UNIT | XCUI | Status |
|---|---|---|---|---|
| ScrollView — separate Yoga content root, `contentSize`, horizontal, refresh | `CanopyScrollView` + `contentYoga` + `contentSize` + `horizontal` + `refreshControl` | — | `test_5_3_component_scrollViewMomentum` | ✅STRUCT · 🍎XCUI |
| TextInput single-line — changeText/submitEditing/focus/blur, secure/keyboard | `CanopyTextInputView` + `changeText` + `secureTextEntry` + `keyboardType` | — | `test_5_3_component_controlledTextInput` | ✅STRUCT · 🍎XCUI |
| TextInput multiline (UITextView fork) | `CanopyMultilineTextInputView` + `multiline` | — | (gallery) | ✅STRUCT · 🍎 |
| Image declarative — `RCTImageView`, recycle-drop de-dup, resizeMode | `RCTImageView` + `lastSource` + `resizeMode` + `contentMode` | — | `test_5_3_component_image` | ✅STRUCT · 🍎XCUI |
| Image blob — `bitmapHandle` → `blobGetUIImage` from the one registry | `bitmapHandle` + `blobGetUIImage` | (registry: EngineTests) | (gallery) | ✅STRUCT · 🍎 |
| Switch — UISwitch → valueChange | `CanopySwitchView` + `valueChange` | — | `test_5_3_component_switch` | ✅STRUCT · 🍎XCUI |
| Modal — own content root, keyWindow traversal, inline 0×0, visible-last | `CanopyModalHostView` + `UIWindowScene` + `presentViewController` + `sizeThatFits…CGSizeZero` | — | `test_5_3_component_modalPresentDismiss` | ✅STRUCT · 🍎XCUI |
| BeforeAfter — CALayer wipe, before/after blob handles, wipeStart/wipeCommit | `CanopyBeforeAfterView` + `beforeHandle` + `afterHandle` + `wipeStart`/`wipeCommit` | `testBeforeAfterWipe*` (shared C++ op, runs for real) | `test_5_3_component_beforeAfterWipe` | ✅STRUCT ✅UNIT · 🍎XCUI |
| Leaf `sizeThatFits` ↔ Yoga measure modes (Exactly/AtMost/Undefined) | `YGNodeSetMeasureFunc` + all three `YGMeasureMode*` | `testMeasure*` | — | ✅STRUCT ✅UNIT |

### §5.3b Imperative-command seam (IOS-8)

The ONE imperative seam, reconciled with AND-3: a single global `__fabric_command(handle, name,
argsJson)`, a single host virtual `CanopyHost::command`, and a single JS routing path (`__callId` →
`__commandResult`). The iOS `command()` override in `CanopyHostFabric.mm` is the line-for-line twin
of Android's AND-4 `CanopyHost.java::command`. The pure JSON marshalling is pinned device-free; the
UIKit behaviours run on a Simulator. Structural gate: `scripts/check-ios-command-seam.sh`.

| Gate | STRUCT seam | UNIT | XCUI | Status |
|---|---|---|---|---|
| `focus`/`blur` — `becomeFirstResponder`/`resignFirstResponder` + keyboard, deferred (RN focus-timing fix) | `commandFocus` + `becomeFirstResponder` + `dispatch_async(…main_queue)` | — | `test_5_3b_command_focusBlur` | ✅STRUCT · 🍎XCUI |
| `measure` — Yoga offset/size (points) + window coords via `convertRect:toView:nil`, RN UIManager.measure contract | `commandMeasure` + `convertRect:v.bounds toView:nil` | `testCommandMeasureResultJson*` | `test_5_3b_command_measure` | ✅STRUCT ✅UNIT · 🍎XCUI |
| `scrollTo`/`scrollToIndex` — `setContentOffset` (points), child-N Yoga frame | `commandScrollTo` + `commandScrollToIndex` + `setContentOffset:` | — | `test_5_3b_command_scrollTo` | ✅STRUCT · 🍎XCUI |
| async result round-trip — echo `__callId`, emit on the `__commandResult` path | `parseCallId`/`measureResultJson`/`mergeCallId` + `emit_(…"__commandResult"…)` | `testCommandParseCallId*` + `testCommandMergeCallId*` | (via the three above) | ✅STRUCT ✅UNIT · 🍎XCUI |

### §5.4 Animation gate

| Gate | STRUCT seam | UNIT | XCUI | Status |
|---|---|---|---|---|
| CADisplayLink driver (`CanopyAnimDriver`), base opacity/transform cache | `CanopyAnimDriver` + `CADisplayLink` + `doFrame` + base-cache | — | `test_5_4_animation_drivesAndCleansUp` | ✅STRUCT · 🍎XCUI |
| Remove-during-animation safety (removeChild cancels) | `removeChild` | — | (same test) | ✅STRUCT · 🍎 |

### §5.5 Capability (C1 effect ABI) gates

Each routes `__canopy_call(module, method, argsJson, callId)` → the by-name ObjC bridge → the Swift
module → `complete(err,res)` → `canopyResolveCall`. The dispatcher is **immutable + reflective**:
`caps[]` only NAMES modules. STRUCT asserts every module is named with the right streaming spec and
that both iOS + Android cover the SAME capability surface.

| Capability | iOS `caps[]` / registration | Streaming spec | XCUI | Status |
|---|---|---|---|---|
| `Echo` (shared C++ bridge smoke) | C++ registration | — | `test_5_5_capability_echoRoundTrips` | ✅STRUCT · 🍎XCUI |
| `Photos` | caps[] | one-shot | (gallery, autoAcceptAlerts) | ✅STRUCT · 🍎 |
| `Album` | caps[] | one-shot | (gallery) | ✅STRUCT · 🍎 |
| `ShareImage` | caps[] | one-shot | (gallery) | ✅STRUCT · 🍎 |
| `StorageSecure` | caps[] | one-shot | (gallery) | ✅STRUCT · 🍎 |
| `Notify` | caps[] | one-shot | (gallery) | ✅STRUCT · 🍎 |
| `Image` | caps[] | one-shot | (gallery) | ✅STRUCT · 🍎 |
| `Http` | caps[] | one-shot | (gallery) | ✅STRUCT · 🍎 |
| `Platform` (Linking + Clipboard) | caps[] | one-shot | (gallery) | ✅STRUCT · 🍎 |
| `Billing` (StoreKit 2) | caps[] | `entitlementChanges` | (gallery, sandbox) | ✅STRUCT · 🍎 |
| `Lifecycle` | caps[] | `appState`, `memoryPressure`, `backPressed` | `test_5_5_streaming_lifecycleAppState` | ✅STRUCT · 🍎XCUI |
| `AppShell` | caps[] | `colorScheme` | (gallery) | ✅STRUCT · 🍎 |
| `Vibration` (IOS-7) | caps[] | one-shot | (captest; Core Haptics / system vibration) | ✅STRUCT · 🍎 |
| `Haptics` (IOS-7) | caps[] | one-shot | (gallery; UIFeedbackGenerator) | ✅STRUCT · 🍎 |
| `Battery` (IOS-7) | caps[] | one-shot | (gallery; UIDevice battery) | ✅STRUCT · 🍎 |
| `DeviceInfo` (IOS-7) | caps[] | one-shot | (gallery; uname/UIDevice) | ✅STRUCT ✅UNIT · 🍎 |
| `NetInfo` (IOS-7) | caps[] | one-shot | (gallery; NWPathMonitor snapshot) | ✅STRUCT · 🍎 |
| `Brightness` (IOS-7) | caps[] | one-shot | (gallery; UIScreen.brightness) | ✅STRUCT · 🍎 |
| `RestoreEngine` (Core ML) | weak factory | — | (Lumen; Apple-only inference) | ✅STRUCT · 🍎 |
| **Streaming** mechanics (subscribe keeps open, emit repeats, `$done` tears down) | `CanopyStreamingModuleBase` `emitOnChannel`/`cancelCallId` | `CanopyEngineTests.testStreaming*` | (lifecycle test) | ✅STRUCT ✅UNIT · 🍎 |

**IOS-7 — iOS↔Android capability parity (no capability is iOS-lost).** Every Android JniModule
capability now has an iOS twin `Canopy<Name>Module.mm` that adopts `<CanopyModule>` (or subclasses
`CanopyStreamingModuleBase`), reports the matching `-moduleName`, handles every method its `.can`
wire contract calls, and is registered in `CanopyModuleHost.mm`'s `registerAll` `caps[]`. The six
twins authored for IOS-7 use iOS-native, permission-free APIs (the Android side needs `VIBRATE` /
`ACCESS_NETWORK_STATE`): `Vibration`→Core Haptics `CHHapticEngine` (continuous event of the
requested `ms`) with an `AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)` fallback on hardware
without Core Haptics; `Haptics`→`UIImpactFeedbackGenerator`/`UINotificationFeedbackGenerator`/
`UISelectionFeedbackGenerator`; `Battery`→`UIDevice` battery (level already `0.0..1.0`);
`DeviceInfo`→`uname(2)`+`UIDevice`+`NSProcessInfo` (the major OS version is the cross-platform
`sdkInt`); `NetInfo`→`NWPathMonitor` first-path snapshot; `Brightness`→`UIScreen.brightness` (already
`0.0..1.0`, no `/255`). The device-free legs are pinned in `CanopyCapabilityParityTests.mm` (each twin
resolves by name, conforms, names itself, rejects unknown methods, accepts every `.can` method, and
`DeviceInfo.info` returns the exact `{model,manufacturer,systemVersion,sdkInt}` shape on the build
host); the structural parity is gated device-free on Linux by `scripts/check-ios-capability-parity.sh`.
The real per-twin hardware behaviour (a buzz, a haptic tap, a live battery read) is **🍎 Mac/device-only**.

### §5.6 Link-time invariant

| Gate | STRUCT seam | Status |
|---|---|---|
| Exactly ONE `globalBlobRegistry()` (Risk #8) — only in `CanopyBlobRegistryHost.mm`; the Android-only definers are NOT in the iOS sources | `globalBlobRegistry`/`blobGetUIImage`/`blobPutUIImage` present in the blob host; `CanopyRestoreEngineModule.mm` does NOT redefine it | ✅STRUCT (linker confirms on Mac) |

### §5.7 Threading invariant

| Gate | STRUCT seam | Status |
|---|---|---|
| `jsi::Runtime` touched only on main; the boot emit closure is the sole `canopyEmitEvent` site; workers hop back via `postToJs` | `canopyEmitEvent` + `dispatch_async(dispatch_get_main_queue)` in the VC; `postToJs`/main-queue hop in the bridge | ✅STRUCT (audit) |

---

## Parity with Android (the iOS ledger is the MIRROR)

`scripts/check-ios-validation-ledger.sh` §P cross-checks that **every capability the iOS `caps[]`
names also exists on the Android side** (the JNI registrant or a `…Module.java`), so the two ledgers
cover the SAME surface and neither platform silently drifts ahead. The XCUI suite selects by
`testID` → accessibilityIdentifier and reads on-screen copy off the element tree — byte-for-byte the
contract `e2e/smoke.mjs` (Appium) and `e2e/flows/counter-smoke.yaml` (Maestro) use on Android — so
the SAME assertions describe both platforms (E2E-2).

## Predicted-rework surfaces (IOS-6 plan) — where each landed

The IOS-6 plan flags four surfaces likely to need rework on the first real Mac build. Each has a
concrete landing site the structural gate pins, so a regression that removes it goes red:

| Predicted rework | Landing site (asserted) |
|---|---|
| Modal `keyWindow` traversal | `CanopyHostFabric.mm` `topPresenter` / `UIWindowScene.windows` / `rootViewController` |
| Per-corner `CAShapeLayer` mask | `CanopyHostFabric.mm` `maskedCorners` + `CAShapeLayer` + `borderTopLeftRadius` |
| Blob premultiplied-alpha | `CanopyBlobRegistryHost.mm` `kCGImageAlphaPremultipliedLast` (UNIT: BeforeAfter wipe) |
| Leaf `sizeThatFits` vs Yoga measure modes | `CanopyHostFabric.mm` `leafMeasureThunk` (UNIT: `testMeasure*`) |

## What is NOT verifiable here (honest scope)

- Real Hermes/Yoga linking, code signing, Simulator boot, and **every** behavioral assertion in the
  XCUI suite — all [MAC-REQUIRED]. This file + the structural gate are the device-free net.
- Core ML inference (`RestoreEngine`) — Apple-only.
- The gallery/Lumen bundle that exposes the richer component/capability surfaces is not the embedded
  bundle in this repo; those XCUI tests `XCTSkip` until it is. The render + event + Echo + Lifecycle
  spine is driven by the canonical `examples/counter` bundle.
