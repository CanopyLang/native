// SwiftLinkShim.swift — intentionally (almost) empty.
//
// CanopyHostCoreTests is an ObjC++ (.mm) test bundle that links libCanopyHostCore.a, which contains
// Swift objects (CanopyBillingStoreKit2, the StoreKit 2 driver). Those Swift objects force-load the
// Swift runtime + back-deployment compatibility libraries (e.g. libswiftCompatibility56). A target
// with NO Swift sources of its own does not invoke the Swift linker, so the link fails with:
//
//   Undefined symbol: __swift_FORCE_LOAD_$_swiftCompatibility56
//       referenced from __swift_FORCE_LOAD_$_swiftCompatibility56_$_CanopyHostCore (CanopyBillingStoreKit2.o)
//
// The mere presence of one .swift file makes this a Swift-linking target, so Xcode links the Swift
// runtime/compatibility libs and the force-load symbols resolve. The app target builds fine on its
// own because it already has Swift sources. No test code lives here.
import Foundation
