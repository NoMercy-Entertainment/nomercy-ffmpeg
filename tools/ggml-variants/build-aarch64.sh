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
    # The compute probe is only worth building where the binary can actually
    # be run, which here means linux under qemu; there is no interpreter for a
    # Windows-on-ARM PE on this host at all.
    local compute=0
    [[ ${os} == linux ]] && compute=1
    # NM_SKIP_BUILD=1 re-runs every CHECK against the artifacts already in
    # ${out} without rebuilding them. For iterating on the checks themselves -
    # a full cross build is ~25 minutes and a bug in an assertion should not
    # cost that. It is not a way to verify a source change: what it tests is
    # whatever binary is sitting in the work directory, so any report that used
    # it has to say which build that was.
    if [[ ${NM_SKIP_BUILD:-0} == 1 ]]; then
        echo "  (NM_SKIP_BUILD=1: checking the existing artifacts in ${out}, not rebuilding)"
    else
        NM_COMPUTE_PROBE=${compute} "${REPO}/tools/ggml-variants/build-common.sh" "${os}" aarch64 "${out}"
    fi

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

    check_vulkan "${os}" "${out}" "${bin}" "${unstripped}"
}

# ggml's Vulkan backend on a target that has never been run.
#
# Both aarch64 targets build it (48-whisper.sh sets NM_VULKAN=1 everywhere but
# darwin and freebsd) and neither had ever been checked for it. windows-aarch64
# is the one with a real reason to break: it has no `ld -r`, so 48-whisper.sh
# assembles its variants archive per-member with an `ar -M` MRI script whose
# ADDLIB expects archives, and the Vulkan shim is a bare object that needed its
# own ADDMOD line. `ar -M` is also documented in that script to report a failed
# script on stdout while still exiting 0, so "the build succeeded" is not
# evidence that the shim is in the archive. These checks are what makes it
# evidence.
check_vulkan() { # target-os  outdir  binary  unstripped-binary
    local os="$1" out="$2" bin="$3" unstripped="$4"

    echo "=== ${os}-aarch64: vulkan backend, shim and link order ==="
    [[ -f ${out}/libggml-vulkan.a ]] || fail "${os}: no libggml-vulkan.a was produced (NM_VULKAN should be 1 here)"

    # Link order. A static linker resolves left to right, so -lggml-vulkan must
    # come before the archive carrying the shim that defines its three loader
    # symbols. Checked on the generated whisper.pc, not on the generator.
    local libs; libs=$(grep -E "^Libs:" "${out}/whisper.pc")
    case "${libs}" in
    *-lggml-vulkan*-lggml-cpu-variants*) echo "  ok: -lggml-vulkan precedes -lggml-cpu-variants" ;;
    *) fail "${os}: whisper.pc link order is wrong for the shim: ${libs}" ;;
    esac

    # The guard is compiled only for non-Windows, non-Apple builds, so
    # linux-aarch64 must carry it and windows-aarch64 must not. Read off the
    # binary rather than off the preprocessor conditions: a string only the
    # guarded build emits. (Both are also confirmed by running, for linux under
    # qemu below; windows-aarch64 cannot be executed on this host at all.)
    local want_guard=1
    [[ ${os} == windows ]] && want_guard=0

    MSYS_NO_PATHCONV=1 docker run --rm -v "$(cygpath -w "${out}")":/o:ro \
        -e NM_BIN="${bin}" -e NM_UNSTRIPPED="${unstripped}" -e NM_OS="${os}" \
        -e NM_WANT_GUARD="${want_guard}" "${IMAGE}" bash -c '
set -eu
N=aarch64-linux-gnu-nm
command -v ${N} >/dev/null || {
    apt-get update >/tmp/a.log 2>&1 && apt-get install -y --no-install-recommends binutils-aarch64-linux-gnu >>/tmp/a.log 2>&1
} || { cat /tmp/a.log; exit 1; }
OD=aarch64-linux-gnu-objdump

echo "-- undefined loader symbols in libggml-vulkan.a (the shim has to supply these)"
undef=$(${N} --undefined-only /o/libggml-vulkan.a 2>/dev/null | grep -oE "\bvk[A-Za-z0-9]+" | sort -u)
echo "${undef}" | sed "s/^/   /"
for s in vkGetInstanceProcAddr vkCmdCopyBuffer vkGetPhysicalDeviceFeatures2; do
    echo "${undef}" | grep -qx "${s}" || { echo "   MISSING undefined symbol ${s}"; exit 1; }
done
n=$(echo "${undef}" | grep -c . )
[ "${n}" = "3" ] || { echo "   expected exactly 3 undefined vk* symbols, got ${n}"; exit 1; }

echo "-- the shim itself, inside libggml-cpu-variants.a"
# This is the windows-aarch64 MRI/ADDMOD check. One definition, not zero (the
# ADDMOD line silently dropped) and not several (the object added twice).
for s in vkGetInstanceProcAddr vkCmdCopyBuffer vkGetPhysicalDeviceFeatures2; do
    c=$(${N} --defined-only /o/libggml-cpu-variants.a 2>/dev/null | grep -cE "[ ]T ${s}$")
    echo "   ${s}: ${c} definition(s)"
    [ "${c}" = "1" ] || { echo "   expected exactly 1"; exit 1; }
done

echo "-- and resolved in the linked binary (nothing left undefined)"
left=$(${N} --undefined-only /o/${NM_UNSTRIPPED} 2>/dev/null | grep -cE "\bvk[A-Za-z0-9]+" || true)
echo "   undefined vk* symbols in ${NM_UNSTRIPPED}: ${left}"
[ "${left}" = "0" ] || { echo "   the shim did not resolve them"; exit 1; }

echo "-- no Vulkan loader as a link-time dependency (the binary must stay static)"
if [ "${NM_OS}" = windows ]; then
    # PE import table. NOT a string search: vk_loader_shim.c contains the
    # literal "vulkan-1.dll" for its LoadLibraryA call, so grepping the binary
    # would match a perfectly correct build.
    dlls=$(${OD} -p /o/${NM_BIN} 2>/dev/null | grep -i "DLL Name:" | sed "s/.*DLL Name: //" | sort -u)
    [ -n "${dlls}" ] || { echo "   could not read the PE import table"; exit 1; }
    echo "${dlls}" | tr "\n" " " | sed "s/^/   /"; echo
    if echo "${dlls}" | grep -qi vulkan; then echo "   FAIL: imports a Vulkan loader"; exit 1; fi
    echo "   ok: no vulkan DLL in the import table"
else
    dyn=$(aarch64-linux-gnu-readelf -d /o/${NM_BIN} 2>/dev/null | grep NEEDED || true)
    echo "   NEEDED entries: ${dyn:-<none, fully static>}"
    if echo "${dyn}" | grep -qi vulkan; then echo "   FAIL: links a Vulkan loader"; exit 1; fi
    echo "   ok: no loader dependency"
fi

echo "-- the fork-and-probe guard: compiled in here? (expected ${NM_WANT_GUARD})"
# A notice only the guarded build can print. NOT "software rasteriser": that
# phrase is also in nm_vk_scan s device-name table, which is compiled on every
# platform, so it is present in a Windows binary with the guard correctly
# absent. Caught by this check failing on windows-aarch64 for a reason that
# turned out to be the check, not the build.
if strings -a /o/${NM_BIN} | grep -q "crash a statically linked"; then got=1; else got=0; fi
echo "   guard present=${got}"
[ "${got}" = "${NM_WANT_GUARD}" ] || { echo "   guard is on the wrong side of its #if for ${NM_OS}"; exit 1; }
' || fail "${os}: vulkan checks failed"
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
        -e SMOKE_MODEL="${SMOKE_MODEL}" -e NM_TAGS="${linux_tags}" ubuntu:24.04 bash -c '
set -eu
echo "-- uname: $(uname -m)"
cp /o/nm-probe /o/nm-compute /o/ffmpeg /tmp/ && chmod +x /tmp/nm-probe /tmp/nm-compute /tmp/ffmpeg
echo "-- nm-probe: which variant the dispatcher SELECTS (no backend is entered)"
for v in "" ${NM_TAGS} bogus-value; do
    printf "   NOMERCY_GGML_CPU=%-28s -> " "${v:-<unset>}"
    NOMERCY_GGML_CPU="${v}" /tmp/nm-probe
done

# The checks that matter: each variant runs its OWN packed code. nm-probe
# above never enters a backend, and an automatic run only ever exercises
# whichever variant this machine happens to select -- under qemu that is the
# i8mm one, because qemu advertises HWCAP2_I8MM. The baseline is the variant
# the whole Raspberry Pi 4 / Jetson Nano safety story rests on, so it is run
# first and becomes the reference every other variant is compared against.
echo "-- nm-compute: real matmul through each variant, checked against the baseline"
rm -f /tmp/ref.bin
for v in ${NM_TAGS}; do
    echo "   --- NOMERCY_GGML_CPU=${v}"
    NOMERCY_GGML_CPU="${v}" /tmp/nm-compute /tmp/ref.bin 2>&1 | sed "s/^/      /"
    [ "${PIPESTATUS[0]}" = "0" ] || { echo "compute probe failed for ${v}"; exit 1; }
done

# And the same through the real filter, forced to each variant in turn, so it
# is the shipped ffmpeg binary doing it and not just a probe.
echo "-- ffmpeg through the whisper filter, forced to each variant:"
first_md5=""
for v in ${NM_TAGS}; do
    NOMERCY_GGML_CPU="${v}" /tmp/ffmpeg -hide_banner -y -nostats -v info -i /o/silence.wav \
        -af "whisper=model=${SMOKE_MODEL}:queue=1" -f wav "/tmp/out-${v}.wav" >"/tmp/ff-${v}.log" 2>&1 \
        || { echo "ffmpeg failed with NOMERCY_GGML_CPU=${v}:"; tail -15 "/tmp/ff-${v}.log"; exit 1; }
    # grep, not "| grep | head": a trailing head throws away the grep status
    # and a missing log line would read as success.
    line=$(grep -m1 -E "ggml cpu variant" "/tmp/ff-${v}.log") \
        || { echo "no variant line for ${v}:"; tail -15 "/tmp/ff-${v}.log"; exit 1; }
    case "${line}" in
    *"${v}"*) ;;
    *) echo "   forced ${v} but the filter reported: ${line}"; exit 1 ;;
    esac
    md5=$(md5sum < "/tmp/out-${v}.wav" | cut -d" " -f1)
    echo "   ${v}: ${line##*] } output $(stat -c%s "/tmp/out-${v}.wav") bytes md5 ${md5}"
    # Every variant must pass the audio through unchanged; a differing stream
    # would mean one of them corrupted the frames it forwarded.
    if [ -z "${first_md5}" ]; then first_md5="${md5}"
    elif [ "${md5}" != "${first_md5}" ]; then echo "   audio output differs between variants"; exit 1
    fi
done
echo "   all variants produced identical audio output"
' || fail "linux: qemu smoke run failed"
}

# The GPU path on linux-aarch64, under arm64 emulation.
#
# WHAT THIS IS AND IS NOT. qemu offers no GPU, so the only correct answer here
# is "cpu" in every configuration - which is exactly the case that must never
# regress, and exactly the case four separate startup crashes were found in on
# x86_64. It is NOT a test that a real Mali/Adreno/Tegra GPU is selected; no
# such machine exists on this host. Timings are meaningless under qemu and are
# not taken.
#
# Two conditions, because they are genuinely different machines:
#   * no ICD at all      - the common case, and the cheap one.
#   * a software ICD     - mesa's lavpipe. This is the guard's whole reason for
#                          existing: on x86_64 a software Vulkan stack in a
#                          static binary is what crashed, and the fork-and-probe
#                          guard is compiled into this target too. Whether it
#                          crashes the same way on arm64 is a question only
#                          running it can answer.
smoke_linux_vulkan() {
    local out="${WORK}/linux-aarch64"
    echo "=== linux-aarch64: vulkan under qemu (no GPU exists here; cpu is the right answer) ==="
    MSYS_NO_PATHCONV=1 docker run --rm --platform linux/arm64 \
        -v "$(cygpath -w "${out}")":/o:ro -v "${SMOKE_MODEL_VOL}":/vol:ro \
        -e SMOKE_MODEL="${SMOKE_MODEL}" ubuntu:24.04 bash -c '
set -eu
cp /o/ffmpeg /o/nm-probe /tmp/ && chmod +x /tmp/ffmpeg /tmp/nm-probe
fail=0

run_whisper() { # run_whisper <label> <use_gpu-suffix>
    rc=0
    /tmp/ffmpeg -hide_banner -y -nostats -v info -i /o/silence.wav \
        -af "whisper=model=${SMOKE_MODEL}:queue=1$2" -f wav /tmp/vk-out.wav \
        > /tmp/vk.log 2>&1 || rc=$?
    # sed, not `tr -d`, to take the quotes off: this whole script is inside a
    # single-quoted bash -c string, so a literal apostrophe cannot appear here
    # and `tr -d "\x27"` does NOT mean what it looks like - bash passes it
    # through unchanged and tr deletes the characters \ x 2 7 instead, leaving
    # the quotes on. That read as "expected cpu, got cpu" on the first run of
    # this check. The dot in the pattern is the quote.
    be=$(grep -oE "whisper: ggml backend .[a-z0-9]+." /tmp/vk.log | head -1 | sed -E "s/.*backend .([a-z0-9]+)./\1/")
    echo "   $1: exit=${rc} backend=${be:-<none>}"
    # exit 0 is the load-bearing assertion. A machine with no usable GPU must
    # behave exactly as it did before any of this existed.
    [ "${rc}" = "0" ] || { echo "      FAIL: did not exit cleanly"; tail -8 /tmp/vk.log | sed "s/^/      /"; fail=1; }
    [ "${be}" = "cpu" ] || { echo "      FAIL: expected the cpu backend under qemu, got ${be:-<none>}"; fail=1; }
}

echo "-- no ICD registered at all"
ls /usr/share/vulkan/icd.d/ 2>/dev/null | sed "s/^/   icd: /" || echo "   (no icd.d directory)"
run_whisper "whisper default (use_gpu=1)" ""
run_whisper "whisper use_gpu=0" ":use_gpu=0"
echo "-- the dispatcher still picks a cpu variant with vulkan linked in"
/tmp/nm-probe | sed "s/^/   nm-probe: /"

echo "-- now with a software vulkan stack installed (the guard s motivating case)"
export DEBIAN_FRONTEND=noninteractive
if apt-get update >/tmp/apt.log 2>&1 && apt-get install -y --no-install-recommends mesa-vulkan-drivers >>/tmp/apt.log 2>&1; then
    echo "   ICD manifests present: $(ls /usr/share/vulkan/icd.d/ | tr "\n" " ")"
    run_whisper "whisper default (use_gpu=1), software ICD" ""
    run_whisper "whisper use_gpu=0, software ICD" ":use_gpu=0"
    echo "-- what the guard said, if anything:"
    grep -oE "whisper: .*vulkan.*" /tmp/vk.log | head -2 | sed "s/^/   /" || echo "   (nothing)"
else
    echo "   SKIPPED: mesa-vulkan-drivers could not be installed in this arm64 container"
    tail -3 /tmp/apt.log | sed "s/^/   /"
    fail=1
fi

[ "${fail}" = "0" ] || { echo "vulkan qemu checks failed"; exit 1; }
' || fail "linux: qemu vulkan run failed"
}

case "${WHAT}" in
linux)   check_platform linux "${linux_tags}";   smoke_linux; smoke_linux_vulkan ;;
windows) check_platform windows "${windows_tags}" ;;
both)    check_platform linux "${linux_tags}";   smoke_linux; smoke_linux_vulkan
         check_platform windows "${windows_tags}" ;;
*) echo "usage: $0 [linux|windows|both] [workdir]" >&2; exit 1 ;;
esac

echo "ALL CHECKS PASSED (${WHAT})"
