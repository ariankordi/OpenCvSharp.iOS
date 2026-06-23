#!/usr/bin/env bash
# Build OpenCV (static, minimal) + OpenCvSharpExtern (static) for iOS device and simulator,
# then assemble an xcframework covering both arm64 slices.
#
# Prerequisites: Xcode, cmake >= 3.15.
#
# Usage (run from the repo root):
#   src/tools/build-opencvsharp-ios.sh
#
# Outputs:
#   ios-build/OpenCvSharpExtern.xcframework   — ready to drop into the NuGet package

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="$ROOT_DIR/ios-build"
OPENCV_SRC="$ROOT_DIR/opencv"

DEVICE_OPENCV_PREFIX="$BUILD_DIR/opencv-device"
SIM_OPENCV_PREFIX="$BUILD_DIR/opencv-simulator"
DEVICE_EXTERN_DIR="$BUILD_DIR/extern-device"
SIM_EXTERN_DIR="$BUILD_DIR/extern-simulator"
XCFRAMEWORK_OUT="$BUILD_DIR/OpenCvSharpExtern.xcframework"

export IPHONEOS_DEPLOYMENT_TARGET="13.0"

# Minimal module set matching the mini-runtime proven recipe (core + imgproc + imgcodecs).
OPENCV_CMAKE_ARGS=(
    -DCMAKE_BUILD_TYPE=Release
    -DBUILD_LIST=core,imgproc,imgcodecs
    -DBUILD_SHARED_LIBS=OFF
    -DOPENCV_FORCE_3RDPARTY_BUILD=ON
    -DBUILD_EXAMPLES=OFF
    -DBUILD_opencv_apps=OFF
    -DBUILD_DOCS=OFF
    -DBUILD_PERF_TESTS=OFF
    -DBUILD_TESTS=OFF
    -DBUILD_JAVA=OFF
    -DWITH_PROTOBUF=OFF
    -DWITH_FFMPEG=OFF
    -DWITH_GSTREAMER=OFF
    -DWITH_V4L=OFF
    -DWITH_1394=OFF
    -DWITH_GTK=OFF
    -DWITH_OPENEXR=OFF
    -DWITH_QUIRC=OFF
    -DOPENCV_ENABLE_NONFREE=OFF
    -DIPHONEOS_DEPLOYMENT_TARGET="$IPHONEOS_DEPLOYMENT_TARGET"
    # KleidiCV is an ARM-only 3rdparty HAL new in OpenCV 4.13. It passes -mcpu=armv8-a
    # explicitly, which breaks when Xcode also tries to compile a fat simulator binary
    # (x86_64 + arm64). Disabling it keeps the build ARM-only without losing functionality.
    -DWITH_KLEIDICV=OFF
    -DWITH_ADE=OFF
)

# All non-core modules disabled so the extern source compiles cleanly.
EXTERN_CMAKE_ARGS=(
    -DCMAKE_BUILD_TYPE=Release
    -DNO_CONTRIB=ON
    -DNO_STITCHING=ON
    -DNO_CALIB3D=ON
    -DNO_VIDEO=ON
    -DNO_FEATURES2D=ON
    -DNO_FLANN=ON
    -DNO_DNN=ON
    -DNO_ML=ON
    -DNO_OBJDETECT=ON
    -DNO_PHOTO=ON
    -DNO_BARCODE=ON
    -DNO_VIDEOIO=ON
    -DNO_HIGHGUI=ON
    -DNO_INSTALL_TO_TEST=ON
)

build_opencv() {
    local slice="$1"     # "device" or "simulator"
    local toolchain="$2" # path to iOS toolchain file
    local prefix="$3"

    echo "=== Build OpenCV [$slice] ==="
    local build_dir="$BUILD_DIR/opencv-build-$slice"
    #rm -rf "$build_dir"
    mkdir -p "$build_dir"

    # The iPhoneSimulator SDK (arm64-apple-ios-simulator) does not define __ARM_FP, so
    # libjpeg-turbo's SIMD cmake detection fails ambiguously and ends up forcing
    # NEON_INTRINSICS=ON anyway, which then breaks at compile time.  ENABLE_LIBJPEG_TURBO_SIMD
    # is the OpenCV-level gate that skips the entire SIMD subdirectory cleanly.
    local extra_cmake_args=()
    if [[ "$slice" == "simulator" ]]; then
        extra_cmake_args+=(-DENABLE_LIBJPEG_TURBO_SIMD=OFF)
    fi

    # Ninja avoids the per-test xcodebuild overhead that makes try_compile checks very slow.
    # STATIC_LIBRARY mode skips the link/run step so compile-only checks work for iOS cross-builds.
    cmake -S "$OPENCV_SRC" -B "$build_dir" \
        -G Ninja \
        "${OPENCV_CMAKE_ARGS[@]}" \
        ${extra_cmake_args[@]+"${extra_cmake_args[@]}"} \
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
        -DCMAKE_TOOLCHAIN_FILE="$toolchain" \
        -DIOS_ARCH=arm64 \
        -DCMAKE_INSTALL_PREFIX="$prefix"

    cmake --build "$build_dir" --config Release --parallel
    cmake --install "$build_dir" --config Release
}

build_extern() {
    local slice="$1"
    local opencv_prefix="$2"
    local out_dir="$3"

    echo "=== Build OpenCvSharpExtern [$slice] ==="
    local toolchain
    if [[ "$slice" == "device" ]]; then
        toolchain="$OPENCV_SRC/platforms/ios/cmake/Toolchains/Toolchain-iPhoneOS_Xcode.cmake"
    else
        toolchain="$OPENCV_SRC/platforms/ios/cmake/Toolchains/Toolchain-iPhoneSimulator_Xcode.cmake"
    fi

    #rm -rf "$out_dir"
    mkdir -p "$out_dir"

    cmake -S "$ROOT_DIR/src" -B "$out_dir" \
        -G Ninja \
        "${EXTERN_CMAKE_ARGS[@]}" \
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
        -DCMAKE_TOOLCHAIN_FILE="$toolchain" \
        -DIOS_ARCH=arm64 \
        -DIPHONEOS_DEPLOYMENT_TARGET="$IPHONEOS_DEPLOYMENT_TARGET" \
        -DOpenCV_DIR="$opencv_prefix/lib/cmake/opencv4"

    cmake --build "$out_dir" --config Release --parallel
}

merge_static() {
    local slice="$1"
    local opencv_prefix="$2"
    local extern_dir="$3"
    local merged_out="$4"

    echo "=== Merge static archives [$slice] ==="
    local extern_a="$extern_dir/OpenCvSharpExtern/libOpenCvSharpExtern.a"
    local opencv_libs=()
    while IFS= read -r -d '' f; do
        opencv_libs+=("$f")
    done < <(find "$opencv_prefix/lib" -name "*.a" -print0)

    libtool -static -o "$merged_out" "$extern_a" "${opencv_libs[@]}"
    echo "Merged archive: $(du -sh "$merged_out" | cut -f1)"
}

assemble_xcframework() {
    local device_a="$1"
    local sim_a="$2"
    local out="$3"

    echo "=== Assemble xcframework ==="
    # lipo cannot merge two arm64 slices (device vs simulator differ only by SDK, not arch).
    # xcodebuild -create-xcframework disambiguates them via Info.plist metadata.
    #rm -rf "$out"
    xcodebuild -create-xcframework \
        -library "$device_a" \
        -library "$sim_a" \
        -output "$out"
    echo "xcframework: $out"
}

# --- Main ---

DEVICE_TOOLCHAIN="$OPENCV_SRC/platforms/ios/cmake/Toolchains/Toolchain-iPhoneOS_Xcode.cmake"
SIM_TOOLCHAIN="$OPENCV_SRC/platforms/ios/cmake/Toolchains/Toolchain-iPhoneSimulator_Xcode.cmake"

if [[ ! -f "$DEVICE_TOOLCHAIN" ]]; then
    echo "ERROR: iOS toolchains not found at $OPENCV_SRC/platforms/ios/cmake/Toolchains/"
    echo "Make sure the opencv submodule is checked out (git submodule update --init opencv)"
    exit 1
fi

mkdir -p "$BUILD_DIR"

build_opencv "device"    "$DEVICE_TOOLCHAIN" "$DEVICE_OPENCV_PREFIX"
build_opencv "simulator" "$SIM_TOOLCHAIN"    "$SIM_OPENCV_PREFIX"

build_extern "device"    "$DEVICE_OPENCV_PREFIX" "$DEVICE_EXTERN_DIR"
build_extern "simulator" "$SIM_OPENCV_PREFIX"    "$SIM_EXTERN_DIR"

DEVICE_MERGED="$BUILD_DIR/merged-device.a"
SIM_MERGED="$BUILD_DIR/merged-simulator.a"
merge_static "device"    "$DEVICE_OPENCV_PREFIX" "$DEVICE_EXTERN_DIR" "$DEVICE_MERGED"
merge_static "simulator" "$SIM_OPENCV_PREFIX"    "$SIM_EXTERN_DIR"    "$SIM_MERGED"

assemble_xcframework "$DEVICE_MERGED" "$SIM_MERGED" "$XCFRAMEWORK_OUT"

echo ""
echo "=== Done ==="
echo "xcframework output: $XCFRAMEWORK_OUT"
echo "Drop this into the NuGet package directory before packing."
