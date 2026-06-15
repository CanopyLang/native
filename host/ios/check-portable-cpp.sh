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
[ $fail -eq 0 ] && echo "iOS-portable C++ compiles (non-Android config)" || echo "FAILURES above"
exit $fail
