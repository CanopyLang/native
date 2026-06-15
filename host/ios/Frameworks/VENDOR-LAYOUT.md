# Frameworks/ — vendored dependency layout (Author A)

CocoaPods (the `Podfile`) is the **primary** path for Hermes + JSI + Yoga; nothing is required
in this directory for the normal build. This file documents the **offline / vendored** fallback
for when a Mac cannot run `pod install` against the network (air-gapped CI, reproducible builds).

## Why these three, and the version pin

The host links exactly three third-party things, all from **one React Native 0.76.9 release** so
the JSI `Value`/`Runtime` ABI matches the linked Hermes binary (SHARED CONTRACT Risk #1 — a
mismatch is a silent crash):

| Dependency | Public surface used | Source of truth |
|---|---|---|
| **Hermes** | `facebook::hermes::makeHermesRuntime()` | `hermes-engine` pod, RN 0.76.9 |
| **JSI** (headers only) | `<jsi/jsi.h>` `Value`/`Runtime` | the SAME hermes-engine pod's headers |
| **Yoga** | `<yoga/Yoga.h>` C API (`YGNode*`) | `Yoga` pod, RN 0.76.9 |

Android pins `hermes-android 0.76.9` (`host/android/app/src/main/cpp/CMakeLists.txt:5`); iOS
pins the RN release whose iOS `hermes-engine` is that same Hermes. **Move both platforms
together** on any bump.

## Offline vendor layout (fallback)

If you vendor instead of `pod install`, drop the prebuilt artifacts here and point the Podfile's
`:podspec`/`:path` at them (or add them as `vendoredFrameworks` in `project.yml`):

```
Frameworks/
├── hermes.xcframework/          # libhermes for ios-arm64 + ios-arm64_x86_64-simulator
│   └── ...                      # extracted from the hermes-engine pod's prebuilt tarball
├── jsi/                         # the jsi/ headers from the SAME hermes release (do NOT mix
│   └── jsi/jsi.h                # with host/shared/third_party/jsi if versions differ!)
├── Yoga.xcframework/            # OR build from facebook/yoga (Package.swift is the SPM fallback)
└── YogaShim/                    # umbrella header for the SPM fallback (see ../Package.swift)
    └── include/YogaShim.h
```

### Getting the prebuilts on a Mac

```sh
# from host/ios/
npm install react-native@0.76.9        # populates node_modules/react-native (Podfile points here)
# Hermes prebuilt tarball is fetched by the hermes-engine podspec during `pod install`;
# to vendor it, run `pod install` once on a connected Mac and copy the resolved
# Pods/hermes-engine/destroot/Library/Frameworks/universal/hermes.xcframework into Frameworks/.
```

### JSI header source — pick ONE

The repo already vendors a JSI header set at `host/shared/third_party/jsi/jsi/jsi.h`, which
`project.yml`'s `HEADER_SEARCH_PATHS` points at. **It must be the same version as the linked
Hermes.** If the hermes-engine pod ships its own `jsi/` headers, prefer those and drop the
`third_party/jsi` search path to avoid a two-version mix (Risk #1). The contract's §2.3 is
explicit: do NOT mix a vendored `jsi.h` with a differently-versioned Hermes.

## The boot-time ABI canary the xcframework must satisfy (IOS-4 / RNV-2)

A version pin is necessary but not sufficient: a *partial* re-vendor (a `hermes.xcframework`
whose `libhermes` drifts from the `jsi/` headers it was compiled against, a hand-swapped slice, a
stale CI cache) keeps the SAME pod version string yet ships a DIFFERENT ABI. That boots fine in the
Simulator and then corrupts / SIGABRTs on a real device the first time a non-trivial JSI `Value`
crosses the seam (Risk #1). Two gates close this, and the `hermes.xcframework` you drop here must
satisfy BOTH:

1. **Boot-time canary (runtime).** `CanopyHostViewController.mm` reads the LIVE
   `HermesRuntime::getBytecodeVersion()` off the engine it just created and runs
   `canopy::checkHermesAbi` against `kCanopyExpectedHermesBytecodeVersion` (= **96** for
   react-native 0.76.9) BEFORE evaluating any JS. A mismatch is fail-LOUD (the `reportFatal`
   red-box) and boot aborts — a mismatched engine never runs user JS. This is the iOS twin of the
   Android boot site's `enforceHermesAbiGate` (`CanopyHostJni.cpp`). The same number gates the
   `.hbc` bundle (`checkBundleBytecode`, RNV-7).

2. **Headless CI gate.** `scripts/check-abi.sh` re-extracts version 96 from the pinned Android
   `libhermes.so`, asserts it equals the baked C++ pin, asserts both boot sites WIRE the canary
   (so it can't be silently deleted), and RUNS `checkHermesAbi`'s verdict logic on the Linux
   runner. `scripts/check-vendor-pins.sh` ties the iOS Podfile `$RN_VERSION`, the
   `vendor.lock.json` `hermes-engine` + `Yoga` pod-pins, and the baked pin to ONE react-native
   release. A one-sided bump turns CI red.

### Verify a freshly-vendored `hermes.xcframework` SPEAKS bytecode version 96 (on a Mac)

`check-abi.sh` disassembles the `getBytecodeVersion()` leaf out of the Android `.so` (a Linux
runner has no Apple slice). On a Mac, run the SAME leaf-read against the xcframework's device slice
to confirm the iOS Hermes you just vendored matches the canary's pin BEFORE you ship — this is the
Mac-gated half of the gate:

```sh
# from host/ios/, after copying hermes.xcframework into Frameworks/
DYLIB="$(find Frameworks/hermes.xcframework/ios-arm64 -name 'hermes' -o -name 'libhermes*' | head -1)"
# Read the constant the getBytecodeVersion() leaf returns (arm64: movz w0,#imm ; ret).
nm -gU "$DYLIB" | grep getBytecodeVersion          # confirm the symbol is present
otool -tvV "$DYLIB" | \
  awk '/getBytecodeVersion/{f=1} f&&/movz|mov.*w0/{print; exit}'   # the immediate is the version
# The immediate MUST be 0x60 (== 96). If it differs, the xcframework's Hermes is NOT the 0.76.9
# engine the canary pins — re-vendor from the matched react-native release. Do NOT ship it.
```

If you maintain a Mac CI lane, wire this assertion (xcframework leaf == 96) into it so the iOS
binary half is gated exactly as `check-abi.sh` gates the Android `.so` half. Until then the
boot-time canary (gate #1) is the device-side safety net: a wrong xcframework cannot run user JS.

## Dual-platform re-vendor procedure (Hermes/Yoga move TOGETHER)

The JSI/Hermes ABI is matched ONLY if iOS and Android come from the same react-native release. On
any Hermes/RN bump, do BOTH platforms in lockstep:

1. **Android (Linux-doable).** `scripts/fetch-vendor.sh` (curl + unzip + sha256) pulls the new
   `libhermes.so` / `libjsi.so` / `libfbjni.so` + headers from the bumped RN's AARs into
   `host/android/vendor/`; then `scripts/revendor.sh lock` rewrites `host/vendor.lock.json` with
   the new checksums + versions.
2. **iOS (Mac-gated).** On a Mac: `cd host/ios && npm install react-native@<new> && pod install`,
   then copy `Pods/hermes-engine/destroot/Library/Frameworks/universal/hermes.xcframework` and the
   matched `jsi/` headers into `Frameworks/` (see "Offline vendor layout" above). VERIFY the
   xcframework leaf == the new bytecode version (the `otool` recipe above).
3. **Move the pins in lockstep.** Update `$RN_VERSION` in `host/ios/Podfile`,
   `kCanopyExpectedRnVersion` + `kCanopyExpectedHermesBytecodeVersion` in
   `host/shared/cpp/CanopyAbiGate.h`, the `hermes-engine` + `Yoga` pod-pin versions in
   `host/vendor.lock.json` (via `revendor.sh lock`), and the provenance comment in
   `host/android/app/src/main/cpp/CMakeLists.txt`. `scripts/bump-check.sh` prints this exact
   checklist.
4. **Re-run the gates.** `scripts/check-vendor-pins.sh` + `scripts/check-abi.sh` must both go
   green; they FAIL a one-sided bump. The boot-time canary then confirms the LIVE engine on first
   launch.
