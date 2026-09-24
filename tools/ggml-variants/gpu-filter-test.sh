#!/bin/bash
# Both filters, on a machine that HAS a GPU: do they use it only when asked, do
# they say so, and do they still produce the right numbers and the right words?
#
# The no-GPU conditions are covered by backend-select-test.sh, which runs in
# containers. This one needs real hardware, so it runs wherever that hardware is
# - on this project's Windows host (Git Bash), against the ffmpeg.exe
# build-windows-x86_64.sh produced, or on any Linux box with a working Vulkan
# driver against the ffmpeg build-linux-x86_64.sh produced.
#
# Usage:  bash tools/ggml-variants/gpu-filter-test.sh <workdir> [ffmpeg-name]
# <workdir> must hold ffmpeg(.exe), spleeter-2stems-f16.gguf and input.mp3; the
# whisper half additionally needs a real model and a speech clip
# (ggml-base.en-real.bin and jfk.wav, the same optional inputs
# build-linux-x86_64.sh uses), because whisper only publishes metadata on a
# frame that actually carried a transcript.
set -eu
WORK="${1:?usage: gpu-filter-test.sh <workdir> [ffmpeg-name]}"
FF="${WORK}/${2:-ffmpeg.exe}"
fail=0

[[ -x ${FF} ]] || { echo "no such ffmpeg: ${FF}" >&2; exit 1; }
cd "${WORK}"

MODEL=spleeter-2stems-f16.gguf
WMODEL=ggml-base.en.bin
WINPUT=input.mp3
[[ -f ggml-base.en-real.bin ]] && WMODEL=ggml-base.en-real.bin
[[ -f jfk.wav ]] && WINPUT=jfk.wav

rms_db() {   # rms_db <a.wav> <b.wav> <threshold-db> <label>
    python3 - "$1" "$2" "$3" "$4" <<"PY"
import sys, wave, math, array

def rd(path):
    w = wave.open(path, "rb")
    a = array.array("h")
    a.frombytes(w.readframes(w.getnframes()))
    return a

a, b = rd(sys.argv[1]), rd(sys.argv[2])
limit, label = float(sys.argv[3]), sys.argv[4]
n = min(len(a), len(b))
sig = diff = 0.0
for i in range(n):
    sig += a[i] * a[i]
    d = a[i] - b[i]
    diff += d * d
rms_sig = math.sqrt(sig / n) if n else 0.0
rms_diff = math.sqrt(diff / n) if n else 0.0
db = 20 * math.log10(rms_diff / rms_sig) if rms_diff and rms_sig else -999.0
print(f"  {label}: {db:.1f} dB relative over {n} samples (limit {limit:.0f})")
sys.exit(0 if db < limit else 1)
PY
}

# ---------------------------------------------------------------- stemsplit

# stemsplit's use_gpu defaults to 0: it never had a GPU path, so defaulting it
# on would change the audio of every existing command line on a GPU host. The
# default must therefore select the CPU EVEN HERE, on a machine with a working
# RTX 3070 - that is the assertion, not an accident of the test environment.
echo "== stemsplit default (use_gpu unset) must stay on the CPU =="
ss_def=$("${FF}" -hide_banner -loglevel info -nostats -y -t 30 -i input.mp3 -vn \
    -af "stemsplit=model=${MODEL}:stem=accompaniment,ametadata=mode=print:key=lavfi.stemsplit.backend" \
    -f wav cpu.wav 2>&1) || true
echo "${ss_def}" | grep -E "stemsplit: ggml backend|lavfi.stemsplit.backend=" | head -2 | sed "s/^/  /"
ss_def_meta=$(echo "${ss_def}" | grep -oE "lavfi.stemsplit.backend=[a-z0-9_]+" | head -1)
[[ ${ss_def_meta} == "lavfi.stemsplit.backend=cpu" ]] \
    || { echo "  FAIL: the default must be cpu, got ${ss_def_meta:-<none>}"; fail=1; }

echo "== stemsplit with use_gpu=1 must take the GPU =="
ss_gpu=$("${FF}" -hide_banner -loglevel info -nostats -y -t 30 -i input.mp3 -vn \
    -af "stemsplit=model=${MODEL}:stem=accompaniment:use_gpu=1,ametadata=mode=print:key=lavfi.stemsplit.backend" \
    -f wav gpu.wav 2>&1) || true
echo "${ss_gpu}" | grep -E "stemsplit: ggml backend|lavfi.stemsplit.backend=" | head -2 | sed "s/^/  /"
ss_gpu_meta=$(echo "${ss_gpu}" | grep -oE "lavfi.stemsplit.backend=[a-z0-9_]+" | head -1)
[[ ${ss_gpu_meta} == "lavfi.stemsplit.backend=vulkan" ]] \
    || { echo "  FAIL: expected lavfi.stemsplit.backend=vulkan, got ${ss_gpu_meta:-<none>}"; fail=1; }

echo "== stemsplit with an out-of-range gpu_device must say cpu, not name device 0 =="
ss_far=$("${FF}" -hide_banner -loglevel info -nostats -t 2 -i input.mp3 -vn \
    -af "stemsplit=model=${MODEL}:stem=accompaniment:use_gpu=1:gpu_device=99,ametadata=mode=print:key=lavfi.stemsplit.backend" \
    -f null - 2>&1) || true
echo "${ss_far}" | grep -E "gpu_device=99|stemsplit: ggml backend|lavfi.stemsplit.backend=" | head -2 | sed "s/^/  /"
ss_far_meta=$(echo "${ss_far}" | grep -oE "lavfi.stemsplit.backend=[a-z0-9_]+" | head -1)
[[ ${ss_far_meta} == "lavfi.stemsplit.backend=cpu" ]] \
    || { echo "  FAIL: gpu_device=99 should report cpu, got ${ss_far_meta:-<none>}"; fail=1; }

echo "== GPU output vs CPU output (both explicit) =="
# Not bit-identical by construction, and the gap is bigger than "different order
# of operations" would suggest. ggml-vulkan's cooperative-matrix conv2d shader
# accumulates in float16 (vulkan-shaders/conv2d_mm.comp: ACC_TYPE float16_t
# under COOPMAT2, coopmat<float16_t, ..., gl_MatrixUseAccumulator> under
# COOPMAT), so on any GPU that advertises KHR_coopmat the whole U-Net runs with
# FP16 accumulators. Measured on an RTX 3070: -58.8 dB with the coopmat path,
# -98.7 dB with GGML_VK_DISABLE_COOPMAT=1, at the same speed (1023 ms vs
# 1032 ms over 30 s of audio). That gap is exactly why use_gpu defaults to 0.
#
# So -55 dB is the threshold for the DEFAULT GPU path - from that measurement,
# with headroom - and the second comparison is what actually proves the
# arithmetic is right: with the FP16 accumulator out of the way the GPU agrees
# with the CPU to -90 dB or better. A regression in our own code would move
# BOTH numbers; only the accumulator moves the first one alone.
rms_db gpu.wav cpu.wav -55 "gpu (use_gpu=1, coopmat) vs cpu" || fail=1

echo "== GPU output vs CPU output, FP16 accumulator disabled =="
GGML_VK_DISABLE_COOPMAT=1 "${FF}" -hide_banner -loglevel error -nostats -y -t 30 -i input.mp3 -vn \
    -af "stemsplit=model=${MODEL}:stem=accompaniment:use_gpu=1" -f wav gpu_nocoop.wav >/dev/null 2>&1 || true
rms_db gpu_nocoop.wav cpu.wav -90 "gpu (GGML_VK_DISABLE_COOPMAT=1) vs cpu" || fail=1

# ------------------------------------------------------------------ whisper

echo "== whisper default (use_gpu unset) takes the GPU =="
wh_gpu=$("${FF}" -hide_banner -loglevel info -nostats -t 12 -i ${WINPUT} -vn \
    -af "aresample=16000,aformat=sample_fmts=s16:channel_layouts=mono,whisper=model=${WMODEL}:language=en:queue=3,ametadata=mode=print" \
    -f null - 2>&1) || true
echo "${wh_gpu}" | grep -E "whisper: ggml backend|lavfi.whisper.backend=" | head -2 | sed "s/^/  /"
wh_gpu_meta=$(echo "${wh_gpu}" | grep -oE "lavfi.whisper.backend=[a-z0-9_]+" | head -1)
[[ ${wh_gpu_meta} == "lavfi.whisper.backend=vulkan" ]] \
    || { echo "  FAIL: expected lavfi.whisper.backend=vulkan, got ${wh_gpu_meta:-<none>} (is ${WMODEL} a real model, and ${WINPUT} speech?)"; fail=1; }

echo "== whisper forced to the CPU (use_gpu=0) =="
wh_cpu=$("${FF}" -hide_banner -loglevel info -nostats -t 12 -i ${WINPUT} -vn \
    -af "aresample=16000,aformat=sample_fmts=s16:channel_layouts=mono,whisper=model=${WMODEL}:language=en:queue=3:use_gpu=0,ametadata=mode=print" \
    -f null - 2>&1) || true
echo "${wh_cpu}" | grep -E "whisper: ggml backend|lavfi.whisper.backend=" | head -2 | sed "s/^/  /"
wh_cpu_meta=$(echo "${wh_cpu}" | grep -oE "lavfi.whisper.backend=[a-z0-9_]+" | head -1)
[[ ${wh_cpu_meta} == "lavfi.whisper.backend=cpu" ]] \
    || { echo "  FAIL: use_gpu=0 did not force the CPU (got ${wh_cpu_meta:-<none>})"; fail=1; }

echo "== whisper with an out-of-range gpu_device must say cpu =="
wh_far=$("${FF}" -hide_banner -loglevel info -nostats -t 12 -i ${WINPUT} -vn \
    -af "aresample=16000,aformat=sample_fmts=s16:channel_layouts=mono,whisper=model=${WMODEL}:language=en:queue=3:gpu_device=99,ametadata=mode=print" \
    -f null - 2>&1) || true
echo "${wh_far}" | grep -E "gpu_device=99|whisper: ggml backend|lavfi.whisper.backend=" | head -2 | sed "s/^/  /"
wh_far_meta=$(echo "${wh_far}" | grep -oE "lavfi.whisper.backend=[a-z0-9_]+" | head -1)
[[ ${wh_far_meta} == "lavfi.whisper.backend=cpu" ]] \
    || { echo "  FAIL: gpu_device=99 should report cpu, got ${wh_far_meta:-<none>}"; fail=1; }

# THE CHECK THAT MATTERS MOST FOR WHISPER.
#
# whisper's use_gpu has always defaulted to 1, but until this branch no GPU
# backend was compiled in, so in practice every existing whisper user has been
# running on the CPU. Turning Vulkan on therefore moves all of them onto the
# GPU without their asking. For stemsplit the equivalent change was -58.8 dB of
# inaudible audio and the owner still chose to make it opt-in; a silently
# different TRANSCRIPT would be a much bigger deal, so it has to be measured
# rather than assumed. The transcripts must match exactly - not "closely".
#
# Three inputs, because a few seconds of clean speech is too easy to catch a
# real divergence:
#   jfk.wav              clean speech, the easy case
#   jfk.wav x8           the same speech looped, ~90 s: eight times the decode
#                        windows, so any drift has room to accumulate and flip
#                        a token
#   input.mp3, 60 s      music with no speech in it, which is the hardest case
#                        there is - the model is maximally uncertain, so the
#                        smallest numerical difference changes what it emits.
#                        This is the input most likely to expose a divergence,
#                        which is precisely why it is here.
run_whisper() {  # run_whisper <use_gpu> <outfile> <input-args...>
    local ug="$1" out="$2"; shift 2
    "${FF}" -hide_banner -loglevel info -nostats "$@" -vn \
        -af "aresample=16000,aformat=sample_fmts=s16:channel_layouts=mono,whisper=model=${WMODEL}:language=en:queue=3:use_gpu=${ug},ametadata=mode=print" \
        -f null - > "${out}" 2>&1 || true
}

# Three things have to be true before "the transcripts match" means anything,
# and only the first was checked when this was written:
#
#   1. the two transcripts are equal;
#   2. there IS a transcript - two empty outputs compare equal, so a model that
#      transcribed nothing would have passed silently;
#   3. the GPU run actually ran on the GPU - on a host where the guard had
#      switched Vulkan off, both sides would run on the CPU and this would pass
#      while proving nothing at all.
#
# A check that passes when it should not have run is worse than no check, so all
# three are asserted here rather than relied on from elsewhere in the file.
compare_transcripts() {   # compare_transcripts <label> <input-args...>
    local label="$1"; shift
    local g c gb cb n

    echo "== whisper transcript, GPU vs CPU: ${label} =="
    run_whisper 1 "${WORK}/wh_gpu.log" "$@"
    run_whisper 0 "${WORK}/wh_cpu.log" "$@"

    g=$(grep -oE "lavfi\.whisper\.text=.*" "${WORK}/wh_gpu.log" || true)
    c=$(grep -oE "lavfi\.whisper\.text=.*" "${WORK}/wh_cpu.log" || true)
    gb=$(grep -oE "lavfi\.whisper\.backend=[a-z0-9_]+" "${WORK}/wh_gpu.log" | head -1 || true)
    cb=$(grep -oE "lavfi\.whisper\.backend=[a-z0-9_]+" "${WORK}/wh_cpu.log" | head -1 || true)
    n=$(printf "%s" "${g}" | grep -c . || true)

    echo "  gpu run backend: ${gb:-<none>}   cpu run backend: ${cb:-<none>}   segments: ${n}"

    if [[ -z ${g} ]]; then
        echo "  FAIL: the GPU run produced no transcript at all - two empty outputs"
        echo "        would compare equal, so this comparison would have been vacuous"
        fail=1
        return
    fi
    [[ ${gb} == "lavfi.whisper.backend=vulkan" ]] \
        || { echo "  FAIL: the use_gpu=1 run did not report vulkan (got ${gb:-<none>}); this comparison proves nothing"; fail=1; return; }
    [[ ${cb} == "lavfi.whisper.backend=cpu" ]] \
        || { echo "  FAIL: the use_gpu=0 run did not report cpu (got ${cb:-<none>})"; fail=1; return; }

    if [[ "${g}" == "${c}" ]]; then
        echo "  IDENTICAL (${n} segment(s), both backends confirmed)"
        printf "%s\n" "${g}" | head -3 | sed "s/^/    /"
    else
        echo "  *** DIFFERENT - this is a silent behaviour change for every whisper user ***"
        echo "  --- gpu ---"; printf "%s\n" "${g}" | sed "s/^/    /"
        echo "  --- cpu ---"; printf "%s\n" "${c}" | sed "s/^/    /"
        fail=1
    fi
}

if [[ -f jfk.wav ]]; then
    compare_transcripts "jfk.wav, clean speech" -i jfk.wav
    compare_transcripts "jfk.wav looped 8x, ~90 s of speech" -stream_loop 7 -i jfk.wav
else
    echo "== whisper transcript, GPU vs CPU: SKIPPED, no jfk.wav in ${WORK} =="
    fail=1
fi
compare_transcripts "60 s of music, the model at its least certain" -t 60 -i input.mp3

[[ ${fail} -eq 0 ]] && echo PASS || { echo FAILED; exit 1; }
