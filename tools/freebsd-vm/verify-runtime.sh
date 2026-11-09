#!/bin/sh
# Run only inside a disposable FreeBSD guest. All .so fixtures are test-only.
# Usage: sh verify-runtime.sh DIRECTORY [FFMPEG]
set -eu
work=$(cd "${1:?fixture directory required}" && pwd)
ffmpeg=${2:-"$work/ffmpeg"}
ffmpeg=$(cd "$(dirname "$ffmpeg")" && pwd)/$(basename "$ffmpeg")
command -v timeout >/dev/null || { echo 'FreeBSD timeout is required' >&2; exit 1; }
test -x "$ffmpeg" || { echo "Missing FFmpeg executable: $ffmpeg" >&2; exit 1; }
test -x "$work/dlopen-main" || { echo 'Missing dlopen-main executable' >&2; exit 1; }
for file in plugin.so hostile-abort/libvulkan.so.1 hostile-hang/libvulkan.so.1; do
    test -f "$work/$file" || { echo "Missing test fixture: $file" >&2; exit 1; }
done
mkdir -p "$work/logs"
cd "$work"
# This runner targets FreeBSD /bin/sh, which supports the core-file limit.
# shellcheck disable=SC3045
ulimit -c 0
uname -a >logs/host.txt
freebsd-version -kru >>logs/host.txt
ldd "$ffmpeg" >logs/ffmpeg-ldd.txt
ldd ./dlopen-main >logs/dlopen-main-ldd.txt
if grep -E 'plugin[.]so|libsnappy|libc[+][+]|libgcc_s' logs/dlopen-main-ldd.txt; then
    echo 'Fixture main has an unexpected startup dependency' >&2
    exit 1
fi
timeout -k 2 20 ./dlopen-main "$work/plugin.so" >logs/dlopen-main.txt 2>&1
grep -q '^PASS: static Snappy/C++' logs/dlopen-main.txt
echo 'PASS: native plugin constructor, late TLS and cross-module allocations'

probe() {
    label=$1; fixture=$2; guard=$3; gpu=$4
    trace="$work/logs/$label.trace"
    rm -f "$trace"
    if env LD_LIBRARY_PATH="$work/$fixture" NM_FIXTURE_TRACE="$trace" \
        VK_DRIVER_FILES=/nonexistent.json VK_ICD_FILENAMES=/nonexistent.json \
        NOMERCY_VK_ICD_GUARD="$guard" NOMERCY_GGML_GPU="$gpu" \
        NOMERCY_VK_PROBE_MS=750 NOMERCY_VK_GUARD_MS=3500 \
        timeout -k 2 15 "$ffmpeg" -hide_banner -loglevel info -nostats -nostdin \
        -f lavfi -i anullsrc=channel_layout=mono:sample_rate=16000 -t 0.1 \
        -af whisper=model=/nonexistent.bin:use_gpu=0 -f null - \
        >"logs/$label.log" 2>&1; then
        status=0
    else
        status=$?
    fi
    printf '%s\n' "$status" >"logs/$label.status"
}

model_failure() {
    case "$(cat "logs/$1.status")" in
        1|5|251) ;;
        *) echo "$1 crashed, hung, or did not return the expected model error" >&2; exit 1 ;;
    esac
    grep -q 'Failed to initialize whisper context from model:' "logs/$1.log"
}

for fixture in hostile-abort hostile-hang; do
    label="guarded-$fixture"
    probe "$label" "$fixture" 1 1
    grep -q 'loaded pid=' "logs/$label.trace"
    model_failure "$label"
    case "$fixture" in
        hostile-abort) grep -q 'vulkan disabled for this process' "logs/$label.log" ;;
        hostile-hang) grep -q 'disabling vulkan for this process as a precaution' "logs/$label.log" ;;
    esac
    echo "PASS: $fixture isolated by guard; parent reached model-open failure"
done

probe gpu-off hostile-abort 0 0
test ! -e logs/gpu-off.trace
model_failure gpu-off
echo 'PASS: GPU-off path never opened the hostile loader'

# Prove the injected loaders are load-bearing, rather than accepting a fixture
# that never reached Vulkan. Both destructive controls run under timeout.
probe unguarded-abort hostile-abort 0 1
test "$(cat logs/unguarded-abort.status)" = 134
grep -q 'loaded pid=' logs/unguarded-abort.trace
probe unguarded-hang hostile-hang 0 1
case "$(cat logs/unguarded-hang.status)" in 124|137) ;; *) echo 'Hang control did not time out' >&2; exit 1 ;; esac
grep -q 'loaded pid=' logs/unguarded-hang.trace
echo 'PASS: unguarded abort and hang controls reproduce the injected failures'
echo 'FreeBSD native runtime checks passed; this does not prove physical GPU execution.'
