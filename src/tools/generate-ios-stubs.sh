#!/usr/bin/env bash
# One-time script: generate src/tools/ios-stubs.txt from the official full-build .so.
#
# Run this when updating the OpenCvSharp/OpenCV version, or when adding new modules.
# The output file is committed to the repo and read by build-opencvsharp-ios.sh at
# build time — no re-running needed for normal builds.
#
# Usage (from repo root):
#   src/tools/generate-ios-stubs.sh /path/to/libOpenCvSharpExtern.so
#
# The .so should be from the official full-build runtime package (all modules),
# e.g. OpenCvSharp4.runtime.linux-x64 from NuGet.
# The minimal iOS extern lib must already be built (ios-build/extern-device/).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STUBS_TXT="$ROOT_DIR/src/tools/ios-stubs.txt"

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 /path/to/libOpenCvSharpExtern.so"
    exit 1
fi

FULL_SO="$1"
MINIMAL_A="$ROOT_DIR/ios-build/extern-device/OpenCvSharpExtern/libOpenCvSharpExtern.a"

if [[ ! -f "$FULL_SO" ]]; then
    echo "ERROR: $FULL_SO not found"
    exit 1
fi

if [[ ! -f "$MINIMAL_A" ]]; then
    echo "ERROR: minimal iOS extern lib not found at $MINIMAL_A"
    echo "Run src/tools/build-opencvsharp-ios.sh first to build the native libs."
    exit 1
fi

echo "Full .so:     $FULL_SO"
echo "Minimal .a:   $MINIMAL_A"

# All C-linkage exported symbols from the full official build.
# nm -D gives only dynamic exports (what consumers can actually call).
# Among those, C++ mangled names start with _Z — filter them out to get
# only the plain C-linkage OpenCvSharp bridge functions.
full_symbols=$(nm -D "$FULL_SO" 2>/dev/null \
    | grep ' T ' \
    | sed 's/.* T //' \
    | grep -v '^_Z' \
    | sort -u)

# Symbols already implemented in our minimal iOS lib.
# macOS/iOS .a format: static archive, symbols have leading underscore — strip it.
# C++ mangled names have __Z prefix on Apple platforms — filter those too.
real_symbols=$(nm "$MINIMAL_A" 2>/dev/null \
    | grep ' T _' \
    | sed 's/.* T _//' \
    | grep -v '^_Z' \
    | sort -u)

# Stubs = full set minus what we already provide.
stub_symbols=$(comm -23 \
    <(echo "$full_symbols") \
    <(echo "$real_symbols"))

echo "$stub_symbols" > "$STUBS_TXT"

echo ""
echo "Full symbols:    $(echo "$full_symbols"  | grep -c . || true)"
echo "Real (iOS) symbols: $(echo "$real_symbols" | grep -c . || true)"
echo "Stubs written:   $(echo "$stub_symbols"  | grep -c . || true)  →  $STUBS_TXT"
echo ""
echo "Commit src/tools/ios-stubs.txt to the repo."
echo "Re-run this script only when the OpenCvSharp/OpenCV version changes."
