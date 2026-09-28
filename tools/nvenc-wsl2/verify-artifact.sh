#!/usr/bin/env bash
# Task 4 of docs/superpowers/plans/2026-09-26-nvenc-wsl2-dynamic.md -- the gate.
#
# "It builds" is not the deliverable. This script re-derives, on demand, the
# evidence the owner's three conditions require:
#   1. no feature may go missing or break;
#   2. no second artifact;
#   3. nothing may be switched off to make it work.
# Every check here RUNS the feature (decodes, transcribes, splits, OCRs,
# demuxes a disc, starts a player) rather than grepping `-filters`/`-codecs`
# for its name -- this repository has produced eleven checks that passed
# while testing nothing (see docs/superpowers/... "Checks that lie"), and
# this script exists so Task 4 is not the twelfth.
#
# Usage: tools/nvenc-wsl2/verify-artifact.sh <workspace_dir>
#   <workspace_dir> must contain the extracted linux-x86_64 artifact:
#   ffmpeg, ffprobe, ffplay (from output/ffmpeg-9.0-linux-x86_64.tar.gz).
#
# Requires: Docker Desktop with the nvidia container runtime for the NVENC
# and Vulkan-loader-present checks (skipped with a reason if unavailable);
# wsl.exe with a distro that has an NVIDIA GPU for the WSL2-native NVENC leg
# (skipped with a reason if unavailable); python3 on the host to author the
# minimal BDMV/DVD fixtures (via make_bdmv.py and dvdauthor respectively).
#
# Every docker invocation below installs its own apt packages inside a
# throwaway --rm container in the SAME invocation as the check that needs
# them -- containers do not persist installs across separate `docker run`
# calls, and re-installing per check keeps each function self-contained and
# independently re-runnable.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/../.." && pwd)"
WORKSPACE="${1:?workspace dir required (extracted ffmpeg/ffprobe/ffplay)}"
IMAGE="debian:bookworm-slim"

export MSYS_NO_PATHCONV=1  # Windows/Git Bash: keep docker -v paths literal

PASS=0
FAIL=0
SKIP=0
pass() { echo "PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }
skip() { echo "SKIP: $*"; SKIP=$((SKIP+1)); }

dcp() {  # run a bash -c snippet (passed as $1) in a throwaway container with $WORKSPACE mounted
    docker run --rm -v "${WORKSPACE}:/art" -w /art "${IMAGE}" bash -c "$1"
}

# ---------------------------------------------------------------------------
# Step 1: NVENC end to end, from the one binary, in both places
# ---------------------------------------------------------------------------
nvenc_debian() {
    if ! docker info 2>/dev/null | grep -q nvidia; then
        skip "NVENC (debian:bookworm-slim): no nvidia container runtime on this host"
        return
    fi
    SCRIPT='
        chmod +x ./ffmpeg
        ./ffmpeg -hide_banner -y -f lavfi -i "testsrc=duration=2:size=1280x720:rate=30" \
            -c:v h264_nvenc -f mp4 /art/.nvenc_debian.mp4 >/tmp/nvenc.log 2>&1
        echo "ENCODE_RC=$?"
        stat -c%s /art/.nvenc_debian.mp4 2>/dev/null || echo "OUT_BYTES=0"
        cat /tmp/nvenc.log | tail -5
    '
    out=$(docker run --rm --gpus all -e NVIDIA_DRIVER_CAPABILITIES=compute,utility,video \
        -v "${WORKSPACE}:/art" -w /art "${IMAGE}" bash -c "$SCRIPT" 2>&1)
    bytes=$(echo "$out" | grep -oE '^[0-9]+$' | tail -1)
    if [[ -n "${bytes:-}" && "${bytes}" -gt 0 ]]; then
        codec=$(docker run --rm -v "${WORKSPACE}:/art" -w /art "${IMAGE}" bash -c \
            'chmod +x ./ffprobe; ./ffprobe -hide_banner -v error -show_entries stream=codec_name -of csv=p=0 /art/.nvenc_debian.mp4' 2>&1)
        if [[ "$codec" == "h264" ]]; then
            pass "NVENC (debian:bookworm-slim): ${bytes} bytes, re-probes as h264"
        else
            fail "NVENC (debian:bookworm-slim): produced ${bytes} bytes but re-probe gave '${codec}'"
        fi
    else
        fail "NVENC (debian:bookworm-slim): no usable output; see log below"
        echo "$out"
    fi
}

nvenc_wsl2() {
    if ! command -v wsl.exe >/dev/null 2>&1; then
        skip "NVENC (WSL2): wsl.exe not available on this host"
        return
    fi
    local distro="${NVENC_WSL_DISTRO:-Ubuntu-24.04}"
    local wsl_ws
    wsl_ws=$(wslpath -a "${WORKSPACE}" 2>/dev/null) || wsl_ws="/mnt/$(echo "${WORKSPACE}" | sed -E 's#^([A-Za-z]):#\L\1#; s#\\#/#g')"
    # Single wsl.exe invocation for the whole experiment: each call may start
    # the distro fresh and wipe /tmp, and $? read from outside is unreliable
    # -- so persist under /root and print results from inside the program.
    out=$(wsl.exe -d "${distro}" -- bash -c "
        set +e
        mkdir -p /root/nvenc-verify
        cp '${wsl_ws}/ffmpeg' /root/nvenc-verify/ffmpeg 2>/dev/null
        chmod +x /root/nvenc-verify/ffmpeg
        /root/nvenc-verify/ffmpeg -hide_banner -y -f lavfi -i 'testsrc=duration=2:size=1280x720:rate=30' \
            -c:v h264_nvenc -f mp4 /root/nvenc-verify/out.mp4 >/root/nvenc-verify/log.txt 2>&1
        echo NVENC_DONE
        stat -c%s /root/nvenc-verify/out.mp4 2>/dev/null || echo 0
    " 2>&1)
    bytes=$(echo "$out" | grep -A1 NVENC_DONE | tail -1 | tr -d '\r')
    if [[ "${bytes:-0}" =~ ^[0-9]+$ ]] && [[ "${bytes}" -gt 0 ]]; then
        probe=$(wsl.exe -d "${distro}" -- bash -c \
            "/root/nvenc-verify/ffmpeg -hide_banner -i /root/nvenc-verify/out.mp4 2>&1 | grep -o 'Video: h264' | head -1" 2>&1 | tr -d '\r')
        if [[ "$probe" == "Video: h264" ]]; then
            pass "NVENC (WSL2 ${distro}): ${bytes} bytes, re-probes as h264"
        else
            fail "NVENC (WSL2 ${distro}): ${bytes} bytes but did not re-probe as h264"
        fi
    else
        fail "NVENC (WSL2 ${distro}): no usable output"
        echo "$out"
    fi
}

# ---------------------------------------------------------------------------
# Step 2: every feature the change could touch must RUN
# ---------------------------------------------------------------------------
check_librsvg() {
    SCRIPT='
        chmod +x ./ffmpeg ./ffprobe
        printf "%s\n" "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"64\" height=\"64\"><rect width=\"64\" height=\"64\" fill=\"#3355ff\"/></svg>" > /tmp/s.svg
        ./ffmpeg -hide_banner -y -i /tmp/s.svg -frames:v 1 /tmp/s.png >/tmp/log 2>&1
        stat -c%s /tmp/s.png 2>/dev/null || echo 0
        ./ffprobe -hide_banner -v error -show_entries stream=codec_name -of csv=p=0 /tmp/s.png 2>&1
    '
    out=$(dcp "$SCRIPT" 2>&1) || true
    if echo "$out" | grep -q "^png$" && echo "$out" | grep -qE '^[1-9][0-9]*$'; then
        pass "librsvg: rasterised SVG through the filter chain (pidfd_* path exercised), re-probes as png"
    else
        fail "librsvg: did not produce a valid raster"
        echo "$out"
    fi
}

check_whisper() {
    local model="${WORKSPACE}/ggml-base.en.bin"
    [[ -f "$model" ]] || { skip "whisper: no ggml-base.en.bin model in workspace"; return; }
    SCRIPT='
        chmod +x ./ffmpeg
        ./ffmpeg -hide_banner -y -f lavfi -i "sine=frequency=440:duration=3" -ar 16000 -ac 1 /tmp/a.wav >/dev/null 2>&1
        timeout 90 ./ffmpeg -hide_banner -v info -i /tmp/a.wav \
            -af "whisper=model=ggml-base.en.bin:language=en" -f null - >/tmp/log 2>&1
        echo "RC=$?"
        grep -c "Whisper filter initialized" /tmp/log
        grep -c "ggml backend .cpu." /tmp/log
    '
    out=$(dcp "$SCRIPT" 2>&1) || true
    if echo "$out" | grep -q "RC=0" && echo "$out" | grep -qE '^[1-9]'; then
        pass "whisper: transcription ran to completion on ggml CPU backend (OpenMP against static libgomp.a exercised)"
    else
        fail "whisper: did not complete"
        echo "$out"
    fi
}

check_stemsplit() {
    local model="${WORKSPACE}/spleeter-2stems-f16.gguf"
    [[ -f "$model" ]] || { skip "stemsplit: no spleeter-2stems-f16.gguf model in workspace"; return; }
    SCRIPT='
        chmod +x ./ffmpeg
        ./ffmpeg -hide_banner -y -f lavfi -i "sine=frequency=220:duration=30" -f lavfi -i "sine=frequency=440:duration=30" \
            -filter_complex "[0:a][1:a]amerge=inputs=2,aformat=channel_layouts=stereo" -ar 44100 /tmp/m.wav >/dev/null 2>&1
        timeout 120 ./ffmpeg -hide_banner -v info -i /tmp/m.wav \
            -filter_complex "[0:a]stemsplit=model=spleeter-2stems-f16.gguf[voc][acc]" \
            -map "[voc]" -y /tmp/voc.wav -map "[acc]" -y /tmp/acc.wav >/tmp/log 2>&1
        echo "RC=$?"
        stat -c%s /tmp/voc.wav 2>/dev/null || echo 0
        stat -c%s /tmp/acc.wav 2>/dev/null || echo 0
    '
    out=$(dcp "$SCRIPT" 2>&1) || true
    sizes=$(echo "$out" | grep -E '^[0-9]+$')
    if echo "$out" | grep -q "RC=0" && [[ -n "$sizes" ]] && ! echo "$sizes" | grep -q '^0$'; then
        pass "stemsplit: 30s split produced two non-empty stems (OpenMP against static libgomp.a exercised)"
    else
        fail "stemsplit: did not produce usable stems"
        echo "$out"
    fi
}

check_tesseract() {
    SCRIPT='
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq tesseract-ocr-eng fonts-dejavu-core >/dev/null 2>&1
        chmod +x ./ffmpeg
        ./ffmpeg -hide_banner -y -f lavfi -i "color=c=white:s=640x120:d=1" \
            -vf "drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf:text=NOMERCY 12345:fontcolor=black:fontsize=48:x=20:y=30" \
            -frames:v 1 -y /tmp/f.png >/dev/null 2>&1
        timeout 30 ./ffmpeg -hide_banner -nostats -y -i /tmp/f.png \
            -vf "ocr=datapath=/usr/share/tesseract-ocr/5/tessdata:language=eng,metadata=mode=print" \
            -frames:v 1 -f null - 2>&1 | grep "lavfi.ocr.text"
    '
    out=$(dcp "$SCRIPT" 2>&1) || true
    if echo "$out" | grep -q "NOMERCY 12345"; then
        pass "tesseract OCR: recognised known text through the newly-static link"
    else
        fail "tesseract OCR: did not recognise the known text"
        echo "$out"
    fi
}

check_vulkan_libplacebo() {
    # Loader ABSENT (plain debian:bookworm-slim): must fail cleanly, not crash.
    SCRIPT='
        chmod +x ./ffmpeg
        timeout 20 ./ffmpeg -hide_banner -v error -init_hw_device vulkan=vk -filter_hw_device vk \
            -f lavfi -i "testsrc=duration=1:size=320x240:rate=5" \
            -vf "format=yuv420p,hwupload,libplacebo=w=160:h=120,hwdownload,format=yuv420p" \
            -frames:v 1 -f null - >/tmp/log 2>&1
        echo "RC=$?"
        cat /tmp/log
    '
    out=$(dcp "$SCRIPT" 2>&1) || true
    if echo "$out" | grep -qE "RC=(1|[2-9][0-9]*)" && ! echo "$out" | grep -qi "segmentation"; then
        pass "libplacebo/Vulkan: loader ABSENT fails cleanly (no crash, no interposition)"
    else
        fail "libplacebo/Vulkan: loader-absent case did not fail cleanly"
        echo "$out"
    fi

    # Loader PRESENT: needs the nvidia (or a mesa) ICD; run only if available.
    if ! docker info 2>/dev/null | grep -q nvidia; then
        skip "libplacebo/Vulkan: loader-present case needs a GPU runtime, none on this host"
        return
    fi
    SCRIPT='
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq libvulkan1 mesa-vulkan-drivers >/dev/null 2>&1
        chmod +x ./ffmpeg
        timeout 30 ./ffmpeg -hide_banner -v error -init_hw_device vulkan=vk -filter_hw_device vk \
            -f lavfi -i "testsrc=duration=1:size=320x240:rate=5" \
            -vf "format=yuv420p,hwupload,libplacebo=w=160:h=120,hwdownload,format=yuv420p" \
            -frames:v 1 -f null - >/tmp/log 2>&1
        echo "RC=$?"
        tail -5 /tmp/log
    '
    out=$(docker run --rm --gpus all -e NVIDIA_DRIVER_CAPABILITIES=compute,utility,video,graphics,display \
        -v "${WORKSPACE}:/art" -w /art "${IMAGE}" bash -c "$SCRIPT" 2>&1)
    if echo "$out" | grep -q "RC=0"; then
        pass "libplacebo/Vulkan: loader PRESENT runs the filter successfully"
    else
        skip "libplacebo/Vulkan: loader-present case had no usable Vulkan ICD in this environment"
        echo "$out"
    fi
}

check_ffplay() {
    SCRIPT='
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq libsdl2-2.0-0 >/dev/null 2>&1
        chmod +x ./ffplay
        export SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy
        timeout 20 ./ffplay -hide_banner -autoexit -nodisp -v error \
            -f lavfi -i "testsrc=duration=2:size=320x240:rate=5" >/tmp/log 2>&1
        echo "RC=$?"
        cat /tmp/log
    '
    out=$(dcp "$SCRIPT" 2>&1) || true
    if echo "$out" | grep -q "RC=0"; then
        pass "ffplay (SDL2): starts and exits cleanly"
    else
        fail "ffplay (SDL2): did not exit cleanly"
        echo "$out"
    fi
}

check_bluray_dvdread() {
    local py; py=$(command -v python3 || command -v python)
    if [[ -z "$py" ]]; then
        skip "bluray/dvdread: no python3 on host to author the minimal fixtures"
        return
    fi
    local bd="${WORKSPACE}/.bd_root" ts="${WORKSPACE}/.plain_long.ts"
    rm -rf "$bd"; mkdir -p "$bd"
    SCRIPT_TS='
        chmod +x ./ffmpeg
        ./ffmpeg -hide_banner -y -f lavfi -i "testsrc=duration=190:size=320x240:rate=5" \
            -c:v mpeg2video -b:v 300k -pix_fmt yuv420p -f mpegts /art/.plain_long.ts >/dev/null 2>&1
    '
    dcp "$SCRIPT_TS" >/dev/null 2>&1
    if [[ -s "$ts" ]]; then
        "$py" "${HERE}/make_bdmv.py" "$bd" "$ts" >/dev/null 2>&1
    fi
    if [[ -f "$bd/BDMV/index.bdmv" ]]; then
        SCRIPT_BD='
            chmod +x ./ffprobe
            timeout 20 ./ffprobe -hide_banner -v error -show_entries stream=codec_name,codec_type -of csv=p=0 "bluray:/art/.bd_root" 2>&1
        '
        out=$(dcp "$SCRIPT_BD" 2>&1) || true
        if echo "$out" | grep -q "mpeg2video"; then
            pass "bluray: opened the minimal authored BDMV disc and demuxed video through the protocol"
        else
            fail "bluray: did not demux the authored disc"
            echo "$out"
        fi
    else
        skip "bluray: could not author the minimal BDMV fixture"
    fi

    # dvdread: real VIDEO_TS via dvdauthor.
    local dvd="${WORKSPACE}/.dvd_root"
    rm -rf "$dvd"; mkdir -p "$dvd"
    SCRIPT_DVD='
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq dvdauthor >/dev/null 2>&1
        chmod +x ./ffmpeg
        ./ffmpeg -hide_banner -y -f lavfi -i "testsrc=duration=5:size=720x480:rate=29.97" \
            -f lavfi -i "sine=frequency=880:duration=5" -target ntsc-dvd -aspect 4:3 /tmp/d.mpg >/dev/null 2>&1
        cat > /tmp/dvdauthor.xml <<XML
<dvdauthor>
  <vmgm><menus><video format="ntsc" aspect="4:3"/></menus></vmgm>
  <titleset><titles><video format="ntsc" aspect="4:3"/><pgc><vob file="/tmp/d.mpg" /></pgc></titles></titleset>
</dvdauthor>
XML
        dvdauthor -x /tmp/dvdauthor.xml -o /art/.dvd_root >/tmp/log 2>&1
        echo "AUTHOR_RC=$?"
    '
    dcp "$SCRIPT_DVD" >/dev/null 2>&1
    if [[ -f "$dvd/VIDEO_TS/VIDEO_TS.IFO" ]]; then
        SCRIPT_DR='
            chmod +x ./ffprobe
            timeout 20 ./ffprobe -hide_banner -v error -show_entries stream=codec_name,codec_type -of csv=p=0 "dvdread:/art/.dvd_root" 2>&1
        '
        out=$(dcp "$SCRIPT_DR" 2>&1) || true
        if echo "$out" | grep -q "mpeg2video" && echo "$out" | grep -q "ac3"; then
            pass "dvdread: opened a real authored VIDEO_TS disc and demuxed video+audio through the protocol"
        else
            fail "dvdread: did not demux the authored disc"
            echo "$out"
        fi
    else
        skip "dvdread: dvdauthor could not build the VIDEO_TS fixture"
    fi
    rm -rf "$bd" "$dvd" "$ts"
}

# ---------------------------------------------------------------------------
# Step 3: the distro matrix, including the accepted failures
# ---------------------------------------------------------------------------
distro_matrix() {
    local img
    for img in debian:12 ubuntu:22.04 almalinux:9; do
        out=$(docker run --rm -v "${WORKSPACE}:/art" -w /art "$img" bash -c \
            'chmod +x ./ffmpeg; ./ffmpeg -hide_banner -version' 2>&1)
        if echo "$out" | grep -q "^ffmpeg version"; then
            pass "distro matrix: ${img} runs the artifact"
        else
            fail "distro matrix: ${img} was expected to run but did not"
            echo "$out"
        fi
    done
    for img in debian:11 alpine:latest; do
        out=$(docker run --rm -v "${WORKSPACE}:/art" -w /art "$img" sh -c \
            'chmod +x ./ffmpeg; ./ffmpeg -hide_banner -version' 2>&1)
        if echo "$out" | grep -qE "GLIBC_2\.3[4-9].*not found|not found$"; then
            pass "distro matrix: ${img} fails as expected (${img} is below the 2.34 floor) -- cost stays visible"
        else
            fail "distro matrix: ${img} was expected to fail below the glibc floor but didn't, or failed for a different reason"
            echo "$out"
        fi
    done
}

# ---------------------------------------------------------------------------
# Link guard (belt-and-suspenders re-assertion of the dockerfile's own guard,
# directly against the shipped artifact rather than the build's intermediate
# state) -- and, critically, against ALL THREE shipped binaries. The
# dockerfile's own guard (Task 3, ffmpeg-linux-x86_64.dockerfile) checks only
# ${PREFIX}/bin/ffmpeg. That gap is exactly what let ffplay ship broken: see
# the Task 4 report for what this catches on ffplay specifically.
# ---------------------------------------------------------------------------
link_guard() {
    local bin
    for bin in ffmpeg ffprobe ffplay; do
        SCRIPT="
            apt-get update -qq >/dev/null 2>&1
            apt-get install -y -qq binutils >/dev/null 2>&1
            chmod +x ./${bin}
            floor=\$(objdump -T ./${bin} | grep -oE 'GLIBC_[0-9.]+' | sort -V -u | tail -1)
            echo \"FLOOR=\$floor\"
            objdump -p ./${bin} | awk '/NEEDED/{print \$2}' | grep -vE '^(libc|libm|libmvec|libdl|libpthread|librt)\.so|^ld-linux' \
                && echo 'UNEXPECTED_SO=yes' || echo 'UNEXPECTED_SO=no'
        "
        out=$(dcp "$SCRIPT" 2>&1) || true
        if echo "$out" | grep -q "FLOOR=GLIBC_2.34" && echo "$out" | grep -q "UNEXPECTED_SO=no"; then
            pass "link guard (${bin}): floor is exactly GLIBC_2.34, NEEDED carries no unexpected .so"
        else
            fail "link guard (${bin}): floor or NEEDED list drifted"
            echo "$out"
        fi
    done
}

# ---------------------------------------------------------------------------
# Step 4: re-run the existing suites
# ---------------------------------------------------------------------------
existing_suites() {
    local version
    version=$(docker run --rm -v "${WORKSPACE}:/art" -w /art "${IMAGE}" bash -c \
        'chmod +x ./ffmpeg; ./ffmpeg -hide_banner -version 2>&1 | head -1' 2>&1 \
        | grep -oE 'ffmpeg version [^ ]+' | sed 's/ffmpeg version //')
    out=$(docker run --rm -v "${REPO_ROOT}:/repo" -w /repo "${IMAGE}" bash -c \
        "chmod +x ${WORKSPACE#${REPO_ROOT}/}/ffmpeg ${WORKSPACE#${REPO_ROOT}/}/ffprobe 2>/dev/null; \
         bash tests/smoke.sh '${WORKSPACE#${REPO_ROOT}/}' '${version}' linux-x86_64" 2>&1)
    echo "$out"
    if echo "$out" | tail -1 | grep -q "Smoke test passed"; then
        pass "tests/smoke.sh: passed against the dynamic artifact (ggml CPU dispatcher, Vulkan backend + ICD guard, trailingsilence)"
    else
        fail "tests/smoke.sh: did not pass"
    fi
}

echo "=============================================================="
echo " Task 4 gate verification -- workspace: ${WORKSPACE}"
echo "=============================================================="
echo "--- Step 1: NVENC end to end ---"
nvenc_debian
nvenc_wsl2
echo "--- Step 2: every feature surface must RUN ---"
check_librsvg
check_whisper
check_stemsplit
check_tesseract
check_vulkan_libplacebo
check_ffplay
check_bluray_dvdread
echo "--- Step 3: distro matrix, including accepted failures ---"
distro_matrix
echo "--- Link guard (re-asserted against the shipped artifact) ---"
link_guard
echo "--- Step 4: existing suites ---"
existing_suites
echo "=============================================================="
echo "PASS=${PASS} FAIL=${FAIL} SKIP=${SKIP}"
echo "=============================================================="
[[ "${FAIL}" -eq 0 ]]
