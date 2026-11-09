#!/bin/sh
# Run inside a disposable FreeBSD guest; the loader DSO is a test fixture.
# Usage: sh verify-real-loader.sh LOADER_DIRECTORY FFMPEG
set -eu
loader=$(cd "${1:?loader fixture directory required}" && pwd)
ffmpeg=${2:?FreeBSD FFmpeg executable required}
ffmpeg=$(cd "$(dirname "$ffmpeg")" && pwd)/$(basename "$ffmpeg")
logs="$loader/logs-ffmpeg"
test -x "$ffmpeg"
test -x "$loader/loader-no-driver"
test -f "$loader/libvulkan.so.1"
mkdir -p "$logs"
# This runner targets FreeBSD /bin/sh, which supports the core-file limit.
# shellcheck disable=SC3045
ulimit -c 0
uname -a >"$logs/host.txt"
freebsd-version -kru >>"$logs/host.txt"
ldd "$ffmpeg" >"$logs/ffmpeg-ldd.txt"
env VK_DRIVER_FILES=/nonexistent.json VK_ICD_FILENAMES=/nonexistent.json \
    timeout -k 2 20 "$loader/loader-no-driver" "$loader/libvulkan.so.1" \
    >"$logs/loader-api.log" 2>&1
grep -Fq 'Real Vulkan loader API: 1.4.353' "$logs/loader-api.log"

if env LD_LIBRARY_PATH="$loader" VK_LOADER_DEBUG=error \
    VK_DRIVER_FILES=/nonexistent.json VK_ICD_FILENAMES=/nonexistent.json \
    NOMERCY_GGML_CPU=x64 NOMERCY_GGML_GPU=1 NOMERCY_VK_ICD_GUARD=1 \
    NOMERCY_VK_PROBE_MS=5000 NOMERCY_VK_GUARD_MS=15000 \
    timeout -k 2 35 "$ffmpeg" -hide_banner -loglevel info -nostats -nostdin \
    -f lavfi -i anullsrc=channel_layout=mono:sample_rate=16000 -t 0.1 \
    -af whisper=model=/nonexistent.bin:use_gpu=0 -f null - \
    >"$logs/whisper-no-driver.log" 2>&1; then
    status=0
else
    status=$?
fi
printf '%s\n' "$status" >"$logs/whisper-no-driver.status"
case "$status" in 1|5|251) ;; *) echo "Unexpected whisper status: $status"; exit 1 ;; esac
grep -q 'Failed to initialize whisper context from model:' "$logs/whisper-no-driver.log"
grep -Eq 'loader_get_json|vkCreateInstance: Found no drivers' "$logs/whisper-no-driver.log"
echo 'PASS: real Vulkan loader/no-ICD whisper startup reaches ordinary missing-model failure'

if env LD_LIBRARY_PATH="$loader" VK_LOADER_DEBUG=error \
    VK_DRIVER_FILES=/nonexistent.json VK_ICD_FILENAMES=/nonexistent.json \
    timeout -k 2 25 "$ffmpeg" -hide_banner -loglevel info -nostats -nostdin \
    -init_hw_device vulkan=test -f lavfi \
    -i anullsrc=channel_layout=mono:sample_rate=16000 -t 0.1 -f null - \
    >"$logs/hw-device-no-driver.log" 2>&1; then
    status=0
else
    status=$?
fi
printf '%s\n' "$status" >"$logs/hw-device-no-driver.status"
case "$status" in 1|187) ;; *) echo "Unexpected hardware-device status: $status"; exit 1 ;; esac
grep -Eq 'loader_get_json|vkCreateInstance: Found no drivers' "$logs/hw-device-no-driver.log"
grep -q 'Device creation failed' "$logs/hw-device-no-driver.log"
echo 'PASS: explicit Vulkan hardware-device request fails cleanly without an ICD'
echo 'No GPU execution or model inference parity is established by these checks.'
