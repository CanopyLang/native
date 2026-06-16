#!/usr/bin/env bash
# check-portable-cpp.sh — compile the PORTABLE shared C++ (the half the iOS host reuses verbatim)
# in the iOS (non-__ANDROID__) configuration, ON LINUX. This is the slice of the iOS host that
# CAN be compiled without a Mac: the JSI Fabric installer, the module registry, the blob registry,
# the billing stream half, image pixel ops. The Objective-C++/UIKit host layer (Render/*.mm,
# Boot/*.mm, Modules/*.mm) needs Xcode (Apple frameworks aren't available off macOS).
# Run:  ./check-portable-cpp.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../shared" && pwd)"
INC="-I $ROOT/cpp -I $ROOT/third_party/jsi"
CXX="${CXX:-g++}"
fail=0
for f in CanopyFabric.cpp CanopyModules.cpp CanopyBlobs.cpp EchoModule.cpp CanopyImage.cpp BillingModule.cpp; do
  if $CXX -std=c++17 -fsyntax-only $INC "$ROOT/cpp/$f" 2>/tmp/ios-cc-$f.log; then
    echo "  OK  $f"
  else
    echo "  ERR $f"; grep -vE "^In file|warning:" /tmp/ios-cc-$f.log | head -6; fail=1
  fi
done

# Header-only portable headers (the iOS host reuses them verbatim). L-I4: CanopyBeforeAfter.h carries
# the shared before/after wipe math (clamp/split/drag/snap/cover/payload) that BOTH hosts delegate to;
# syntax-check it in the iOS (non-__ANDROID__) config so a non-portable construct can't slip in.
for h in CanopyBeforeAfter.h; do
  if $CXX -std=c++17 -fsyntax-only $INC -x c++ "$ROOT/cpp/$h" 2>/tmp/ios-cc-$h.log; then
    echo "  OK  $h (header-only)"
  else
    echo "  ERR $h"; grep -vE "^In file|warning:" /tmp/ios-cc-$h.log | head -6; fail=1
  fi
done
[ $fail -eq 0 ] && echo "iOS-portable C++ compiles (non-Android config)" || echo "FAILURES above"
exit $fail
