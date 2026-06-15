# CMakeLists.txt — builds the PORTABLE Canopy host C++ (the __fabric_* render surface +
# the __canopy_* native-module ABI) as a static library against the JSI headers.
#
# This is the platform-neutral half of the host: it compiles identically with the host
# toolchain (a type-check on a dev box) and with the Android NDK (the real arm64 build),
# because it includes ONLY <jsi/jsi.h> — no UIKit, no android.view, no React component
# headers (the survival rule). The per-platform mount/runtime wiring (CanopyHostFabric.mm,
# CanopyHostJni.cpp, …) links against this lib inside a real app target.
#
# Vendored JSI headers live in third_party/jsi (fetched from facebook/react-native
# ReactCommon/jsi). On a real device build the NDK provides its own JSI via prefab; point
# CANOPY_JSI_INCLUDE_DIR at that instead.
#
#   Host type-check:
#     cmake -S . -B build-host && cmake --build build-host
#   Android NDK (arm64):
#     cmake -S . -B build-android \
#       -DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK/build/cmake/android.toolchain.cmake \
#       -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-24
#     cmake --build build-android

cmake_minimum_required(VERSION 3.18)
project(canopyhost_shared CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(CANOPY_JSI_INCLUDE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/third_party/jsi"
    CACHE PATH "Directory containing <jsi/jsi.h> (vendored, or the NDK's JSI prefab)")

add_library(canopyhost_shared STATIC
  cpp/CanopyFabric.cpp     # __fabric_* render surface
  cpp/CanopyModules.cpp    # __canopy_* native-module dispatcher (C1)
  cpp/CanopyBlobs.cpp      # opaque binary-handle registry (C1)
  cpp/EchoModule.cpp       # the C1 reference capability
)

target_include_directories(canopyhost_shared PUBLIC
  "${CMAKE_CURRENT_SOURCE_DIR}/cpp"
  "${CANOPY_JSI_INCLUDE_DIR}"
)

target_compile_options(canopyhost_shared PRIVATE -Wall -Wextra)
