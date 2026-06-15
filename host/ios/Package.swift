// swift-tools-version:5.9
// Package.swift — OPTIONAL Yoga-via-SPM fallback (Author A, SHARED CONTRACT §1/§2.3).
//
// CocoaPods (Podfile) is the PRIMARY dependency path: it pulls Hermes + JSI + Yoga from one
// ABI-matched React Native release (Risk #1). This Package.swift exists ONLY as a fallback if
// the Yoga *pod* proves troublesome on a given Mac toolchain — Yoga is a clean, dependency-free
// C/C++ library that SPM can vend on its own. Hermes is NOT consumed via SPM (hermes-engine is
// not first-class as an SPM product); it always comes from the pod or a vendored xcframework.
//
// This package is NOT wired into project.yml by default. To use it, add a `packages:` /
// `dependencies:` entry to the CanopyHostCore target in project.yml pointing here, and remove
// the `pod 'Yoga'` line from the Podfile. Do this only if the Yoga pod blocks you.
//
// NOTE: facebook/yoga's own Package.swift tracks `main`; pin to the tag whose Yoga sources match
// the React Native 0.76.9 release (so flexbox defaults match what native.js assumes — Risk #2).

import PackageDescription

let package = Package(
    name: "CanopyHostYoga",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(name: "CanopyHostYoga", targets: ["YogaShim"])
    ],
    dependencies: [
        // Pin to the Yoga tag matching RN 0.76.9 (Risk #2). Replace the revision with the exact
        // commit/tag once the Mac build confirms the flexbox-default parity.
        .package(url: "https://github.com/facebook/yoga.git", exact: "3.1.0")
    ],
    targets: [
        // A thin shim target so the host can `import CanopyHostYoga` (or just link Yoga's C API
        // directly). Yoga's public headers (<yoga/Yoga.h>) are what CanopyHostFabric.mm uses.
        .target(
            name: "YogaShim",
            dependencies: [
                .product(name: "yoga", package: "yoga")
            ],
            path: "Frameworks/YogaShim",
            cSettings: [
                .headerSearchPath("../../../shared/cpp"),
                .headerSearchPath("../../../shared/third_party/jsi")
            ]
        )
    ],
    cxxLanguageStandard: .cxx17
)
