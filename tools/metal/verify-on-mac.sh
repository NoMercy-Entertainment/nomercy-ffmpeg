#!/bin/bash
# The four Metal release gates from docs/superpowers/plans/2026-09-27-metal-backend.md
# (Task 4), run on the only machine that can answer them: a real Apple Silicon Mac.
#
# Nothing in the build pipeline runs a Metal compiler or executes a line of Metal
# code -- ggml embeds the shader *source* and the user's machine compiles it the
# first time it is needed. So every claim below has to be produced HERE, on
# hardware, not reasoned about in a cross-compile container. This script is the
# only thing that can answer:
#
#   1. does the embedded MSL actually compile at all
#   2. what does that compile cost a use_gpu=0 user who never asked for it
#   3. does a device get selected outside an interactive GUI session (the media
#      server runs as a launchd job / over SSH, not from Terminal.app)
#   4. does Metal produce the same answer as the CPU path, and is it actually
#      faster than the fixed-level NEON CPU build
#
# Each is printed as an unambiguous PASS or FAIL. If an asset needed to run a
# gate is missing, that gate FAILS with an explicit reason -- it is never
# silently skipped and never counted as a pass.
#
# bash 3.2 ONLY (macOS's stock /bin/bash). No `declare -A`, no `${var^^}`, no
# `mapfile`, no `&>>`. Assume nothing is installed beyond a stock macOS and the
# ffmpeg binary under test -- no python3 (a stock Mac without Xcode Command
# Line Tools pops a GUI install prompt for it and this script would hang
# forever waiting on a dialog nobody can see over SSH), no perl reliance, no
# GNU coreutils. Timing uses bash's own `time`/TIMEFORMAT (built in since
# bash 2.x). The audio comparison in gate 4 uses ffmpeg's own `astats` and
# `amix` filters instead of an external numeric library, for the same reason.
#
# Usage:
#   verify-on-mac.sh <workdir> [ffmpeg-name]
#
# <workdir> must contain the binary under test (default name "ffmpeg") plus
# the models/inputs below. Override any filename with the matching env var if
# yours are named differently; nothing here downloads a model for you.
#
#   ffmpeg                    the darwin-arm64 binary to test (positional arg 2 to rename)
#   WMODEL   (ggml-base.en.bin)        a real whisper.cpp GGML model
#   WINPUT   (jfk.wav)                  real speech, 16-bit PCM WAV
#   SS_MODEL (spleeter-2stems-f16.gguf) a real stemsplit GGUF model
#   SS_INPUT (input.mp3)                a music clip, at least ~35s long
#
# Every gate that needs an asset you did not provide FAILS with "asset
# missing", not a skip -- because a missing asset means the gate answers
# nothing, and this script's whole job is to never let that pass for a PASS.
#
# Output ends with a copy-pasteable summary block for issue #69.

set -uo pipefail

WORKDIR="${1:?usage: verify-on-mac.sh <workdir> [ffmpeg-name]}"
FF_NAME="${2:-ffmpeg}"
FF="${WORKDIR%/}/${FF_NAME}"

WMODEL_NAME="${WMODEL:-ggml-base.en.bin}"
WINPUT_NAME="${WINPUT:-jfk.wav}"
SS_MODEL_NAME="${SS_MODEL:-spleeter-2stems-f16.gguf}"
SS_INPUT_NAME="${SS_INPUT:-input.mp3}"

WMODEL_PATH="${WORKDIR%/}/${WMODEL_NAME}"
WINPUT_PATH="${WORKDIR%/}/${WINPUT_NAME}"
SS_MODEL_PATH="${WORKDIR%/}/${SS_MODEL_NAME}"
SS_INPUT_PATH="${WORKDIR%/}/${SS_INPUT_NAME}"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/nm-metal-verify.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

hr()   { printf '%s\n' "--------------------------------------------------------------------"; }
note() { printf 'ℹ️  %s\n' "$*"; }
ok()   { printf '✅ %s\n' "$*"; }
bad()  { printf '❌ %s\n' "$*"; }
warn() { printf '⚠️  %s\n' "$*"; }

# Overall gate verdicts. Plain variables, not an associative array (bash 3.2).
G1_STATUS="FAIL"; G1_REASON="not run"
G2_STATUS="FAIL"; G2_REASON="not run"
G3_STATUS="FAIL"; G3_REASON="not run"
G4A_STATUS="FAIL"; G4A_REASON="not run"   # identity
G4B_STATUS="FAIL"; G4B_REASON="not run"   # speed

T1_VERSION=""; T2_STEMSPLIT1=""; T3_STEMSPLIT2=""; SUBTRACTION=""; LOADED_IN_LINE=""; EMBED_LINE=""
G4A_DB=""
G4A_TXT_STATUS=""
G4B_CPU_T=""; G4B_METAL_T=""

FATAL() { bad "$*"; exit 1; }

# ---------------------------------------------------------------- step 0: host

hr
echo "Metal release-gate verification -- $(date '+%Y-%m-%d %H:%M:%S %Z')"
hr

UNAME_S="$(uname -s)"
UNAME_M="$(uname -m)"

if [ "${UNAME_S}" != "Darwin" ]; then
    FATAL "this script only runs on macOS (uname -s reported '${UNAME_S}'). It answers questions about Apple's Metal framework and cannot produce nonsense answers on another OS."
fi

if [ "${UNAME_M}" != "arm64" ]; then
    FATAL "this script only runs on Apple Silicon (uname -m reported '${UNAME_M}', not arm64). darwin-x86_64 deliberately does not get Metal (see the plan's Global Constraints) -- there is nothing for this script to verify on an Intel Mac, and running it there would test the wrong thing."
fi

# Belt and braces: uname -m can lie under certain shells/emulation layers.
# hw.optional.arm64 is the sysctl Apple's own code checks.
if command -v sysctl >/dev/null 2>&1; then
    ARM64_SYSCTL="$(sysctl -n hw.optional.arm64 2>/dev/null || echo '')"
    if [ -n "${ARM64_SYSCTL}" ] && [ "${ARM64_SYSCTL}" != "1" ]; then
        FATAL "uname -m says arm64 but sysctl hw.optional.arm64=${ARM64_SYSCTL} -- this does not look like real Apple Silicon. Refusing to produce results that would look like a pass."
    fi
fi

MAC_MODEL="$(sysctl -n hw.model 2>/dev/null || echo 'unknown model')"
MAC_CHIP="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'unknown chip')"
MAC_OS="$(sw_vers -productVersion 2>/dev/null || echo 'unknown macOS')"
note "host: ${MAC_MODEL} / ${MAC_CHIP} / macOS ${MAC_OS}"

if [ ! -e "${FF}" ]; then
    FATAL "no such binary: ${FF}"
fi
if [ ! -x "${FF}" ]; then
    FATAL "${FF} exists but is not executable (chmod +x it?)"
fi

FILE_INFO="$(file "${FF}" 2>/dev/null || echo '')"
echo "${FILE_INFO}"
case "${FILE_INFO}" in
    *arm64*) : ;;
    *) FATAL "${FF} does not look like an arm64 Mach-O binary ('file' said: ${FILE_INFO:-<nothing>}). Wrong artifact?" ;;
esac

# A quarantined or unsigned-and-rejected binary fails every gate below in a way
# that looks like a Metal problem but is not one. Rule that out first, loudly.
QUARANTINE="$(xattr -p com.apple.quarantine "${FF}" 2>/dev/null || echo '')"
if [ -n "${QUARANTINE}" ]; then
    warn "${FF} carries com.apple.quarantine (${QUARANTINE}). If the gates below fail with a launch/signature error rather than a Metal error, clear it first: xattr -d com.apple.quarantine '${FF}'"
fi

VERSION_OUTPUT="$("${FF}" -hide_banner -version 2>&1)"
VERSION_RC=$?
if [ ${VERSION_RC} -ne 0 ]; then
    echo "${VERSION_OUTPUT}"
    FATAL "'${FF} -version' exited ${VERSION_RC}. Nothing past this point can be trusted until the binary runs at all -- check codesign (codesign -dv '${FF}') and the quarantine attribute above before assuming this is a Metal problem."
fi
FF_VERSION_LINE="$(printf '%s\n' "${VERSION_OUTPUT}" | head -1)"
ok "binary launches: ${FF_VERSION_LINE}"

MISSING_ASSETS=""
[ -f "${WMODEL_PATH}" ]   || MISSING_ASSETS="${MISSING_ASSETS} ${WMODEL_PATH}(whisper model)"
[ -f "${WINPUT_PATH}" ]   || MISSING_ASSETS="${MISSING_ASSETS} ${WINPUT_PATH}(whisper speech input)"
[ -f "${SS_MODEL_PATH}" ] || MISSING_ASSETS="${MISSING_ASSETS} ${SS_MODEL_PATH}(stemsplit model)"
[ -f "${SS_INPUT_PATH}" ] || MISSING_ASSETS="${MISSING_ASSETS} ${SS_INPUT_PATH}(stemsplit/music input)"
if [ -n "${MISSING_ASSETS}" ]; then
    warn "missing asset(s):${MISSING_ASSETS}"
    warn "any gate that needs a missing asset below will FAIL with that reason -- it is not skipped."
fi

# ------------------------------------------------------------- shared helpers

# Real elapsed wall-clock seconds for one command, via bash's own `time`
# builtin (portable back to bash 2.x, no external timer needed).
wall_time() {   # wall_time <cmd...>   -> prints seconds to stdout, e.g. "0.842"
    local t
    TIMEFORMAT='%R'
    t=$( { time "$@" >/dev/null 2>"${TMP}/last_stderr"; } 2>&1 )
    printf '%s' "${t}"
}

backend_of() {   # backend_of <log-text>   -> "mtl" / "cpu" / "" (grep, case-sensitive)
    printf '%s\n' "$1" | grep -oE "backend '[a-z0-9_]+'" | head -1 | sed "s/backend '//;s/'//"
}

# ---------------------------------------------------------- gate 1: MSL compiles

hr
echo "GATE 1: the embedded MSL actually compiles (whisper, use_gpu=1, interactive session)"
hr

if [ ! -f "${WMODEL_PATH}" ] || [ ! -f "${WINPUT_PATH}" ]; then
    G1_STATUS="FAIL"; G1_REASON="asset missing (need ${WMODEL_NAME} and ${WINPUT_NAME} in ${WORKDIR})"
else
    G1_OUT="$("${FF}" -hide_banner -loglevel info -nostats -t 15 -i "${WINPUT_PATH}" -vn \
        -af "aresample=16000,aformat=sample_fmts=s16:channel_layouts=mono,whisper=model=${WMODEL_PATH}:language=en:queue=3:use_gpu=1,ametadata=mode=print" \
        -f null - 2>&1)"
    printf '%s\n' "${G1_OUT}" | grep -E "ggml backend|using embedded metal library|loaded in|lavfi.whisper.backend=" | sed 's/^/  /'

    EMBED_LINE="$(printf '%s\n' "${G1_OUT}" | grep -F 'using embedded metal library' | head -1)"
    LOADED_IN_LINE="$(printf '%s\n' "${G1_OUT}" | grep -oE 'loaded in [0-9.]+ sec' | head -1)"
    G1_BACKEND="$(backend_of "${G1_OUT}")"

    if [ -z "${EMBED_LINE}" ] || [ -z "${LOADED_IN_LINE}" ]; then
        G1_STATUS="FAIL"
        G1_REASON="ggml never printed 'using embedded metal library' / 'loaded in ... sec' -- the Metal device/library never initialised at all"
    elif [ "${G1_BACKEND}" != "mtl" ]; then
        G1_STATUS="FAIL"
        G1_REASON="use_gpu=1 did not select mtl (got backend '${G1_BACKEND:-<none>}') even though the library init lines appeared"
    else
        G1_STATUS="PASS"
        G1_REASON="ggml compiled and loaded the embedded MSL, backend reports 'mtl' (${LOADED_IN_LINE})"
    fi
fi

[ "${G1_STATUS}" = "PASS" ] && ok "GATE 1: ${G1_REASON}" || bad "GATE 1: ${G1_REASON}"

# ------------------------------------------------------- gate 2: compile cost

hr
echo "GATE 2: first-use compile cost -- the number that settles the dropped Task 2"
hr

if [ ! -f "${SS_MODEL_PATH}" ] || [ ! -f "${SS_INPUT_PATH}" ]; then
    G2_STATUS="FAIL"; G2_REASON="asset missing (need ${SS_MODEL_NAME} and ${SS_INPUT_NAME} in ${WORKDIR})"
else
    # T1: ffmpeg -version never builds a filtergraph, so never touches ggml's
    # registry at all -- the baseline with literally no compile in it.
    T1_VERSION="$(wall_time "${FF}" -hide_banner -version)"

    # T2: the run the owner actually does today -- stemsplit, use_gpu=0 -- in a
    # fresh process. Per the research (section 6), this pays the compile even
    # though it never asked for the GPU.
    STDOUT2="${TMP}/g2_run1.log"
    TIMEFORMAT='%R'
    T2_STEMSPLIT1=$( { time "${FF}" -hide_banner -loglevel info -nostats -t 1 -i "${SS_INPUT_PATH}" -vn \
        -af "stemsplit=model=${SS_MODEL_PATH}:stem=accompaniment:use_gpu=0" \
        -f null - >"${STDOUT2}" 2>&1; } 2>&1 )

    # T3: the exact same call again, in another fresh process -- shows whether
    # anything is cached ACROSS processes (ggml's own cache is per-process:
    # ggml-metal-context.m caches on the device object, which dies with the
    # process; this checks whether the OS/driver layer caches underneath that).
    STDOUT3="${TMP}/g2_run2.log"
    T3_STEMSPLIT2=$( { time "${FF}" -hide_banner -loglevel info -nostats -t 1 -i "${SS_INPUT_PATH}" -vn \
        -af "stemsplit=model=${SS_MODEL_PATH}:stem=accompaniment:use_gpu=0" \
        -f null - >"${STDOUT3}" 2>&1; } 2>&1 )

    RUN1_TEXT="$(cat "${STDOUT2}")"
    RUN2_TEXT="$(cat "${STDOUT3}")"
    echo "  ffmpeg -version (baseline, no compile possible) : ${T1_VERSION}s"
    echo "  stemsplit use_gpu=0, fresh process #1            : ${T2_STEMSPLIT1}s"
    echo "  stemsplit use_gpu=0, fresh process #2            : ${T3_STEMSPLIT2}s"

    RUN1_EMBED="$(printf '%s\n' "${RUN1_TEXT}" | grep -F 'using embedded metal library' | head -1)"
    RUN1_LOADED="$(printf '%s\n' "${RUN1_TEXT}" | grep -oE 'loaded in [0-9.]+ sec' | head -1)"
    RUN2_EMBED="$(printf '%s\n' "${RUN2_TEXT}" | grep -F 'using embedded metal library' | head -1)"
    RUN2_LOADED="$(printf '%s\n' "${RUN2_TEXT}" | grep -oE 'loaded in [0-9.]+ sec' | head -1)"

    echo "  ggml log, run #1: ${RUN1_EMBED:-<not printed>} / ${RUN1_LOADED:-<not printed>}"
    echo "  ggml log, run #2: ${RUN2_EMBED:-<not printed>} / ${RUN2_LOADED:-<not printed>}"

    if [ -z "${RUN1_EMBED}" ]; then
        # No Metal init on a use_gpu=0 run. This gate used to call that a
        # failure, because the research (section 6) believed such a run still
        # paid the ~6 s shader compile. It does not on this ggml version, and
        # that is the best possible answer to the Task 2 question: what a
        # CPU-only user pays for Metal being linked in is zero, not merely
        # small, so there is nothing to defer. README.md carried the same
        # stale claim and is corrected alongside this.
        #
        # Kept as an assertion rather than deleted: if a future ggml builds
        # the registry on the CPU path again, the cost returns and this is
        # where it surfaces -- see the else branch.
        G2_STATUS="PASS"
        G2_REASON="use_gpu=0 does not initialise Metal at all (baseline ${T1_VERSION}s, run #1 ${T2_STEMSPLIT1}s, run #2 ${T3_STEMSPLIT2}s) -- a CPU-only run pays nothing for Metal being linked in"
    else
        SUBTRACTION="$(awk -v a="${T1_VERSION}" -v b="${T2_STEMSPLIT1}" 'BEGIN{printf "%.3f", b-a}')"
        echo "  subtraction (run #1 - baseline)                  : ${SUBTRACTION}s  <-- the number a use_gpu=0 user pays for Metal being linked in"
        RUN3_VS_RUN1="$(awk -v a="${T2_STEMSPLIT1}" -v b="${T3_STEMSPLIT2}" 'BEGIN{printf "%.3f", b-a}')"
        echo "  run #2 - run #1                                  : ${RUN3_VS_RUN1}s  <-- ~0 means no cross-process caching; a big negative number means the OS/driver cached the compiled pipeline"

        VERDICT="$(awk -v s="${SUBTRACTION}" 'BEGIN{ if (s < 0.25) print "SMALL"; else if (s > 1.0) print "LARGE"; else print "BORDERLINE" }')"
        case "${VERDICT}" in
            SMALL)
                echo "  verdict: SMALL (<0.25s) -- small enough to close the Task 2 question for good. No deferral mechanism needed."
                ;;
            LARGE)
                echo "  verdict: LARGE (>1.0s) -- large enough that Task 2 (deferring registry construction on the stemsplit CPU path) should be reopened with this number as evidence."
                ;;
            *)
                echo "  verdict: BORDERLINE (0.25s-1.0s) -- not obviously negligible or obviously bad. This is a judgment call for the owner, not this script; report the raw number in the summary block below rather than a verdict."
                ;;
        esac
        # Reaching here means Metal DID initialise on a use_gpu=0 run, which
        # is the regression the branch above guards against. The size decides:
        # SMALL is noise, BORDERLINE is the owner's call and is reported rather
        # than judged here, LARGE is a real cost on the CPU path and fails so
        # that it cannot be merged without someone having seen the number.
        if [ "${VERDICT}" = "LARGE" ]; then
            G2_STATUS="FAIL"
        else
            G2_STATUS="PASS"
        fi
        G2_REASON="Metal initialised on a use_gpu=0 run (unexpected): baseline ${T1_VERSION}s, first run ${T2_STEMSPLIT1}s, subtraction ${SUBTRACTION}s (${VERDICT})"
    fi
fi

[ "${G2_STATUS}" = "PASS" ] && ok "GATE 2: ${G2_REASON}" || bad "GATE 2: ${G2_REASON}"

# --------------------------------------------- gate 3: daemon/SSH device selection

hr
echo "GATE 3: a device is selected outside an interactive GUI session (launchd, not Terminal.app)"
hr

if [ ! -f "${WMODEL_PATH}" ] || [ ! -f "${WINPUT_PATH}" ]; then
    G3_STATUS="FAIL"; G3_REASON="asset missing (need ${WMODEL_NAME} and ${WINPUT_NAME} in ${WORKDIR})"
elif ! command -v launchctl >/dev/null 2>&1; then
    G3_STATUS="FAIL"; G3_REASON="launchctl not found -- cannot construct a daemon context on this machine at all"
else
    G3_LABEL="com.nomercy.metal-gate3.$$"
    G3_WRAPPER="${TMP}/gate3-wrapper.sh"
    G3_OUT="${TMP}/gate3-output.log"
    G3_DONE="${TMP}/gate3-done"
    rm -f "${G3_DONE}"

    cat > "${G3_WRAPPER}" <<WRAPPER
#!/bin/bash
"${FF}" -hide_banner -loglevel info -nostats -t 15 -i "${WINPUT_PATH}" -vn \\
    -af "aresample=16000,aformat=sample_fmts=s16:channel_layouts=mono,whisper=model=${WMODEL_PATH}:language=en:queue=3:use_gpu=1,ametadata=mode=print" \\
    -f null - > "${G3_OUT}" 2>&1
: > "${G3_DONE}"
WRAPPER
    chmod +x "${G3_WRAPPER}"

    launchctl remove "${G3_LABEL}" >/dev/null 2>&1 || true
    if launchctl submit -l "${G3_LABEL}" -- /bin/bash "${G3_WRAPPER}" >/dev/null 2>"${TMP}/gate3-submit.err"; then
        WAITED=0
        while [ ! -e "${G3_DONE}" ] && [ ${WAITED} -lt 60 ]; do
            sleep 1
            WAITED=$((WAITED + 1))
        done
        launchctl remove "${G3_LABEL}" >/dev/null 2>&1 || true

        if [ ! -e "${G3_DONE}" ]; then
            G3_STATUS="FAIL"
            G3_REASON="the launchd job did not finish within 60s -- see ${G3_OUT} if it exists"
        else
            G3_TEXT="$(cat "${G3_OUT}" 2>/dev/null || echo '')"
            printf '%s\n' "${G3_TEXT}" | grep -E "ggml backend|using embedded metal library|MTLCreateSystemDefaultDevice|lavfi.whisper.backend=" | sed 's/^/  /'
            G3_BACKEND="$(backend_of "${G3_TEXT}")"
            if [ "${G3_BACKEND}" = "mtl" ]; then
                G3_STATUS="PASS"
                G3_REASON="a Metal device was selected from a launchd job with no GUI session attached (backend='mtl')"
            elif [ "${G3_BACKEND}" = "cpu" ]; then
                G3_STATUS="FAIL"
                G3_REASON="ran fine but fell back to cpu under launchd -- this is the MTLCreateSystemDefaultDevice()-returns-nil-with-no-window-server failure mode the research flagged as most likely. Metal cannot be relied on for a media-server daemon until this is fixed."
            else
                G3_STATUS="FAIL"
                G3_REASON="could not determine the backend from the launchd job's output (got '${G3_BACKEND:-<none>}') -- see ${G3_OUT}"
            fi
        fi
    else
        G3_STATUS="FAIL"
        G3_REASON="launchctl submit itself failed: $(cat "${TMP}/gate3-submit.err" 2>/dev/null)"
    fi
fi

[ "${G3_STATUS}" = "PASS" ] && ok "GATE 3: ${G3_REASON}" || bad "GATE 3: ${G3_REASON}"

# ------------------------------------------------- gate 4a: output matches CPU

hr
echo "GATE 4a: output matches the CPU path (same standard the Vulkan work used)"
hr

# Returns the literal string "-inf" for silence as well as a number. astats
# prints "RMS level dB: -inf" for a pure-silence stream, which the old
# [-0-9.]+ pattern could not match -- so a PERFECT null came back empty and
# gate 4a took that for "astats reported nothing" and failed. The best
# possible result was unreachable. Callers must test for "-inf" before doing
# arithmetic, because awk would coerce it to 0.
rms_dbfs() {   # rms_dbfs <wav>  -> "Overall RMS level dB" or "-inf"
    "${FF}" -hide_banner -nostats -loglevel info -i "$1" -af astats -f null - 2>&1 \
        | grep -oE "RMS level dB: (-inf|[-0-9.]+)" | tail -1 | awk '{print $NF}'
}

if [ ! -f "${SS_MODEL_PATH}" ] || [ ! -f "${SS_INPUT_PATH}" ]; then
    G4A_STATUS="FAIL"; G4A_REASON="asset missing (need ${SS_MODEL_NAME} and ${SS_INPUT_NAME} in ${WORKDIR})"
else
    CPU_WAV="${TMP}/g4_cpu.wav"
    MTL_WAV="${TMP}/g4_mtl.wav"

    CPU_LOG="$("${FF}" -hide_banner -loglevel info -nostats -y -t 30 -i "${SS_INPUT_PATH}" -vn \
        -af "stemsplit=model=${SS_MODEL_PATH}:stem=accompaniment:use_gpu=0" -f wav "${CPU_WAV}" 2>&1)"
    MTL_LOG="$("${FF}" -hide_banner -loglevel info -nostats -y -t 30 -i "${SS_INPUT_PATH}" -vn \
        -af "stemsplit=model=${SS_MODEL_PATH}:stem=accompaniment:use_gpu=1" -f wav "${MTL_WAV}" 2>&1)"

    CPU_BACKEND="$(backend_of "${CPU_LOG}")"
    MTL_BACKEND="$(backend_of "${MTL_LOG}")"
    echo "  cpu run backend: ${CPU_BACKEND:-<none>}   metal run backend: ${MTL_BACKEND:-<none>}"

    if [ "${MTL_BACKEND}" != "mtl" ]; then
        G4A_STATUS="FAIL"
        G4A_REASON="the use_gpu=1 run did not report backend='mtl' (got '${MTL_BACKEND:-<none>}') -- this comparison would prove nothing"
    elif [ ! -s "${CPU_WAV}" ] || [ ! -s "${MTL_WAV}" ]; then
        G4A_STATUS="FAIL"
        G4A_REASON="one of the two output files is empty -- a backend that produced no audio would trivially 'match' nothing, so this is a hard fail, not a pass by omission"
    else
        DIFF_WAV="${TMP}/g4_diff.wav"
        # Invert one input, then sum. `amix` does NOT honour a negative
        # weight: weights='1 -1' adds instead of subtracting, which is what
        # this gate did until now. Measured on two byte-identical files it
        # reports +6.0 dB -- exactly the 6.02 dB of doubling a signal. That is
        # the number issue #90 read as a Metal defect in stemsplit; it is in
        # fact the signature of the two outputs being IDENTICAL. The gate
        # failed hardest when the build was perfect.
        "${FF}" -hide_banner -loglevel error -y -i "${CPU_WAV}" -i "${MTL_WAV}" \
            -filter_complex "[1:a]volume=-1[inv];[0:a][inv]amix=inputs=2:weights='1 1':normalize=0:duration=shortest[out]" \
            -map "[out]" -f wav "${DIFF_WAV}" 2>&1

        SIG_DB="$(rms_dbfs "${CPU_WAV}")"
        DIFF_DB="$(rms_dbfs "${DIFF_WAV}")"
        if [ "${DIFF_DB}" = "-inf" ]; then
            # Cancelled to exact silence: the two outputs are bit-identical.
            G4A_STATUS="PASS"
            G4A_DB="-inf"
            G4A_REASON="stemsplit: cpu and mtl output null to exact silence -- bit-identical, the strongest result this gate can report"
        elif [ "${SIG_DB}" = "-inf" ]; then
            # The reference is silent, so a null would mean nothing at all.
            G4A_STATUS="FAIL"
            G4A_REASON="the cpu reference is pure silence -- the fixture produced no audio, so no comparison here proves anything"
        elif [ -z "${SIG_DB}" ] || [ -z "${DIFF_DB}" ]; then
            G4A_STATUS="FAIL"
            G4A_REASON="astats did not report an RMS level for the signal or the difference -- cannot compute a relative dB figure"
        else
            REL_DB="$(awk -v d="${DIFF_DB}" -v s="${SIG_DB}" 'BEGIN{printf "%.1f", d-s}')"
            G4A_DB="${REL_DB}"
            echo "  cpu signal: ${SIG_DB} dBFS   diff (cpu-metal): ${DIFF_DB} dBFS   relative: ${REL_DB} dB"
            THRESHOLD_OK="$(awk -v r="${REL_DB}" 'BEGIN{ print (r < -55) ? "1" : "0" }')"
            if [ "${THRESHOLD_OK}" = "1" ]; then
                G4A_STATUS="PASS"
                G4A_REASON="stemsplit: ${REL_DB} dB relative difference, under the -55 dB bar the Vulkan work used"
            else
                G4A_STATUS="FAIL"
                G4A_REASON="stemsplit: ${REL_DB} dB relative difference -- at or above the -55 dB bar the Vulkan work used. (Vulkan needed a second, relaxed comparison because of an FP16 accumulator quirk in one shader path -- if Metal has an equivalent, that is a real finding, not a bug in this script; investigate before shipping either way.)"
            fi
        fi
    fi

    # Whisper transcript identity: exact match required, same as the Vulkan gate.
    if [ -f "${WMODEL_PATH}" ] && [ -f "${WINPUT_PATH}" ]; then
        WH_CPU_LOG="$("${FF}" -hide_banner -loglevel info -nostats -t 20 -i "${WINPUT_PATH}" -vn \
            -af "aresample=16000,aformat=sample_fmts=s16:channel_layouts=mono,whisper=model=${WMODEL_PATH}:language=en:queue=3:use_gpu=0,ametadata=mode=print" \
            -f null - 2>&1)"
        WH_MTL_LOG="$("${FF}" -hide_banner -loglevel info -nostats -t 20 -i "${WINPUT_PATH}" -vn \
            -af "aresample=16000,aformat=sample_fmts=s16:channel_layouts=mono,whisper=model=${WMODEL_PATH}:language=en:queue=3:use_gpu=1,ametadata=mode=print" \
            -f null - 2>&1)"
        WH_CPU_TXT="$(printf '%s\n' "${WH_CPU_LOG}" | grep -oE 'lavfi\.whisper\.text=.*')"
        WH_MTL_TXT="$(printf '%s\n' "${WH_MTL_LOG}" | grep -oE 'lavfi\.whisper\.text=.*')"
        WH_MTL_BACKEND="$(backend_of "${WH_MTL_LOG}")"

        if [ -z "${WH_MTL_TXT}" ]; then
            G4A_TXT_STATUS="FAIL: the Metal whisper run produced no transcript at all -- two empty outputs would compare equal and prove nothing"
        elif [ "${WH_MTL_BACKEND}" != "mtl" ]; then
            G4A_TXT_STATUS="FAIL: the use_gpu=1 whisper run did not report backend='mtl' (got '${WH_MTL_BACKEND:-<none>}')"
        elif [ "${WH_CPU_TXT}" = "${WH_MTL_TXT}" ]; then
            G4A_TXT_STATUS="PASS: whisper transcript identical, cpu vs mtl"
        else
            G4A_TXT_STATUS="FAIL: whisper transcript DIFFERS between cpu and mtl -- a silently different transcript is a much bigger deal than a few dB of inaudible audio"
            G4A_STATUS="FAIL"
            G4A_REASON="${G4A_REASON}; also: whisper transcript differs cpu vs mtl"
        fi
        echo "  whisper transcript check: ${G4A_TXT_STATUS}"
    else
        echo "  whisper transcript check: FAIL: asset missing (need ${WMODEL_NAME} and ${WINPUT_NAME})"
        G4A_TXT_STATUS="FAIL: asset missing"
    fi
fi

[ "${G4A_STATUS}" = "PASS" ] && ok "GATE 4a: ${G4A_REASON}" || bad "GATE 4a: ${G4A_REASON}"

# ------------------------------------------------ gate 4b: actually beats CPU

hr
echo "GATE 4b: Metal actually beats the fixed-level NEON CPU build"
hr

if [ ! -f "${SS_MODEL_PATH}" ] || [ ! -f "${SS_INPUT_PATH}" ]; then
    G4B_STATUS="FAIL"; G4B_REASON="asset missing (need ${SS_MODEL_NAME} and ${SS_INPUT_NAME} in ${WORKDIR})"
else
    # Warm up the Metal path first so the one-time shader compile (gate 2's
    # number) doesn't get charged to this comparison -- we want steady-state
    # throughput, not compile latency.
    "${FF}" -hide_banner -loglevel error -nostats -t 1 -i "${SS_INPUT_PATH}" -vn \
        -af "stemsplit=model=${SS_MODEL_PATH}:stem=accompaniment:use_gpu=1" -f null - >/dev/null 2>&1

    SPEED_LOG_CPU="${TMP}/g4b_cpu.log"
    SPEED_LOG_MTL="${TMP}/g4b_mtl.log"
    TIMEFORMAT='%R'
    G4B_CPU_T=$( { time "${FF}" -hide_banner -loglevel info -nostats -t 30 -i "${SS_INPUT_PATH}" -vn \
        -af "stemsplit=model=${SS_MODEL_PATH}:stem=accompaniment:use_gpu=0" -f null - >"${SPEED_LOG_CPU}" 2>&1; } 2>&1 )
    G4B_METAL_T=$( { time "${FF}" -hide_banner -loglevel info -nostats -t 30 -i "${SS_INPUT_PATH}" -vn \
        -af "stemsplit=model=${SS_MODEL_PATH}:stem=accompaniment:use_gpu=1" -f null - >"${SPEED_LOG_MTL}" 2>&1; } 2>&1 )

    CPU_BACKEND_SPEED="$(backend_of "$(cat "${SPEED_LOG_CPU}")")"
    MTL_BACKEND_SPEED="$(backend_of "$(cat "${SPEED_LOG_MTL}")")"
    echo "  cpu   (backend=${CPU_BACKEND_SPEED:-<none>}): ${G4B_CPU_T}s over 30s of audio"
    echo "  metal (backend=${MTL_BACKEND_SPEED:-<none>}): ${G4B_METAL_T}s over 30s of audio"

    if [ "${MTL_BACKEND_SPEED}" != "mtl" ]; then
        G4B_STATUS="FAIL"
        G4B_REASON="the timed use_gpu=1 run did not report backend='mtl' (got '${MTL_BACKEND_SPEED:-<none>}') -- no speed comparison is meaningful without it"
    else
        FASTER="$(awk -v c="${G4B_CPU_T}" -v m="${G4B_METAL_T}" 'BEGIN{ print (m < c) ? "1" : "0" }')"
        SPEEDUP="$(awk -v c="${G4B_CPU_T}" -v m="${G4B_METAL_T}" 'BEGIN{ if (m>0) printf "%.2fx", c/m; else print "n/a" }')"
        if [ "${FASTER}" = "1" ]; then
            G4B_STATUS="PASS"
            G4B_REASON="metal (${G4B_METAL_T}s) beats cpu (${G4B_CPU_T}s), ${SPEEDUP}"
        else
            G4B_STATUS="FAIL"
            G4B_REASON="metal (${G4B_METAL_T}s) does NOT beat cpu (${G4B_CPU_T}s). Per the plan: if Metal does not beat CPU, this phase is not worth shipping."
        fi
    fi
fi

[ "${G4B_STATUS}" = "PASS" ] && ok "GATE 4b: ${G4B_REASON}" || bad "GATE 4b: ${G4B_REASON}"

# ------------------------------------------------------------------- summary

OVERALL="PASS"
for s in "${G1_STATUS}" "${G2_STATUS}" "${G3_STATUS}" "${G4A_STATUS}" "${G4B_STATUS}"; do
    [ "${s}" = "PASS" ] || OVERALL="FAIL"
done

hr
echo "=== METAL RELEASE GATES -- copy-paste into issue #69 ==="
echo "host: ${MAC_MODEL} / ${MAC_CHIP} / macOS ${MAC_OS}"
echo "binary: ${FF_VERSION_LINE}"
echo "date: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "---"
echo "Gate 1 (MSL compiles, interactive):        ${G1_STATUS} -- ${G1_REASON}"
echo "Gate 2 (first-use compile cost):           ${G2_STATUS} -- ${G2_REASON}"
echo "Gate 3 (device selected under launchd):    ${G3_STATUS} -- ${G3_REASON}"
echo "Gate 4a (output matches CPU):              ${G4A_STATUS} -- ${G4A_REASON}"
echo "         whisper transcript:               ${G4A_TXT_STATUS:-not run}"
echo "Gate 4b (Metal beats CPU):                 ${G4B_STATUS} -- ${G4B_REASON}"
echo "---"
fmt_s() { [ -n "${1:-}" ] && printf '%ss' "$1" || printf 'n/a'; }
echo "timings: baseline=$(fmt_s "${T1_VERSION:-}")  stemsplit#1=$(fmt_s "${T2_STEMSPLIT1:-}")  stemsplit#2=$(fmt_s "${T3_STEMSPLIT2:-}")  subtraction=$(fmt_s "${SUBTRACTION:-}")"
echo "stemsplit cpu=$(fmt_s "${G4B_CPU_T:-}")  metal=$(fmt_s "${G4B_METAL_T:-}")  (30s of audio)"
echo "audio relative dB (stemsplit, cpu vs metal): ${G4A_DB:-n/a}"
echo "---"
echo "OVERALL: ${OVERALL}"
echo "=== END SUMMARY ==="
hr

if [ "${OVERALL}" = "PASS" ]; then
    note "All four gates passed on this machine. This is evidence for the release decision, not the decision itself -- that belongs to the owner."
else
    note "At least one gate failed or could not be answered. Fix the cause (missing asset, code bug, or a real hardware finding) and re-run; do not ship on a partial result."
fi

[ "${OVERALL}" = "PASS" ]
exit $?
