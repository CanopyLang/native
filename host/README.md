# canopy/native — React Native host shell

The native shell that boots a Hermes runtime, installs the `__fabric_*` JSI surface
`external/native.js` drives, loads `canopy.bundle.js`, and runs the program against a
native root surface. **No React, no WebView.**

> These are **integration templates**. They compile inside a real iOS/Android app
> target (UIKit/Hermes/Yoga on iOS; NDK/Hermes/Yoga on Android) and cannot be built on a
> machine without those SDKs. Each marked `TODO` is a seam you wire to your app's run
> loop / event targets.

## Layout

```
host/
├── shared/cpp/
│   ├── CanopyFabric.h     # the CanopyHost interface + JSI entry points
│   └── CanopyFabric.cpp   # PORTABLE JSI installer: __fabric_* ⇄ CanopyHost (no platform headers)
├── ios/CanopyHost/
│   ├── CanopyHostFabric.mm        # CanopyHost impl: UIView + Yoga
│   └── CanopyHostViewController.mm # boot flow: make Hermes runtime → install → eval bundle → boot
└── android/app/src/main/
    ├── java/com/canopyhost/CanopyHost.java      # CanopyHost impl: android.view.View + Yoga
    ├── java/com/canopyhost/CanopyHostJni.java   # native method declarations
    ├── java/com/canopyhost/MainActivity.java    # boot flow
    └── jni/CanopyHostJni.cpp                     # JNI glue: C++ installer ⇄ Java CanopyHost
```

## Boot flow (identical shape on both platforms)

1. Create a Hermes runtime (`makeHermesRuntime`).
2. `installCanopyFabric(runtime, host)` — installs `__fabric_createView/updateProps/
   insertChild/removeChild/setRoot/setEvents/requestFrame` on the runtime, backed by a
   `CanopyHost`.
3. Evaluate `canopy.bundle.js` (defines `globalThis.Elm` + `__canopy_boot`).
4. `canopyBoot(runtime, rootTag, "{}")` → runs the program; it self-installs its event
   dispatcher and drives the whole tree through `__fabric_*`.
5. On a gesture, the host calls `canopyEmitEvent(runtime, handle, "press", "{}")` →
   `__canopy_dispatchEvent` → decoded → `sendToApp` → `update`.

## Two host strategies

| | **Direct views + Yoga** (shipped templates) | **RN Fabric mount** |
|---|---|---|
| Binds to | UIKit / android.view + Yoga's public C API | RN's `MountingManager` / component-view registry |
| Risk | Low — all stable public surfaces | Higher — New-Arch C++ surface |
| You get | real native views + flexbox layout | + RN's entire component & native-module catalog |
| When | first light, full control | inherit the RN ecosystem |

Both implement the **same `CanopyHost` interface** — switching is a host-side change
only; the JS and the JSI surface are byte-identical (the survival rule, architecture.md §5).

## Integrating into an app

1. `canopy-native build <app>` → `build/canopy.bundle.js` (+ `build/generated/` Fabric
   mapping glue — the C++ header feeds the JSI layer's float-coercion set).
2. **iOS:** add `shared/cpp/*` + `ios/CanopyHost/*` to the target; link Hermes + Yoga;
   make `CanopyHostViewController` the root; bundle `canopy.bundle.js` as a resource.
3. **Android:** add `CanopyHost*.java` + `MainActivity.java`; build the `canopyhost` NDK
   module from `jni/CanopyHostJni.cpp` + `shared/cpp/*`; package `canopy.bundle.js` under
   `app/src/main/assets/`.
4. Build with Xcode / Gradle as usual; inspect the tree in the Xcode View Hierarchy or
   Android Layout Inspector — it is real native views.

## Status
The JSI installer (`CanopyFabric.*`) is the portable, inspection-verifiable core; the
per-platform mounts are faithful scaffolds against the real UIKit/Yoga and android.view/
Yoga APIs. Standing up a device build (Android first) is the next roadmap item — it needs
the Android SDK/NDK that the development machine here does not have.
