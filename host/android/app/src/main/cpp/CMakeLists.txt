# CMakeLists.txt — builds libcanopyhost.so for the Echo app.
#
# Links the portable Canopy host (host/shared/cpp/*) + the Android JNI glue against the
# version-matched prebuilt Hermes/JSI/fbjni libraries vendored under host/android/vendor
# (extracted from the 0.76.9 hermes-android / react-android / fbjni AARs). No React Native.

cmake_minimum_required(VERSION 3.22)
project(canopyhost CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# host/android  (this file is at host/android/app/src/main/cpp)
get_filename_component(ANDROID_HOST_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../.." ABSOLUTE)
# host/shared/cpp
get_filename_component(SHARED_CPP "${ANDROID_HOST_DIR}/../shared/cpp" ABSOLUTE)
set(VENDOR "${ANDROID_HOST_DIR}/vendor")

# Version-matched prebuilt .so as IMPORTED targets (per-ABI).
add_library(hermes SHARED IMPORTED)
set_target_properties(hermes PROPERTIES IMPORTED_LOCATION "${VENDOR}/lib/${ANDROID_ABI}/libhermes.so")
add_library(jsi SHARED IMPORTED)
set_target_properties(jsi PROPERTIES IMPORTED_LOCATION "${VENDOR}/lib/${ANDROID_ABI}/libjsi.so")
add_library(fbjni SHARED IMPORTED)
set_target_properties(fbjni PROPERTIES IMPORTED_LOCATION "${VENDOR}/lib/${ANDROID_ABI}/libfbjni.so")

# ONNX Runtime (canopy/inference) — vendored prebuilt, statically links libc++ (no conflict).
add_library(onnxruntime SHARED IMPORTED)
set_target_properties(onnxruntime PROPERTIES IMPORTED_LOCATION "${VENDOR}/onnxruntime/lib/${ANDROID_ABI}/libonnxruntime.so")

add_library(canopyhost SHARED
    ${CMAKE_CURRENT_SOURCE_DIR}/../jni/CanopyHostJni.cpp
    ${SHARED_CPP}/CanopyHermes.cpp        # RNV-4: the ONE Hermes runtime factory (canopy::makeRuntime)
    ${SHARED_CPP}/CanopyFabric.cpp
    ${SHARED_CPP}/CanopyModules.cpp
    ${SHARED_CPP}/CanopyBlobs.cpp
    ${SHARED_CPP}/EchoModule.cpp
    ${SHARED_CPP}/CanopyJni.cpp           # Foundation: JniModule + blob bridge + globalBlobRegistry + resolveModule
    ${SHARED_CPP}/CanopyImage.cpp         # canopy/image composite helpers
    ${SHARED_CPP}/RestoreEngineModule.cpp # canopy/inference: ORT NativeModule
    ${SHARED_CPP}/BillingModule.cpp       # canopy/billing: streaming entitlement NativeModule
    ${SHARED_CPP}/StreamingJniModule.cpp  # canopy/navigation: Lifecycle + AppShell stream wrapper
)

target_include_directories(canopyhost PRIVATE
    ${SHARED_CPP}
    ${VENDOR}/hermes-include
    ${VENDOR}/jsi-include
    ${VENDOR}/onnxruntime/include
)

find_library(log-lib log)
find_library(jnigraphics-lib jnigraphics)   # AndroidBitmap_* for the blob↔Bitmap bridge
target_link_libraries(canopyhost hermes jsi fbjni onnxruntime ${log-lib} ${jnigraphics-lib})
