#!/bin/bash
# Test fixture only. Never install this DSO in the FFmpeg release prefix.
# Run inside the project's FreeBSD cross-toolchain container.
set -euo pipefail
: "${CC:?FreeBSD target C compiler is required}"
: "${CXX:?FreeBSD target C++ compiler is required}"
: "${CROSS_PREFIX:?FreeBSD cross-toolchain prefix is required}"
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
out=/tmp/real-vulkan-loader
mkdir -p "$out"

test "$(grep '#define VK_HEADER_VERSION ' /build/vulkan-headers/include/vulkan/vulkan_core.h | awk '{print $3}')" = 353
cmake -S /build/vulkan-headers -B /tmp/loader-headers-build \
    -DCMAKE_SYSTEM_NAME=FreeBSD -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_INSTALL_PREFIX=/tmp/loader-headers \
    -DVULKAN_HEADERS_ENABLE_TESTS=OFF -DVULKAN_HEADERS_ENABLE_MODULE=OFF
cmake --install /tmp/loader-headers-build >/tmp/loader-headers-install.log
if [[ ! -d /tmp/Vulkan-Loader/.git ]]; then
    git clone --depth 1 --branch v1.4.353 https://github.com/KhronosGroup/Vulkan-Loader.git /tmp/Vulkan-Loader
fi
test "$(git -C /tmp/Vulkan-Loader rev-parse HEAD)" = 1025d2a5a05018b6dbb41440718af7a7f1153a94
cmake -S /tmp/Vulkan-Loader -B /tmp/loader-build -GNinja \
    -DCMAKE_SYSTEM_NAME=FreeBSD -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" -DCMAKE_ASM_COMPILER="$CC" \
    -DCMAKE_INSTALL_PREFIX=/tmp/loader-not-installed \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_LIBDIR=lib \
    -DVULKAN_HEADERS_INSTALL_DIR=/tmp/loader-headers \
    -DBUILD_TESTS=OFF -DLOADER_CODEGEN=OFF -DUPDATE_DEPS=OFF -DBUILD_WERROR=OFF \
    -DBUILD_WSI_XCB_SUPPORT=OFF -DBUILD_WSI_XLIB_SUPPORT=OFF \
    -DBUILD_WSI_XLIB_XRANDR_SUPPORT=OFF -DBUILD_WSI_WAYLAND_SUPPORT=OFF -DBUILD_WSI_DIRECTFB_SUPPORT=OFF
cmake --build /tmp/loader-build --parallel 2 --target vulkan
cp -L /tmp/loader-build/loader/libvulkan.so.1 "$out/libvulkan.so.1"
"$CC" -std=c11 -O2 -Wall -Wextra -Werror -I/tmp/loader-headers/include \
    "$script_dir/loader-no-driver.c" -ldl -o "$out/loader-no-driver"
for file in libvulkan.so.1 loader-no-driver; do
    "${CROSS_PREFIX}readelf" --file-header --program-headers --dynamic --version-info "$out/$file" >"$out/$file.elf.txt"
done
printf '%s\n' 'Vulkan-Loader v1.4.353' '1025d2a5a05018b6dbb41440718af7a7f1153a94' >"$out/source.txt"
echo 'Test-only real Vulkan loader and no-driver probe built successfully'
