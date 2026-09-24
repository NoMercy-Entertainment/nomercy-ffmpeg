#!/bin/bash
# Issue #64's reproduction, re-run against a binary that has Vulkan compiled in.
#
# #64 was an exit hang on windows-x86_64: stemsplit finished its work and then
# never returned from process teardown. It was fixed before this branch started
# (commit b52078d, OpenBLAS worker threads capped) and verified at 20/20 clean
# runs on this project's own 16-core Windows host. ggml's Vulkan backend spawns
# driver threads that are torn down at exit, which is the same class of fault,
# so the check has to be re-run with Vulkan in the binary before this branch can
# claim it did not reopen #64.
#
# The reproduction protocol is the one that originally found the bug: 30 seconds
# of a real mp3 through stemsplit, each run under `timeout`, a run that outlives
# the timeout counted as hung. Nothing here is a benchmark - the per-run seconds
# are printed only so a run that is merely slow can be told apart from one that
# is stuck, and they are meaningless on any machine but the one they were taken
# on.
#
# Both halves matter and neither substitutes for the other:
#   * use_gpu=1  - a Vulkan device really is created and destroyed on every run,
#                  which is the new teardown path this branch introduces. The
#                  harness asserts the backend really was vulkan on every single
#                  run, so a machine that quietly fell back to the CPU cannot
#                  pass this as if it had exercised the GPU.
#   * default    - stemsplit's use_gpu defaults to 0, so this is what users
#                  actually ship with, and it is the configuration #64's
#                  original 20/20 was measured in.
#
# Usage:  bash tools/ggml-variants/exit-hang-test.sh <workdir> [ffmpeg-name] [runs] [timeout-s]
# <workdir> must hold ffmpeg(.exe), spleeter-2stems-f16.gguf and input.mp3 -
# the same inputs gpu-filter-test.sh uses.
set -eu
WORK="${1:?usage: exit-hang-test.sh <workdir> [ffmpeg-name] [runs] [timeout-s]}"
FF="${WORK}/${2:-ffmpeg.exe}"
RUNS="${3:-20}"
# Deliberately far above any plausible run time (the pre-Vulkan default run on
# this host is ~8 s). A "hang" has to be unambiguous, not a slow machine.
TMO="${4:-120}"

[[ -x ${FF} ]] || { echo "no such ffmpeg: ${FF}" >&2; exit 1; }
cd "${WORK}"
MODEL=spleeter-2stems-f16.gguf
[[ -f ${MODEL} ]] || { echo "no ${MODEL} in ${WORK}" >&2; exit 1; }
[[ -f input.mp3 ]] || { echo "no input.mp3 in ${WORK}" >&2; exit 1; }

fail=0

run_series() { # run_series <label> <filter-suffix> <expected-backend>
    local label="$1" suffix="$2" want="$3"
    local hung=0 nonzero=0 ok=0 wrong=0 i rc t0 t1 ms backend
    local lo="" hi="" total=0 all=""
    local logdir="${WORK}/hangtest-${label}"
    rm -rf "${logdir}" && mkdir -p "${logdir}"

    echo "== ${RUNS} stemsplit runs, ${label} (timeout ${TMO}s each) =="
    for ((i = 1; i <= RUNS; i++)); do
        t0=$(date +%s%N)
        set +e
        timeout -k 5 "${TMO}" "${FF}" -hide_banner -loglevel info -nostats -y \
            -t 30 -i input.mp3 -vn \
            -af "stemsplit=model=${MODEL}:stem=accompaniment${suffix}" \
            -f wav "${logdir}/out.wav" > "${logdir}/run-${i}.log" 2>&1
        rc=$?
        set -e
        t1=$(date +%s%N)
        ms=$(( (t1 - t0) / 1000000 ))
        # timeout reports 124 when it fired, 137 when the -k SIGKILL was what
        # actually stopped it. Both mean the process did not leave on its own.
        if [[ ${rc} -eq 124 || ${rc} -eq 137 ]]; then
            hung=$((hung + 1))
            echo "  run ${i}: HUNG (killed after ${ms} ms)"
        elif [[ ${rc} -ne 0 ]]; then
            nonzero=$((nonzero + 1))
            echo "  run ${i}: exit ${rc} after ${ms} ms"
            tail -3 "${logdir}/run-${i}.log" | sed "s/^/      /"
        else
            ok=$((ok + 1))
            # Kept, not discarded. These are NOT a benchmark and are worthless
            # off this machine -- what they are for is that a series which
            # passes in 0.9 s and one that passes in 90 s are not the same
            # result, and #64's fault class shows up as drift before it shows
            # up as a hang. They also make the two series visibly distinct
            # populations, which is a second, independent reason to believe the
            # GPU half was not silently running on the CPU.
            total=$((total + ms))
            all="${all}${ms} "
            [[ -z ${lo} || ${ms} -lt ${lo} ]] && lo=${ms}
            [[ -z ${hi} || ${ms} -gt ${hi} ]] && hi=${ms}
        fi
        # Asserted on every run, not once at the start: a binary that used the
        # GPU on run 1 and silently fell back afterwards would otherwise read as
        # 20 GPU runs.
        backend=$(grep -oE "stemsplit: ggml backend '[a-z0-9]+'" "${logdir}/run-${i}.log" | head -1 | sed "s/.*'\(.*\)'/\1/")
        if [[ ${backend} != "${want}" ]]; then
            wrong=$((wrong + 1))
            echo "  run ${i}: backend was '${backend:-<none>}', expected '${want}'"
        fi
    done

    echo "  ${label}: ${ok}/${RUNS} exited cleanly, ${hung} hung, ${nonzero} exited non-zero"
    echo "  ${label}: backend '${want}' on $((RUNS - wrong))/${RUNS} runs"
    if [[ ${ok} -gt 0 ]]; then
        echo "  ${label}: clean runs took min ${lo} ms, max ${hi} ms, mean $((total / ok)) ms (this machine only, not a benchmark)"
        echo "  ${label}: every clean run, in order: ${all}"
    fi
    [[ ${hung} -eq 0 ]]    || { echo "  FAIL: ${hung} run(s) failed to exit - this is issue #64's fault class"; fail=1; }
    [[ ${nonzero} -eq 0 ]] || { echo "  FAIL: ${nonzero} run(s) exited non-zero"; fail=1; }
    [[ ${wrong} -eq 0 ]]   || { echo "  FAIL: ${wrong} run(s) did not use the ${want} backend, so this series proves less than it claims"; fail=1; }
}

# GPU first: it is the series that can regress, so a host that runs out of
# patience still gets the answer that matters.
run_series gpu ":use_gpu=1" vulkan
run_series default "" cpu

if [[ ${fail} -eq 0 ]]; then
    echo "PASS: ${RUNS}/${RUNS} clean exits in both series"
else
    echo "FAILURES ABOVE"
    exit 1
fi
