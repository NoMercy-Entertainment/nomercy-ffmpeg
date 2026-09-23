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

[[ ${fail} -eq 0 ]] && echo PASS || { echo FAILED; exit 1; }
'
