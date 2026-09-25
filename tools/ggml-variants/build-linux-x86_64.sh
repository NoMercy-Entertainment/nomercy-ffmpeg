#!/bin/bash
# Build a minimal linux-x86_64 ffmpeg against the variant-enabled whisper and
# check that stemsplit is fast by default and slow when forced to baseline.
#
# Inputs expected in ${WORK} before running (see task-3-report.md for where
# to get them): spleeter-2stems-f16.gguf, input.mp3, ggml-base.en.bin.
#
# DEVIATION 1 from the plan: the plan's variant-selection check grepped
# ffmpeg's verbose log for "cpu variant '<name>'" -- a string Task 4 (report
# the selected variant from both filters) is responsible for adding, and
# Task 4 runs AFTER this task in the plan's own ordering (docs/superpowers/
# plans/2026-09-23-ggml-cpu-hardware-acceleration.md: Task 3 at line 612,
# Task 4 at line 856). Nothing on this branch emits that line yet, so that
# check would fail regardless of whether the build wiring is correct. This
# harness instead asserts variant selection directly against the produced
# libggml-cpu-variants.a via a tiny static probe binary (built by
# build-common.sh) that calls nm_ggml_cpu_variant_name() -- proving the same
# fact without depending on or duplicating Task 4's not-yet-written filter
# code.
#
# DEVIATION 2 from the plan: the plan ran the entire harness, build-common.sh
# (and its own nested `docker run`) included, inside a single `docker run
# ubuntu:24.04 bash build-linux-x86_64.sh` with no docker socket mounted and
# no docker CLI in that image -- Docker-in-Docker that could not have worked
# as written. On this Windows host (Git Bash + Docker Desktop, no nested
# docker), build-common.sh runs directly on the host and does its own single
# `docker run`; this script does its own SEPARATE single `docker run` for the
# measurement phase, mounting the same ${WORK} directory. Never more than one
# level of container nesting.
set -eu
REPO="${REPO:-$(cd "$(dirname "$0")/../.." && pwd)}"
WORK="${WORK:-/tmp/nm-linux-x86_64}"
IMAGE="${BASE_IMAGE:-nomercyentertainment/ffmpeg-base:latest}"

[[ -f "${WORK}/spleeter-2stems-f16.gguf" ]] || { echo "missing ${WORK}/spleeter-2stems-f16.gguf" >&2; exit 1; }
[[ -f "${WORK}/input.mp3" ]] || { echo "missing ${WORK}/input.mp3" >&2; exit 1; }
[[ -f "${WORK}/ggml-base.en.bin" ]] || { echo "missing ${WORK}/ggml-base.en.bin" >&2; exit 1; }

# NM_SKIP_BUILD=1 reuses whatever is already in ${WORK} from a previous run
# (iteration convenience; not part of the plan). Default is a full rebuild
# through the real 48-whisper.sh, as specified.
if [[ "${NM_SKIP_BUILD:-0}" != "1" ]]; then
    bash "$(dirname "$0")/build-common.sh" linux x86_64 "${WORK}"
fi

[[ -f "${WORK}/ffmpeg" ]] || { echo "FAIL: ${WORK}/ffmpeg was not built"; exit 1; }
[[ -f "${WORK}/nm-probe" ]] || { echo "FAIL: ${WORK}/nm-probe was not built (libggml-cpu-variants.a missing?)"; exit 1; }

MSYS_NO_PATHCONV=1 docker run --rm -v "$(cygpath -w "${WORK}")":/work "${IMAGE}" bash -c '
set -eu
cd /work
chmod +x ./ffmpeg ./nm-probe
fail=0

echo "== exactly one CPU backend implementation linked =="
# DEVIATION 3: the task brief'"'"'s suggested check ("-f lavfi -i anullsrc ...
# | grep \"ggml_backend_registry: registered backend CPU\"") does not work
# against this harness build: lavfi is an input device this minimal
# --disable-everything ffmpeg never enables, so the run fails before ggml
# even initialises, and separately that exact log string does not exist
# anywhere in whisper.cpp 1.9.1 / ggml 0.15.1 (confirmed via `strings` on the
# linked binary) -- it was never emitted at any log level. What "exactly one
# CPU backend" actually means structurally is: exactly one DEFINED, unprefixed
# ggml_backend_cpu_reg symbol reaches the final link (a second one -- e.g. a
# leftover stock libggml-cpu.a also linked -- would be a link-time multiple
# definition error, not a silent runtime duplicate), plus the 4 packed
# variants each keeping their own prefixed copy. Checking the symbol table of
# the pre-strip ffmpeg_g (build-common.sh copies it out alongside ffmpeg)
# proves this directly instead of grepping for a log line that does not
# exist.
unprefixed=$(nm --defined-only ffmpeg_g 2>/dev/null | grep -cE " T ggml_backend_cpu_reg$")
prefixed=$(nm --defined-only ffmpeg_g 2>/dev/null | grep -cE " T nm_v[0-9]+_ggml_backend_cpu_reg$")
echo "  unprefixed ggml_backend_cpu_reg: ${unprefixed}, prefixed (packed variant) copies: ${prefixed}"
[[ ${unprefixed} -eq 1 ]] || { echo "  FAIL: expected exactly 1 unprefixed ggml_backend_cpu_reg, got ${unprefixed}"; fail=1; }
[[ ${prefixed} -eq 4 ]] || { echo "  FAIL: expected 4 packed variant copies (x64, sse42, ivybridge, haswell), got ${prefixed}"; fail=1; }

echo "== static link check =="
if ldd ./ffmpeg 2>&1 | grep -qi "not a dynamic executable"; then
    echo "  static: yes"
else
    echo "  FAIL: ffmpeg is not statically linked:"
    ldd ./ffmpeg || true
    fail=1
fi

echo "== variant probe (direct call, not filter log -- see DEVIATION 1) =="
auto_variant=$(./nm-probe)
forced_variant=$(NOMERCY_GGML_CPU=x64 ./nm-probe)
bogus_variant=$(NOMERCY_GGML_CPU=nonsense-value ./nm-probe)
echo "  auto: ${auto_variant}, forced x64: ${forced_variant}, bogus override: ${bogus_variant}"
[[ -n ${auto_variant} ]] || { echo "  FAIL: no variant reported"; fail=1; }
[[ ${forced_variant} == "x64" ]] || { echo "  FAIL: NOMERCY_GGML_CPU=x64 did not select x64 (got ${forced_variant})"; fail=1; }
[[ ${bogus_variant} == "${auto_variant}" ]] || { echo "  FAIL: unknown override did not fall back to auto choice"; fail=1; }

echo "== timing: automatic selection vs forced baseline =="
run_stemsplit() {
    local tag="$1"; shift
    local start end
    start=$(date +%s%N)
    env "$@" ./ffmpeg -hide_banner -loglevel error -nostats -y -t 30 -i input.mp3 -vn \
        -af "stemsplit=model=spleeter-2stems-f16.gguf:stem=accompaniment" -f wav "out-${tag}.wav"
    end=$(date +%s%N)
    echo $(( (end - start) / 1000000 ))
}
auto_ms=$(run_stemsplit auto)
base_ms=$(run_stemsplit base NOMERCY_GGML_CPU=x64)
echo "  auto: ${auto_ms} ms, forced baseline: ${base_ms} ms"
[[ ${auto_ms} -lt $(( base_ms * 2 / 3 )) ]] || { echo "  FAIL: automatic choice is not faster than baseline"; fail=1; }

echo "== audio similarity: auto vs forced baseline output =="
python3 - out-auto.wav out-base.wav <<"PY" || fail=1
import sys, wave, math, array

def rd(path):
    w = wave.open(path, "rb")
    a = array.array("h")
    a.frombytes(w.readframes(w.getnframes()))
    return a

a, b = rd(sys.argv[1]), rd(sys.argv[2])
n = min(len(a), len(b))
sum_sig = 0.0
sum_diff = 0.0
for i in range(n):
    av = a[i]
    bv = b[i]
    sum_sig += av * av
    d = av - bv
    sum_diff += d * d
rms_sig = math.sqrt(sum_sig / n) if n else 0.0
rms_diff = math.sqrt(sum_diff / n) if n else 0.0
db = 20 * math.log10(rms_diff / rms_sig) if rms_diff and rms_sig else -999.0
print(f"  variant difference: {db:.1f} dB relative")
sys.exit(0 if db < -80 else 1)
PY

echo "== filter-level cpu variant metadata (Task 4) =="
# NOTE 1: the task-4 brief'"'"'s snippet referenced ${MODEL}/${INPUT}/${WORK}/ffmpeg,
# none of which exist in this script -- it hardcodes spleeter-2stems-f16.gguf,
# input.mp3 and ./ffmpeg (see the rest of this file). Adapted to match, and
# forced to NOMERCY_GGML_CPU=x64 so this also proves the metadata carries the
# variant actually in use rather than a hardcoded string.
# NOTE 2: the brief'"'"'s snippet (and every other check above) runs at
# "-loglevel error", but ametadata'"'"'s mode=print writes its output via
# av_log(ctx, AV_LOG_INFO, ...) (libavfilter/f_metadata.c) -- at "error"
# level that print is silently swallowed along with our own "cpu variant"
# log line, so the grep found nothing no matter how correct the filter code
# was. Confirmed by reading f_metadata.c and reproducing manually. This
# check needs -loglevel info.
meta=$(NOMERCY_GGML_CPU=x64 ./ffmpeg -hide_banner -loglevel info -nostats -t 12 -i input.mp3 -vn \
    -af "stemsplit=model=spleeter-2stems-f16.gguf:stem=accompaniment,ametadata=mode=print:key=lavfi.stemsplit.cpu_variant" \
    -f null - 2>&1 | grep -oE "lavfi.stemsplit.cpu_variant=[a-z0-9.+_]+" | head -1)
echo "  metadata: ${meta:-<none>}"
[[ -n ${meta} ]] || { echo "  FAIL: no cpu_variant metadata"; fail=1; }
[[ ${meta} == "lavfi.stemsplit.cpu_variant=x64" ]] || { echo "  FAIL: forced x64 not reflected in metadata (got ${meta})"; fail=1; }

echo "== stemsplit log line has the required shape =="
logline=$(NOMERCY_GGML_CPU=x64 ./ffmpeg -hide_banner -loglevel info -nostats -t 2 -i input.mp3 -vn \
    -af "stemsplit=model=spleeter-2stems-f16.gguf:stem=accompaniment" -f null - 2>&1 \
    | grep -oE "cpu variant '"'"'x64'"'"'" | head -1)
echo "  log: ${logline:-<none>}"
[[ -n ${logline} ]] || { echo "  FAIL: no \"cpu variant '"'"'...'"'"'\" log line"; fail=1; }

echo "== filter-level backend reporting (Task 3) =="
# Both filters must name the backend they actually ran on, and publish it as
# metadata. This container has no GPU, so the only correct answer is "cpu" --
# which is also the assertion that matters most: global constraint 1 is that a
# GPU-less machine behaves exactly as it did before this code existed.
ss_out=$(./ffmpeg -hide_banner -loglevel info -nostats -t 12 -i input.mp3 -vn \
    -af "stemsplit=model=spleeter-2stems-f16.gguf:stem=accompaniment,ametadata=mode=print:key=lavfi.stemsplit.backend" \
    -f null - 2>&1)
ss_meta=$(echo "${ss_out}" | grep -oE "lavfi.stemsplit.backend=[a-z0-9_]+" | head -1)
ss_log=$(echo "${ss_out}" | grep -oE "stemsplit: ggml backend .[a-z0-9_]+. \([^)]*\)" | head -1)
echo "  stemsplit metadata: ${ss_meta:-<none>}"
echo "  stemsplit log: ${ss_log:-<none>}"
[[ ${ss_meta} == "lavfi.stemsplit.backend=cpu" ]] || { echo "  FAIL: stemsplit backend metadata is not cpu on a GPU-less host"; fail=1; }
[[ -n ${ss_log} ]] || { echo "  FAIL: stemsplit did not log a backend"; fail=1; }

# whisper publishes its metadata only on a frame that actually carried a
# transcript, so this needs a model and an input that produce one. The 586 KB
# ggml-base.en.bin this harness requires is a stub that transcribes nothing:
# with it NEITHER lavfi.whisper.cpu_variant NOR lavfi.whisper.backend appears,
# and asserting on the backend key alone would have reported a bug that is not
# there (it did, on the first run of this check). Use a real model and jfk.wav
# when they are present in WORK -- optional inputs, exactly as they were for
# Task 2 -- and in every case assert the structural property that holds either
# way: the backend key appears wherever the already-verified cpu_variant key
# appears, i.e. beside lavfi.whisper.text and NOT inside the language branch.
wh_model=ggml-base.en.bin
wh_input=input.mp3
[[ -f ggml-base.en-real.bin ]] && wh_model=ggml-base.en-real.bin
[[ -f jfk.wav ]] && wh_input=jfk.wav
wh_out=$(./ffmpeg -hide_banner -loglevel info -nostats -t 12 -i ${wh_input} -vn \
    -af "aresample=16000,aformat=sample_fmts=s16:channel_layouts=mono,whisper=model=${wh_model}:language=en:queue=3,ametadata=mode=print" \
    -f null - 2>&1)
wh_status=$?
wh_cpuvar_n=$(echo "${wh_out}" | grep -c "lavfi.whisper.cpu_variant=" || true)
wh_backend_n=$(echo "${wh_out}" | grep -c "lavfi.whisper.backend=" || true)
wh_meta=$(echo "${wh_out}" | grep -oE "lavfi.whisper.backend=[a-z0-9_]+" | head -1)
wh_log=$(echo "${wh_out}" | grep -oE "whisper: ggml backend .[a-z0-9_]+. \([^)]*\)" | head -1)
echo "  whisper model: ${wh_model}, input: ${wh_input}"
echo "  whisper exit code: ${wh_status}"
echo "  whisper cpu_variant keys: ${wh_cpuvar_n}, backend keys: ${wh_backend_n}"
echo "  whisper metadata: ${wh_meta:-<none>}"
echo "  whisper log: ${wh_log:-<none>}"
[[ ${wh_status} -eq 0 ]] || { echo "  FAIL: whisper run did not exit 0"; fail=1; }
[[ ${wh_backend_n} -eq ${wh_cpuvar_n} ]] || { echo "  FAIL: backend key does not accompany cpu_variant on every transcribed frame"; fail=1; }
if [[ ${wh_cpuvar_n} -gt 0 ]]; then
    [[ ${wh_meta} == "lavfi.whisper.backend=cpu" ]] || { echo "  FAIL: whisper backend metadata is not cpu on a GPU-less host"; fail=1; }
else
    echo "  NOTE: this model transcribed nothing, so the check above is structural only."
    echo "        Put a real ggml-base.en-real.bin and jfk.wav in WORK to check the value too."
fi
[[ -n ${wh_log} ]] || { echo "  FAIL: whisper did not log a backend"; fail=1; }

echo "== the gpu options parse on both filters =="
# These have to exist and parse even where there is no GPU to select; a typo in
# an AVOption would only ever show up here. Both directions, because since the
# owner ruling stemsplit defaults to use_gpu=0 and whisper to 1, so each filter
# has one value that is its default and one that is not, and neither should be
# the only one exercised.
if ./ffmpeg -hide_banner -loglevel error -nostats -t 2 -i input.mp3 -vn \
    -af "stemsplit=model=spleeter-2stems-f16.gguf:stem=accompaniment:use_gpu=0" -f null - >/dev/null 2>&1; then
    echo "  ok: stemsplit use_gpu=0"
else
    echo "  FAIL: stemsplit rejected use_gpu=0"; fail=1
fi
if ./ffmpeg -hide_banner -loglevel error -nostats -t 2 -i input.mp3 -vn \
    -af "aresample=16000,aformat=sample_fmts=s16:channel_layouts=mono,whisper=model=ggml-base.en.bin:language=en:queue=3:use_gpu=0" -f null - >/dev/null 2>&1; then
    echo "  ok: whisper use_gpu=0"
else
    echo "  FAIL: whisper rejected use_gpu=0"; fail=1
fi
if ./ffmpeg -hide_banner -loglevel error -nostats -t 2 -i input.mp3 -vn     -af "stemsplit=model=spleeter-2stems-f16.gguf:stem=accompaniment:use_gpu=1:gpu_device=0" -f null - >/dev/null 2>&1; then
    echo "  ok: stemsplit use_gpu=1 gpu_device=0"
else
    echo "  FAIL: stemsplit rejected use_gpu=1/gpu_device"; fail=1
fi


echo "== ggml vulkan backend linked into the binary =="
# DEVIATION 4 from the plan (task-2-brief.md Step 2): its suggested check
# ("-f lavfi -i anullsrc=... | grep -qi vulkan") does not work against this
# harness build for the exact same reason as DEVIATION 3 above: lavfi is an
# input device this minimal --disable-everything ffmpeg never enables (no
# --enable-indev=lavfi, no anullsrc filter), so the run fails before ggml even
# initialises. Two checks instead, neither depending on lavfi:
#   1. the pre-strip binary carries exactly one defined ggml_backend_vk_reg
#      symbol -- proves the backend was actually linked in, not merely
#      configured (a configure-only failure would leave this symbol absent).
#   2. actually running the whisper filter makes ggml'"'"'s backend registry
#      enumerate devices, which unconditionally fprintf'"'"'s a "ggml_vulkan:"
#      line straight to stderr -- this is a raw ggml fprintf, not behind
#      av_log, so it appears regardless of -loglevel.
# FOUND WHILE VERIFYING: this probe originally ran stemsplit (already
# exercised above for timing/metadata), on the assumption that linking
# ggml-vulkan in is enough by itself to trigger device enumeration on ANY
# ggml use. Empirically false: stemsplit produced zero "ggml_vulkan:" output
# (0/0 ffmpeg exit, otherwise healthy) -- NoMercy'"'"'s stemsplit path drives
# ggml-cpu directly through the variant dispatcher and never calls
# whisper.cpp'"'"'s own backend auto-selection at all. The whisper filter does
# (it goes through unmodified whisper.cpp, which probes for a GPU backend on
# every init unless told not to), and reliably printed "ggml_vulkan: Error:
# Vulkan 1.2 required." here -- confirmed by hand first, see task-2-report.md.
# That message, not "No devices found.", is what a real loader with zero
# registered ICDs (this image ships libvulkan1 via libvulkan-dev but no GPU
# driver, no mesa-vulkan-drivers) actually produces: ggml_vulkan still treats
# it as an ordinary, handled Vulkan error, not a crash -- ffmpeg exits 0 and
# the transcription completes on CPU either way, which is the real thing this
# check needs to prove (global constraint 1: no regression for a GPU-less
# user). NM_SKIP_VARIANTS-style "No devices found." would also be acceptable;
# the assertion below matches on the "ggml_vulkan:" prefix common to both.
vk_reg=$(nm --defined-only ffmpeg_g 2>/dev/null | grep -cE " T ggml_backend_vk_reg$")
echo "  defined ggml_backend_vk_reg in ffmpeg_g: ${vk_reg}"
[[ ${vk_reg} -eq 1 ]] || { echo "  FAIL: expected exactly 1 ggml_backend_vk_reg, got ${vk_reg}"; fail=1; }

vk_probe_out=$(./ffmpeg -hide_banner -loglevel error -nostats -y -t 2 -i input.mp3 -vn \
    -af "aresample=16000,aformat=sample_fmts=s16:channel_layouts=mono,whisper=model=ggml-base.en.bin:language=en:queue=3" \
    -f null - 2>&1)
vk_status=$?
vk_lines=$(echo "${vk_probe_out}" | grep -c "ggml_vulkan:" || true)
echo "  whisper run exit code: ${vk_status}"
echo "  ggml_vulkan: lines seen at runtime: ${vk_lines}"
echo "${vk_probe_out}" | grep "ggml_vulkan:" | head -5 | sed "s/^/  /"
[[ ${vk_status} -eq 0 ]] || { echo "  FAIL: whisper run crashed/exited non-zero with vulkan built in"; fail=1; }
[[ ${vk_lines} -gt 0 ]] || { echo "  FAIL: no ggml_vulkan: output seen at runtime"; fail=1; }

echo "== still static (vulkan build) =="
if file ./ffmpeg | grep -q "statically linked"; then echo "  ok: static"; else echo "  FAIL: not static"; fail=1; fi

echo "== no vulkan loader import (must stay fully static) =="
if ldd ./ffmpeg 2>&1 | grep -qi vulkan; then echo "  FAIL: links the loader"; fail=1; else echo "  ok: no loader dependency"; fi

[[ ${fail} -eq 0 ]] && echo PASS || { echo FAILED; exit 1; }
'

# The machine this whole guard exists for: a software Vulkan stack (Mesa) and no
# GPU. A SEPARATE container, because the checks above deliberately run in the
# clean base image and installing mesa-vulkan-drivers there would change what
# every one of them is testing.
#
# This is the filter-level version of the regression that shipped once: the
# guard used to be the right-hand side of an && with use_gpu, so
# whisper=...:use_gpu=0 skipped it and died at exit 139 - on the exact option a
# user reaches for when a GPU is causing trouble. The parse check further up
# cannot see that, because it runs where there are no ICDs at all. Both filters,
# both values of use_gpu, all four must exit 0.
echo
echo "=== Mesa-container regression: both filters must survive with and without use_gpu ==="
MSYS_NO_PATHCONV=1 docker run --rm -v "$(cygpath -w "${WORK}")":/work "${IMAGE}" bash -c '
set -u
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends mesa-vulkan-drivers >/dev/null 2>&1
cd /work
chmod +x ./ffmpeg
echo "  ICD manifests present: $(ls /usr/share/vulkan/icd.d/ | wc -l)"
fail=0
wh_model=ggml-base.en.bin
[[ -f ggml-base.en-real.bin ]] && wh_model=ggml-base.en-real.bin

for ug in 1 0; do
    ./ffmpeg -hide_banner -loglevel error -nostats -t 2 -i input.mp3 -vn \
        -af "stemsplit=model=spleeter-2stems-f16.gguf:stem=accompaniment:use_gpu=${ug}" \
        -f null - >/dev/null 2>&1
    rc=$?
    echo "  stemsplit use_gpu=${ug}: exit ${rc}"
    [[ ${rc} -eq 0 ]] || { echo "  FAIL: stemsplit died on a software-Vulkan machine with use_gpu=${ug}"; fail=1; }

    ./ffmpeg -hide_banner -loglevel error -nostats -t 2 -i input.mp3 -vn \
        -af "aresample=16000,aformat=sample_fmts=s16:channel_layouts=mono,whisper=model=${wh_model}:language=en:queue=3:use_gpu=${ug}" \
        -f null - >/dev/null 2>&1
    rc=$?
    echo "  whisper   use_gpu=${ug}: exit ${rc}"
    [[ ${rc} -eq 0 ]] || { echo "  FAIL: whisper died on a software-Vulkan machine with use_gpu=${ug}"; fail=1; }
done

# The third route to the same crash, and the one the review could only
# demonstrate with a static probe. An inconclusive guard verdict used to leave
# the process to die inside ggml_backend_load_all(); it now pins as a
# precaution, so the real filter must survive an unusable budget on a machine
# with fatal ICDs. Both filters, both use_gpu values.
# Both knobs, because they are distinct paths into the precaution: an
# exhausted total budget returns UNKNOWN from nm_vk_probe before it forks at
# all, while an unusable per-probe cap forks and then times out. Only the first
# was covered when this block was added.
echo "  with an unusable guard budget (the precautionary path):"
for knob in NOMERCY_VK_GUARD_MS NOMERCY_VK_PROBE_MS; do
for ug in 1 0; do
    env ${knob}=1 ./ffmpeg -hide_banner -loglevel error -nostats -t 2 -i input.mp3 -vn         -af "aresample=16000,aformat=sample_fmts=s16:channel_layouts=mono,whisper=model=${wh_model}:language=en:queue=3:use_gpu=${ug}"         -f null - >/dev/null 2>&1
    rc=$?
    echo "    whisper   use_gpu=${ug}, ${knob}=1: exit ${rc}"
    [[ ${rc} -eq 0 ]] || { echo "  FAIL: whisper died when the guard could not finish (${knob})"; fail=1; }

    env ${knob}=1 ./ffmpeg -hide_banner -loglevel error -nostats -t 2 -i input.mp3 -vn         -af "stemsplit=model=spleeter-2stems-f16.gguf:stem=accompaniment:use_gpu=${ug}"         -f null - >/dev/null 2>&1
    rc=$?
    echo "    stemsplit use_gpu=${ug}, ${knob}=1: exit ${rc}"
    [[ ${rc} -eq 0 ]] || { echo "  FAIL: stemsplit died when the guard could not finish (${knob})"; fail=1; }
done
done

# --- the four verdict arms of the guard, actually observed ------------------
#
# NOTE FOR EDITORS: this whole block is inside a single-quoted string, so it
# cannot contain an apostrophe. Hence the stilted wording below.
#
# vulkan_guard_vocabulary_intact in tests/lib/cpu-variant.sh proves the phrases
# still EXIST in the binary; that is all a string search can do, and on the
# platforms no runner can execute it is all there is. THIS is where the
# stronger claim belongs: that each arm still prints its own message and not
# the message of a neighbour. It needs a machine whose drivers misbehave, which
# is what this Mesa container is.
#
# The negative half of each assertion is the part that was missing everywhere
# until the Task 6 review: nothing would have caught an arm printing BOTH
# messages, which is precisely what a collapse looks like.

notice_for() {  # notice_for <env assignments...>; echoes the guard notice, if any
    env "$@" ./ffmpeg -hide_banner -loglevel info -nostats -t 2 -i input.mp3 -vn \
        -af "stemsplit=model=spleeter-2stems-f16.gguf:stem=accompaniment" -f null - 2>&1 \
        | grep -oE "stemsplit: (could not verify|this machine.s vulkan drivers crash|the only vulkan device)[^$]*" \
        | head -1
}

assert_arm() {  # assert_arm <label> <notice> <must-contain> <must-not-contain>
    local label="$1" notice="$2" want="$3" nope="$4"
    echo "  ${label}:"
    echo "    said: ${notice:-<nothing>}"
    if [[ "${notice}" != *"${want}"* ]]; then
        echo "  FAIL: ${label} did not say \"${want}\""; fail=1; return
    fi
    # The half nothing checked before. An arm that says its own message AND the
    # message of a neighbour has collapsed just as surely as one that says only
    # the wrong message, and it reads as a pass to any positive-only assertion.
    if [[ "${notice}" == *"${nope}"* ]]; then
        echo "  FAIL: ${label} ALSO said \"${nope}\" - the wording of two arms in one notice"; fail=1; return
    fi
    echo "    ok: said its own message, and not \"${nope}\""
}

# Arm 3, the precaution. The guard could not decide anything at all, so it must
# say in so many words that this is not a fault report, and must NOT use the
# crash wording - that sends a user chasing a driver bug they do not have.
assert_arm "precaution (NOMERCY_VK_GUARD_MS=1)" \
    "$(notice_for NOMERCY_VK_GUARD_MS=1)" \
    "not a report that anything is broken" \
    "crash a statically linked"

# Arm 2, a crash the bisect could not finish attributing. Reached only in a
# window: long enough to watch the whole set die, too short to finish the
# bisect. It must not claim nothing is broken.
#
# R1: that window MOVES. This used to pin NOMERCY_VK_GUARD_MS=80 with a
# "the bisect completed at this budget; nothing to check here" fallback, and on
# a faster container 80 ms now completes - so the check quietly passed through
# the plain crash arm without ever exercising the truncated path it was written
# for. It could not false-fail, but it had stopped covering, which is how every
# dead check on this branch started. Sweep instead, and FAIL if no budget in
# the sweep reaches the arm: better to be told the path is unreachable than to
# be told nothing.
truncated=""
for ms in 30 40 60 80 120 160; do
    n="$(notice_for NOMERCY_VK_GUARD_MS=${ms})"
    if [[ "${n}" == *"could not finish identifying which"* ]]; then
        truncated="${n}"
        echo "  truncated-bisect arm reached at NOMERCY_VK_GUARD_MS=${ms}"
        break
    fi
done
if [[ -z "${truncated}" ]]; then
    echo "  FAIL: no budget in 30..160 ms reached the truncated-bisect arm."
    echo "        Either the arm is gone, or the timings of this machine have moved out of the"
    echo "        swept range - widen it. Do NOT downgrade this to a note: that is what let the"
    echo "        old fixed-80ms version stop covering silently."
    fail=1
else
    assert_arm "observed crash, bisect truncated" "${truncated}" \
        "could not finish identifying which" \
        "not a report that anything is broken"
    # This arm offers the budget knob - safe, and the thing that would actually
    # finish the bisect - and must NOT offer to skip the guard, which on this
    # exact machine is exit 139. That was N11.
    case "${truncated}" in
    *NOMERCY_VK_ICD_GUARD*) echo "  FAIL: recommended skipping the guard to a machine we watched crash"; fail=1 ;;
    *NOMERCY_VK_GUARD_MS*)  echo "    ok: offers the budget knob, and does not offer to skip the guard" ;;
    *) echo "  FAIL: offers no way forward at all"; fail=1 ;;
    esac
fi

# Arm 1, a fully identified crash: a conclusion, and the only arm allowed to
# state one. At the shipped budget the bisect finishes here.
assert_arm "observed crash, fully identified (default budget)" \
    "$(notice_for NOMERCY_VK_DUMMY=0)" \
    "crash a statically linked" \
    "not a report that anything is broken"

echo "  guard notice, as the filters report it:"
./ffmpeg -hide_banner -loglevel info -nostats -t 2 -i input.mp3 -vn \
    -af "stemsplit=model=spleeter-2stems-f16.gguf:stem=accompaniment" -f null - 2>&1 \
    | grep -oE "stemsplit: .*vulkan.*" | head -1 | sed "s/^/    /"

[[ ${fail} -eq 0 ]] && echo "  PASS" || { echo "  FAILED"; exit 1; }
'
