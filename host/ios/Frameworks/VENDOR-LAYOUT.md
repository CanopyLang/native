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
