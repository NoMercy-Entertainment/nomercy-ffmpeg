#!/bin/bash
# Does ggml's Metal backend work on this Intel Mac, and is it worth using?
#
# Nothing in the build can answer that: the binary carries the shader SOURCE and
# the Mac compiles it on first use, on whatever GPU it has. tools/metal/
# verify-on-mac.sh asks the same for Apple Silicon and refuses to run here; this
# is the short version for an Intel Mac, made to be run by someone outside the
# project and to hand back one file.
#
#   check-intel-mac.sh <directory that holds ffmpeg>
#
# It needs a whisper model and a speech clip. ggml-base.en.bin (148 MB) and
# jfk.wav are downloaded into that directory when they are not there yet; set
# WHISPER_TEST_MODEL / WHISPER_TEST_AUDIO to use your own copies.
#
# What it answers, each with the evidence printed under it:
#
#   1. which backend the whisper filter takes by default on this GPU
#   2. whether the transcript on Metal is the same as on the CPU
#   3. how long both take on the same two minutes of speech (median of three)
#   4. whether NOMERCY_GGML_GPU=0 puts the filter back on the CPU
#
# When the default is the CPU (the GPU reports no Metal 3, or it is an
# integrated one), 2 and 3 are still measured, with NOMERCY_GGML_METAL=1, and
# the report says the run was forced.
#
# Everything is written to metal-intel-report.txt next to the binary.
#
# bash 3.2 and a stock macOS only: no python, no GNU tools.

set -uo pipefail

DIR="${1:?usage: check-intel-mac.sh <directory that holds ffmpeg>}"
DIR="$(cd "${DIR}" 2>/dev/null && pwd)" || { echo "no such directory: $1" >&2; exit 1; }
FF="${DIR}/ffmpeg"
REPORT="${DIR}/metal-intel-report.txt"
MODEL="${WHISPER_TEST_MODEL:-${DIR}/ggml-base.en.bin}"
CLIP="${WHISPER_TEST_AUDIO:-${DIR}/jfk.wav}"
MODEL_SHA=a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002
CLIP_SHA=59dfb9a4acb36fe2a2affc14bacbee2920ff435cb13cc314a08c13f66ba7860e

TMP="$(mktemp -d "${TMPDIR:-/tmp}/nm-metal-intel.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

exec > >(tee "${REPORT}") 2>&1

hr() { printf '%s\n' "----------------------------------------------------------------"; }

hr
echo "Metal on an Intel Mac -- $(date '+%Y-%m-%d %H:%M:%S %Z')"
hr

[ "$(uname -s)" = Darwin ] || { echo "STOP: this is not macOS ($(uname -s))"; exit 1; }
[ "$(uname -m)" = x86_64 ] || { echo "STOP: this is not an Intel Mac ($(uname -m)); use tools/metal/verify-on-mac.sh on Apple Silicon"; exit 1; }
[ -x "${FF}" ] || { echo "STOP: no executable ffmpeg in ${DIR}"; exit 1; }

echo "model  : $(sysctl -n hw.model 2>/dev/null)"
echo "cpu    : $(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
echo "macOS  : $(sw_vers -productVersion 2>/dev/null)"
system_profiler SPDisplaysDataType 2>/dev/null |
    grep -E 'Chipset Model|Vendor|VRAM|Metal|Bus:' | sed 's/^ */gpu    : /'

VERSION="$("${FF}" -hide_banner -version 2>&1)" ||
    { echo "${VERSION}"; echo "STOP: ffmpeg does not start (quarantine? xattr -d com.apple.quarantine '${FF}')"; exit 1; }
echo "ffmpeg : $(printf '%s\n' "${VERSION}" | head -1)"

# fetch <url> <file> <sha256>
fetch() {
    if [ ! -f "$2" ]; then
        echo "downloading $(basename "$2") from $1"
        curl -fL --retry 3 -o "$2" "$1" || { echo "STOP: download failed"; exit 1; }
    fi
    local got
    got="$(shasum -a 256 "$2" | cut -d' ' -f1)"
    [ "${got}" = "$3" ] || echo "note: $(basename "$2") is not the file CI uses (sha256 ${got})"
}
fetch "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin" "${MODEL}" "${MODEL_SHA}"
fetch "https://raw.githubusercontent.com/ggml-org/whisper.cpp/v1.9.1/samples/jfk.wav" "${CLIP}" "${CLIP_SHA}"

# The clip is 11 s. Eleven copies end to end give two minutes, enough for the
# GPU's start-up cost to stop deciding the outcome.
LONG="${TMP}/long.wav"
"${FF}" -hide_banner -loglevel error -stream_loop 10 -i "${CLIP}" -ac 1 -ar 16000 -c:a pcm_s16le "${LONG}" ||
    { echo "STOP: could not build the two-minute clip"; exit 1; }

# run <log> <input> <use_gpu or ""> [VAR=value ...]   -> wall seconds on stdout
run() {
    local log="$1" input="$2" gpu="$3" opt t
    shift 3
    opt="whisper=model=${MODEL}:language=en:queue=3"
    [ -n "${gpu}" ] && opt="${opt}:use_gpu=${gpu}"
    TIMEFORMAT='%R'
    t=$( { time env "$@" "${FF}" -hide_banner -loglevel info -nostats -i "${input}" -vn \
        -af "aresample=16000,aformat=sample_fmts=s16:channel_layouts=mono,${opt},ametadata=mode=print" \
        -f null - >"${log}" 2>&1; } 2>&1 )
    echo "$?" >"${log}.rc"
    printf '%s' "${t}"
}
backend() { grep -oE 'lavfi\.whisper\.backend=[a-z0-9_]+' "$1" | head -1 | sed 's/.*=//'; }
text()    { grep -oE 'lavfi\.whisper\.text=.*' "$1"; }
median()  { printf '%s\n' "$@" | sort -n | sed -n 2p; }

# ------------------------------------------------------------------ 1. default
hr
echo "1. Which backend does whisper take by default?"
run "${TMP}/default.log" "${CLIP}" "" >/dev/null
grep -E "nm_ggml_metal|ggml_metal_device_init|ggml_metal_init|embedded metal library|simdgroup|shared buffers|unified memory|GPU name|backend '" \
    "${TMP}/default.log" | sed 's/^/   /'
DEFAULT_BACKEND="$(backend "${TMP}/default.log")"
echo "   exit code ${DEFAULT_RC:=$(cat "${TMP}/default.log.rc")}, lavfi.whisper.backend=${DEFAULT_BACKEND:-<none>}"

FORCED=""
METAL_ENV="NM_UNUSED=1"
if [ "${DEFAULT_BACKEND}" != mtl ]; then
    FORCED="yes"
    METAL_ENV="NOMERCY_GGML_METAL=1"
    echo "   The default is not Metal here. Everything below that says Metal runs with ${METAL_ENV}."
fi

# --------------------------------------------------------------- 2. transcript
hr
echo "2. Is the transcript on Metal the same as on the CPU?"
run "${TMP}/cpu.log" "${CLIP}" 0 NM_UNUSED=1 >/dev/null
run "${TMP}/mtl.log" "${CLIP}" 1 "${METAL_ENV}" >/dev/null
CPU_TEXT="$(text "${TMP}/cpu.log")"
MTL_TEXT="$(text "${TMP}/mtl.log")"
MTL_BACKEND="$(backend "${TMP}/mtl.log")"
echo "   cpu   (exit $(cat "${TMP}/cpu.log.rc"), backend $(backend "${TMP}/cpu.log")):"
printf '%s\n' "${CPU_TEXT:-<no transcript>}" | sed 's/^/      /'
echo "   metal (exit $(cat "${TMP}/mtl.log.rc"), backend ${MTL_BACKEND:-<none>}):"
printf '%s\n' "${MTL_TEXT:-<no transcript>}" | sed 's/^/      /'
grep -E "cannot run|error|failed|unsupported" "${TMP}/mtl.log" | head -20 | sed 's/^/      log: /'
if [ "${MTL_BACKEND}" != mtl ]; then
    TEXT_VERDICT="NOT MEASURED: the Metal run reported backend '${MTL_BACKEND:-<none>}', not mtl"
elif [ -z "${CPU_TEXT}" ] || [ -z "${MTL_TEXT}" ]; then
    TEXT_VERDICT="FAIL: a run produced no transcript"
elif [ "${CPU_TEXT}" = "${MTL_TEXT}" ]; then
    TEXT_VERDICT="SAME"
else
    TEXT_VERDICT="DIFFERENT"
fi
echo "   ${TEXT_VERDICT}"

# -------------------------------------------------------------------- 3. speed
hr
echo "3. How long do both take on two minutes of speech?"
SPEED_VERDICT="NOT MEASURED: Metal did not run"
if [ "${MTL_BACKEND}" = mtl ]; then
    c1="$(run "${TMP}/s.log" "${LONG}" 0 NM_UNUSED=1)"; m1="$(run "${TMP}/s.log" "${LONG}" 1 "${METAL_ENV}")"
    c2="$(run "${TMP}/s.log" "${LONG}" 0 NM_UNUSED=1)"; m2="$(run "${TMP}/s.log" "${LONG}" 1 "${METAL_ENV}")"
    c3="$(run "${TMP}/s.log" "${LONG}" 0 NM_UNUSED=1)"; m3="$(run "${TMP}/s.log" "${LONG}" 1 "${METAL_ENV}")"
    echo "   cpu   : ${c1}s ${c2}s ${c3}s"
    echo "   metal : ${m1}s ${m2}s ${m3}s"
    CPU_T="$(median "${c1}" "${c2}" "${c3}")"
    MTL_T="$(median "${m1}" "${m2}" "${m3}")"
    SPEED_VERDICT="$(awk -v c="${CPU_T}" -v m="${MTL_T}" 'BEGIN{ if (m > 0) printf "cpu %ss, metal %ss: Metal is %.2fx the speed of the CPU", c, m, c/m; else print "NOT MEASURED: no time" }')"
fi
echo "   ${SPEED_VERDICT}"

# --------------------------------------------------------------- 4. off switch
hr
echo "4. Does NOMERCY_GGML_GPU=0 put whisper back on the CPU?"
run "${TMP}/off.log" "${CLIP}" "" NOMERCY_GGML_GPU=0 >/dev/null
OFF_BACKEND="$(backend "${TMP}/off.log")"
if [ "${OFF_BACKEND}" = cpu ]; then OFF_VERDICT="YES"; else OFF_VERDICT="NO: backend '${OFF_BACKEND:-<none>}'"; fi
echo "   ${OFF_VERDICT}"

# ---------------------------------------------------------------------- summary
hr
echo "SUMMARY"
echo "   default backend : ${DEFAULT_BACKEND:-<none>} (exit code ${DEFAULT_RC})"
echo "   metal forced    : ${FORCED:-no}"
echo "   transcript      : ${TEXT_VERDICT}"
echo "   speed           : ${SPEED_VERDICT}"
echo "   off switch      : ${OFF_VERDICT}"
hr
echo "Please send back ${REPORT}"
