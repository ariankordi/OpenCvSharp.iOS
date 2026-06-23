#!/usr/bin/env bash
# Build OpenCV (static, minimal) + OpenCvSharpExtern (static) for iOS device and simulator,
# compile abort-stubs for all non-minimal symbols so the iOS static linker is satisfied,
# then assemble an xcframework covering both arm64 slices.
#
# Prerequisites: Xcode, cmake >= 3.15, Ninja.
#
# Usage (run from the repo root):
#   src/tools/build-opencvsharp-ios.sh
#
# The stub symbol list is read from src/tools/ios-stubs.txt (committed to the repo).
# To regenerate it after an OpenCV/OpenCvSharp version update:
#   src/tools/generate-ios-stubs.sh /path/to/libOpenCvSharpExtern.so
#
# Outputs:
#   ios-build/OpenCvSharpExtern.xcframework   — ready for dotnet pack

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

# Generate a C source file with abort-stubs for every P/Invoke entry point declared in the
# managed OpenCvSharp.dll that is NOT already provided by the real extern lib.
#
# Why: iOS static linking requires every referenced symbol to physically exist at link time.
# The managed DLL declares [DllImport] for all OpenCV modules, but we only build a minimal
# native lib (core/imgproc/imgcodecs). Calling a stub crashes immediately with a clear
# message — better than a mysterious link error or silent misbehavior.
generate_stubs() {
    local extern_a="$1"   # real static lib to diff against
    local out_c="$2"      # output .c file

    echo "=== Generate abort-stubs ==="

    local managed_dll="$ROOT_DIR/src/OpenCvSharp/bin/Release/net9.0-ios/OpenCvSharp.dll"
    if [[ ! -f "$managed_dll" ]]; then
        echo "ERROR: managed dll not found at $managed_dll"
        echo "Run: dotnet build src/OpenCvSharp/OpenCvSharp.csproj -f net9.0-ios -c Release"
        exit 1
    fi

    # Extract C-linkage (non-mangled) symbols already defined in the real lib.
    local real_symbols
    real_symbols=$(nm "$extern_a" 2>/dev/null \
        | grep ' T _' \
        | grep -v '__Z' \
        | sed 's/.* T _//' \
        | sort -u)

    # Extract P/Invoke entry-point names from ALL C# source files under NativeMethods/
    # (files are organized in subdirectories: calib3d/, core/, dnn/, etc.).
    # Strategy: grep for static extern declarations; the method name IS the native entry point
    # (ExactSpelling = true on all DllImport calls, except a few overloads that use
    # explicit EntryPoint — capture those separately).
    #
    # Pattern 1: "public static extern <ReturnType> <MethodName>(" — method name = entry point.
    # Pattern 2: EntryPoint = "name" — explicit override.
    local cs_dir="$ROOT_DIR/src/OpenCvSharp/Internal/PInvoke/NativeMethods"
    local all_pinvokes
    all_pinvokes=$(
        {
            # Implicit: method name is the entry point (use find to cover all subdirectories)
            find "$cs_dir" -name "*.cs" -exec grep -h 'public static extern' {} \; \
                | grep -oP '(?<=extern )[A-Za-z0-9_<>?]+\s+\K[a-z][a-zA-Z0-9_]+(?=\()' || true
            # Explicit EntryPoint = "name"
            find "$cs_dir" -name "*.cs" -exec grep -h 'EntryPoint' {} \; \
                | grep -oP '(?<=EntryPoint = ")[^"]+' || true
        } | sort -u
    )

    # Compute stubs = all P/Invoke names minus what the real lib already provides.
    local stub_symbols
    stub_symbols=$(comm -23 \
        <(echo "$all_pinvokes" | sort -u) \
        <(echo "$real_symbols" | sort -u))

    local stub_count
    stub_count=$(echo "$stub_symbols" | grep -c . || true)
    echo "Real symbols: $(echo "$real_symbols" | grep -c . || true)"
    echo "P/Invoke declarations: $(echo "$all_pinvokes" | grep -c . || true)"
    echo "Stubs to generate: $stub_count"

    # Emit the C stub file.
    # Each stub calls abort() with a message so callers get an immediate, clear crash rather
    # than silent wrong behavior. __attribute__((cold)) keeps them out of instruction caches.
    cat > "$out_c" <<'HEADER'
/* Auto-generated abort-stubs for OpenCvSharp iOS minimal build.
 * These satisfy the static linker for P/Invoke entry points that are declared in the
 * managed OpenCvSharp.dll but not implemented in the minimal native lib (core/imgproc/imgcodecs).
 * Calling any of these at runtime will abort with a descriptive message. */
#include <stdio.h>
#include <stdlib.h>

HEADER

    while IFS= read -r sym; do
        [[ -z "$sym" ]] && continue
        printf '__attribute__((cold)) void %s() {\n' "$sym" >> "$out_c"
        printf '    fprintf(stderr, "OpenCvSharp iOS: %s is not available in the minimal build (core/imgproc/imgcodecs only).\\n");\n' "$sym" >> "$out_c"
        printf '    abort();\n}\n\n' >> "$out_c"
    done <<< "$stub_symbols"

    echo "Generated: $out_c ($stub_count stubs)"
}

compile_stubs() {
    local slice="$1"   # "device" or "simulator"
    local in_c="$2"
    local out_o="$3"

    echo "=== Compile stubs [$slice] ==="
    local sdk target
    if [[ "$slice" == "device" ]]; then
        sdk=$(xcrun --sdk iphoneos --show-sdk-path)
        target="arm64-apple-ios${IPHONEOS_DEPLOYMENT_TARGET}"
    else
        sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
        target="arm64-apple-ios${IPHONEOS_DEPLOYMENT_TARGET}-simulator"
    fi

    xcrun clang \
        -target "$target" \
        -isysroot "$sdk" \
        -O0 -c "$in_c" -o "$out_o"
}

merge_static() {
    local slice="$1"
    local opencv_prefix="$2"
    local extern_dir="$3"
    local stubs_o="$4"
    local merged_out="$5"

    echo "=== Merge static archives [$slice] ==="
    local extern_a="$extern_dir/OpenCvSharpExtern/libOpenCvSharpExtern.a"
    local opencv_libs=()
    while IFS= read -r -d '' f; do
        opencv_libs+=("$f")
    done < <(find "$opencv_prefix/lib" -name "*.a" -print0)

    libtool -static -o "$merged_out" "$extern_a" "${opencv_libs[@]}" "$stubs_o"
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

# Generate stubs once (same managed DLL, same entry point list for both slices).
STUBS_C="$BUILD_DIR/opencvsharp_stubs.c"
generate_stubs "$DEVICE_EXTERN_DIR/OpenCvSharpExtern/libOpenCvSharpExtern.a" "$STUBS_C"

DEVICE_STUBS_O="$BUILD_DIR/stubs-device.o"
SIM_STUBS_O="$BUILD_DIR/stubs-simulator.o"
compile_stubs "device"    "$STUBS_C" "$DEVICE_STUBS_O"
compile_stubs "simulator" "$STUBS_C" "$SIM_STUBS_O"

DEVICE_MERGED="$BUILD_DIR/merged-device.a"
SIM_MERGED="$BUILD_DIR/merged-simulator.a"
merge_static "device"    "$DEVICE_OPENCV_PREFIX" "$DEVICE_EXTERN_DIR" "$DEVICE_STUBS_O" "$DEVICE_MERGED"
merge_static "simulator" "$SIM_OPENCV_PREFIX"    "$SIM_EXTERN_DIR"    "$SIM_STUBS_O"    "$SIM_MERGED"

assemble_xcframework "$DEVICE_MERGED" "$SIM_MERGED" "$XCFRAMEWORK_OUT"

echo ""
echo "=== Done ==="
echo "xcframework output: $XCFRAMEWORK_OUT"
echo "Next: dotnet build src/OpenCvSharp/OpenCvSharp.csproj -f net9.0-ios -c Release"
echo "      mono ios-build/nuget.exe pack nuget/ios/OpenCvSharp4.runtime.ios.nuspec -OutputDirectory ios-build/nupkg"
