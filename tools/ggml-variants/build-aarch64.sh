#!/bin/bash
# Usage: build-aarch64.sh [linux|windows|both] [workdir]
#
# Builds the two aarch64 targets through build-common.sh (which runs the
# repo's real 48-whisper.sh / 60-stemsplit.sh), then checks what can be
# checked without ARM hardware:
#
#   * every variant in the matrix was built and packed;
#   * the produced libggml-cpu-variants.a carries exactly one unprefixed
#     ggml_backend_cpu_reg (the dispatcher's forwarder) and one nm_vN_-prefixed
#     one per variant -- the check that catches COMDAT folding and a silently
#     half-packed archive;
#   * the ffmpeg binary is static and links the variants archive;
#   * linux-aarch64 only: the binary actually runs under qemu-user and the
#     dispatcher picks a variant, including when NOMERCY_GGML_CPU forces one.
#
# TIMINGS UNDER QEMU ARE MEANINGLESS and are deliberately never taken here.
# Real ARM numbers come from the fleet in Task 10.
#
# windows-aarch64 cannot be executed at all on this host (no Windows-on-ARM
# machine, and wine does not emulate ARM64 PE), so its verification stops at
# the archive/binary level by design.
set -eu
WHAT="${1:-both}"
REPO="${REPO:-$(cd "$(dirname "$0")/../.." && pwd)}"
WORK="${2:-${REPO}/.ggml-aarch64}"
IMAGE="${BASE_IMAGE:-nomercyentertainment/ffmpeg-base:latest}"
# Whisper test model for the qemu smoke run. Any ggml whisper model works; the
# ffblas-vol stubs whisper.cpp ships for its own tests are the cheapest.
SMOKE_MODEL_VOL="${SMOKE_MODEL_VOL:-ffblas-vol}"
SMOKE_MODEL="${SMOKE_MODEL:-/vol/whisper.cpp/models/for-tests-ggml-base.en.bin}"

fail() { echo "FAIL: $*" >&2; exit 1; }

# Expected variant tags, straight out of 48-whisper.sh's matrix, so this
# harness fails if the matrix silently loses a row. linux carries the i8mm
# variant; windows must not (no reliable runtime detection there).
linux_tags="armv8.0 armv8.2+dotprod+fp16 armv8.2+dotprod+fp16+i8mm"
windows_tags="armv8.0 armv8.2+dotprod+fp16"

check_platform() { # target-os  expected-tags
    local os="$1" tags="$2" out="${WORK}/${1}-aarch64"
    local ntags; ntags=$(set -- ${tags}; echo $#)
    echo "=== ${os}-aarch64: building ==="
    mkdir -p "${out}"
    "${REPO}/tools/ggml-variants/build-common.sh" "${os}" aarch64 "${out}"

    echo "=== ${os}-aarch64: variants in the build log ==="
    # whisper_build.log, not ffmpeg_build.log: 60-stemsplit.sh truncates the
    # latter, so the per-variant lines only survive in build-common.sh's
    # snapshot taken between the two scripts.
    local vlog="${out}/whisper_build.log"
    [[ -f ${vlog} ]] || fail "${os}: no whisper_build.log (build-common.sh did not snapshot it)"
    grep "ggml CPU variant" "${vlog}" || fail "${os}: no variant lines in whisper_build.log"
    local tag
    for tag in ${tags}; do
        grep -qF "Building ggml CPU variant ${tag}" "${vlog}" \
            || fail "${os}: variant ${tag} was not built"
    done
    grep -qF "Built ${ntags} ggml CPU variants" "${vlog}" \
        || fail "${os}: expected ${ntags} variants"

    echo "=== ${os}-aarch64: symbols in libggml-cpu-variants.a and in ffmpeg ==="
    [[ -f ${out}/libggml-cpu-variants.a ]] || fail "${os}: no libggml-cpu-variants.a"
    # One nm for both platforms: binutils-aarch64-linux-gnu reads ELF and,
    # since it carries the pe-aarch64-little BFD target, the Windows-on-ARM
    # PE objects and executables too. The alternative (apt llvm, for llvm-nm)
    # is an order of magnitude larger for the same answer.
    local bin=ffmpeg unstripped=ffmpeg_g
    [[ ${os} == windows ]] && { bin=ffmpeg.exe; unstripped=ffmpeg_g.exe; }
    MSYS_NO_PATHCONV=1 docker run --rm -v "$(cygpath -w "${out}")":/o:ro \
        -e NM_BIN="${unstripped}" -e NM_N="${ntags}" \
        "${IMAGE}" bash -c '
set -eu
N=aarch64-linux-gnu-nm
command -v ${N} >/dev/null || {
    apt-get update >/tmp/a.log 2>&1 && apt-get install -y --no-install-recommends binutils-aarch64-linux-gnu >>/tmp/a.log 2>&1
} || { cat /tmp/a.log; exit 1; }
for f in /o/libggml-cpu-variants.a /o/${NM_BIN}; do
    echo "-- ${f}"
    ${N} --defined-only "${f}" 2>/dev/null | grep -E "[ ](nm_v[0-9]+_)?ggml_backend_cpu_reg$" | sort -k3
    plain=$(${N} --defined-only "${f}" 2>/dev/null | grep -cE "[ ]ggml_backend_cpu_reg$")
    pref=$(${N} --defined-only "${f}" 2>/dev/null | grep -cE "[ ]nm_v[0-9]+_ggml_backend_cpu_reg$")
    echo "   unprefixed=${plain} prefixed=${pref} (expected 1 and ${NM_N})"
    [ "${plain}" = "1" ] || { echo "WRONG unprefixed count in ${f}"; exit 1; }
    [ "${pref}" = "${NM_N}" ] || { echo "WRONG prefixed count in ${f}"; exit 1; }
done
echo "-- nm_ggml_cpu_variant_name"
${N} --defined-only /o/${NM_BIN} 2>/dev/null | grep -E "nm_ggml_cpu_variant_name$" \
    || { echo "nm_ggml_cpu_variant_name not defined in ${NM_BIN}"; exit 1; }
' || fail "${os}: symbol check failed"

    echo "=== ${os}-aarch64: variant names reaching the shipped binary ==="
    MSYS_NO_PATHCONV=1 docker run --rm -v "$(cygpath -w "${out}")":/o:ro "${IMAGE}" \
        bash -c "strings -a /o/${bin} | grep -E '^armv8[.]' | sort -u" > "${out}/names.txt" \
        || fail "${os}: could not read variant names out of ${bin}"
    cat "${out}/names.txt"
    for tag in ${tags}; do
        grep -qxF "${tag}" "${out}/names.txt" || fail "${os}: ${tag} missing from ${bin}"
    done
    # The i8mm constraint is checked on the binary, not on a log line: Windows
    # exposes no feature flag for i8mm and inferring it from SVE is wrong on
    # Qualcomm Oryon, so that variant must not exist at all there.
    # NB: written as if/then, not "grep && fail" -- under set -e a grep that
    # correctly finds nothing would exit the script with the good result.
    if [[ ${os} == windows ]] && grep -q "i8mm" "${out}/names.txt"; then
        fail "windows-aarch64 must not carry an i8mm variant"
    fi

    echo "=== ${os}-aarch64: static and pkg-config ==="
    grep -q -- "-lggml-cpu-variants" "${out}/whisper.pc" || fail "${os}: whisper.pc does not link the variants archive"
    grep -E "^Libs" "${out}/whisper.pc"
    MSYS_NO_PATHCONV=1 docker run --rm -v "$(cygpath -w "${out}")":/o:ro "${IMAGE}" \
        bash -c "file /o/${bin}"
}

smoke_linux() { # qemu-user smoke run; NOT a benchmark
    local out="${WORK}/linux-aarch64"
    echo "=== linux-aarch64: qemu smoke run (timings meaningless, never quoted) ==="
    # The harness ffmpeg is built --disable-everything and does not carry the
    # lavfi input device, so the filter needs a real file. One second of
    # 16 kHz mono silence is enough to get the filter initialised, which is
    # where the variant is reported.
    MSYS_NO_PATHCONV=1 docker run --rm -v "$(cygpath -w "${out}")":/o "${IMAGE}" python3 -c '
import struct, sys
n = 16000
d = b"\x00\x00" * n
h = b"RIFF" + struct.pack("<I", 36 + len(d)) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, 16000, 32000, 2, 16) + b"data" + struct.pack("<I", len(d))
open("/o/silence.wav", "wb").write(h + d)
' || fail "linux: could not create the smoke-test wav"
    MSYS_NO_PATHCONV=1 docker run --rm --platform linux/arm64 \
        -v "$(cygpath -w "${out}")":/o:ro -v "${SMOKE_MODEL_VOL}":/vol:ro \
        -e SMOKE_MODEL="${SMOKE_MODEL}" ubuntu:24.04 bash -c '
set -eu
echo "-- uname: $(uname -m)"
cp /o/nm-probe /o/ffmpeg /tmp/ && chmod +x /tmp/nm-probe /tmp/ffmpeg
echo "-- nm-probe (dispatcher only):"
for v in "" armv8.0 "armv8.2+dotprod+fp16" "armv8.2+dotprod+fp16+i8mm" bogus-value; do
    printf "   NOMERCY_GGML_CPU=%-28s -> " "${v:-<unset>}"
    NOMERCY_GGML_CPU="${v}" /tmp/nm-probe
done
echo "-- ffmpeg through the whisper filter:"
NOMERCY_GGML_CPU= /tmp/ffmpeg -hide_banner -v info -i /o/silence.wav \
    -af "whisper=model=${SMOKE_MODEL}:queue=1" -f null - >/tmp/ff.log 2>&1 || true
# The pipeline is deliberately not "| grep"; with a trailing head the grep
# exit status is thrown away and a missing log line would read as success.
grep -E "ggml cpu variant" /tmp/ff.log \
    || { echo "no variant line in ffmpeg output:"; tail -15 /tmp/ff.log; exit 1; }
' || fail "linux: qemu smoke run failed"
}

case "${WHAT}" in
linux)   check_platform linux "${linux_tags}";   smoke_linux ;;
windows) check_platform windows "${windows_tags}" ;;
both)    check_platform linux "${linux_tags}";   smoke_linux
         check_platform windows "${windows_tags}" ;;
*) echo "usage: $0 [linux|windows|both] [workdir]" >&2; exit 1 ;;
esac

echo "ALL CHECKS PASSED (${WHAT})"
