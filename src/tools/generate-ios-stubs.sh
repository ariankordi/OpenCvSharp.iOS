#!/usr/bin/env bash
# One-time script: generate src/tools/ios-stubs.txt.
#
# Commit the output to the repo. Re-run only when updating OpenCvSharp/OpenCV version.
#
# Usage (from repo root, AFTER running build-opencvsharp-ios.sh):
#   src/tools/generate-ios-stubs.sh /path/to/libOpenCvSharpExtern.so
#
# The .so should be from the official full-build runtime package (all modules enabled),
# e.g. OpenCvSharp4.runtime.linux-x64 from NuGet.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STUBS_TXT="$ROOT_DIR/src/tools/ios-stubs.txt"

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 /path/to/libOpenCvSharpExtern.so"
    exit 1
fi

FULL_SO="$1"
IOS_EXTERN_A="$ROOT_DIR/ios-build/extern-device/OpenCvSharpExtern/libOpenCvSharpExtern.a"
IOS_OPENCV_LIB_DIR="$ROOT_DIR/ios-build/opencv-device/lib"

if [[ ! -f "$FULL_SO" ]];              then echo "ERROR: $FULL_SO not found"; exit 1; fi
if [[ ! -f "$IOS_EXTERN_A" ]];         then echo "ERROR: iOS extern lib not found — run build-opencvsharp-ios.sh first"; exit 1; fi
if [[ ! -d "$IOS_OPENCV_LIB_DIR" ]];   then echo "ERROR: iOS opencv libs not found — run build-opencvsharp-ios.sh first"; exit 1; fi

echo "Reference .so: $FULL_SO"

# --- Step 1: all C-linkage exports from the full official Linux .so ---
# nm -D = dynamic (exported) symbols only.
# Filter out C++ mangled names (start with _Z on Linux).
full_so_symbols=$(nm -D "$FULL_SO" 2>/dev/null \
    | grep ' T ' \
    | sed 's/.* T //' \
    | grep -v '^_Z' \
    | sort -u)

echo "Full .so C-linkage exports: $(echo "$full_so_symbols" | grep -c . || true)"

# --- Step 2: all symbols already defined in the iOS merged archive ---
# This covers:
#   - libOpenCvSharpExtern.a  (our minimal core/imgproc/imgcodecs wrappers)
#   - libopencv_*.a           (OpenCV static libs)
#   - liblibpng.a, liblibjpeg-turbo.a, libwebp.a, etc.  (3rdparty bundled by OPENCV_FORCE_3RDPARTY_BUILD)
# Subtracting all of these avoids generating stubs for symbols that are already defined,
# which would cause duplicate symbol errors at link time.
ios_defined_symbols=$(
    {
        nm "$IOS_EXTERN_A" 2>/dev/null
        find "$IOS_OPENCV_LIB_DIR" -name "*.a" -exec nm {} \; 2>/dev/null
    } \
    | grep ' T _' \
    | sed 's/.* T _//' \
    | grep -v '^_Z' \
    | sort -u
)

echo "iOS defined symbols:        $(echo "$ios_defined_symbols" | grep -c . || true)"

# --- Step 3: C# source scan for symbols absent from the Linux .so ---
# Some modules (e.g. text, wechat_qrcode) may not be built in the reference .so.
# Any P/Invoke entry point in the C# source that is not in the .so and not already
# defined in the iOS archive needs a stub.
cs_dir="$ROOT_DIR/src/OpenCvSharp/Internal/PInvoke/NativeMethods"
cs_symbols=$(
    {
        # Implicit: ExactSpelling=true, method name = entry point
        find "$cs_dir" -name "*.cs" -exec grep -h 'public static extern' {} \; \
            | grep -oP '(?<=extern )[A-Za-z0-9_<>?]+\s+\K[a-z][a-zA-Z0-9_]+(?=\()' || true
        # Explicit EntryPoint override
        find "$cs_dir" -name "*.cs" -exec grep -h 'EntryPoint' {} \; \
            | grep -oP '(?<=EntryPoint = ")[^"]+' || true
    } | sort -u
)

echo "C# P/Invoke declarations:   $(echo "$cs_symbols" | grep -c . || true)"

# --- Final: stubs = (full .so symbols ∪ C# symbols) − iOS defined symbols ---
# Union of step 1 + step 3, then subtract step 2.
stub_symbols=$(comm -23 \
    <({ echo "$full_so_symbols"; echo "$cs_symbols"; } | sort -u) \
    <(echo "$ios_defined_symbols"))

echo "Stubs to generate:          $(echo "$stub_symbols" | grep -c . || true)"

echo "$stub_symbols" > "$STUBS_TXT"

echo ""
echo "Written: $STUBS_TXT"
echo "Commit this file to the repo."
echo "Re-run only when updating the OpenCvSharp/OpenCV version."
