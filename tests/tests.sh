#!/bin/bash

Workspace="$1"

if [[ -z "$Workspace" ]]; then
    echo "Error: Workspace path is required." >&2
    exit 1
fi

if [[ -L "$Workspace" ]]; then
    echo "Error: Workspace path cannot be a symbolic link." >&2
    exit 1
fi

TOTAL_WIDTH_TEXT=54
REQUIRED_TOTAL=0
REQUIRED_PASSED=0
REQUIRED_FAILED=0
HW_TOTAL=0
HW_PASSED=0
HW_UNAVAILABLE=0

TestRoot="${Workspace}/test_files"
SampleVideo="${TestRoot}/sample.mp4"
SampleAudio="${TestRoot}/sample.wav"
SampleImage="${TestRoot}/sample.png"
SampleSubs="${TestRoot}/test.ass"

# Cleanup and create test directory
rm -rf "${TestRoot}"
mkdir -p "${TestRoot}"

text_with_padding() {
    local text_before=$1
    local text_after=$2
    local extra_padding=${3:-0}
    local text_length=$((${#text_before} + ${#text_after}))
    local padding=$((TOTAL_WIDTH_TEXT - text_length - extra_padding))
    if [ $padding -lt 1 ]; then padding=1; fi
    printf "%s%*s%s\n" "$text_before" "$padding" " " "$text_after"
}

check_command() {
    if [[ ! -f ${Workspace}/ffmpeg ]]; then
        printf "%s\n" "❌ FFmpeg executable not found in current directory"
        exit 1
    fi
    if [[ ! -x ${Workspace}/ffmpeg ]]; then
        chmod +x ${Workspace}/ffmpeg
    fi
}

generate_samples() {
    local Total_Count=0
    local Current_Count=0
    local Start_Time End_Time

    [[ ! -f "$SampleVideo" ]] && ((Total_Count++))
    [[ ! -f "$SampleAudio" ]] && ((Total_Count++))
    [[ ! -f "$SampleImage" ]] && ((Total_Count++))
    [[ ! -f "$SampleSubs" ]] && ((Total_Count++))

    if [[ ! -f "$SampleVideo" ]]; then
        Start_Time=$(date +%s)
        Current_Count=$((Current_Count + 1))
        text_with_padding "📹 Generating sample video" "[$Current_Count/$Total_Count]" 1
        output=$(eval "${Workspace}/ffmpeg -hide_banner -y -f lavfi -i \"testsrc=duration=10:size=1280x720:rate=30\" -c:v libx264 -crf 23 \"$SampleVideo\"" 2>&1)
        exit_code=$?
        End_Time=$(date +%s)
        if [[ $exit_code -ne 0 ]]; then
            text_with_padding "❌ Error generating sample video" "[$((End_Time - Start_Time))s]" 1
            echo "$output"
            exit 1
        fi
        text_with_padding "✅ Sample video generated" "[$((End_Time - Start_Time))s]" 1
    fi

    if [[ ! -f "$SampleAudio" ]]; then
        Start_Time=$(date +%s)
        Current_Count=$((Current_Count + 1))
        text_with_padding "🔊 Generating sample audio" "[$Current_Count/$Total_Count]" 1
        output=$(eval "${Workspace}/ffmpeg -hide_banner -y -f lavfi -i \"sine=frequency=1000:duration=10\" -c:a pcm_s16le \"$SampleAudio\"" 2>&1)
        exit_code=$?
        End_Time=$(date +%s)
        if [[ $exit_code -ne 0 ]]; then
            text_with_padding "❌ Error generating sample audio" "[$((End_Time - Start_Time))s]" 1
            echo "$output"
            exit 1
        fi
        text_with_padding "✅ Sample audio generated" "[$((End_Time - Start_Time))s]" 1
    fi

    if [[ ! -f "$SampleImage" ]]; then
        Start_Time=$(date +%s)
        Current_Count=$((Current_Count + 1))
        text_with_padding "🖼️ Generating sample image" "[$Current_Count/$Total_Count]"
        output=$(eval "${Workspace}/ffmpeg -hide_banner -y -f lavfi -i \"testsrc=duration=1:size=640x480:rate=1\" -frames:v 1 \"$SampleImage\"" 2>&1)
        exit_code=$?
        End_Time=$(date +%s)
        if [[ $exit_code -ne 0 ]]; then
            text_with_padding "❌ Error generating sample image" "[$((End_Time - Start_Time))s]" 1
            echo "$output"
            exit 1
        fi
        text_with_padding "✅ Sample image generated" "[$((End_Time - Start_Time))s]" 1
    fi

    if [[ ! -f "$SampleSubs" ]]; then
        Start_Time=$(date +%s)
        Current_Count=$((Current_Count + 1))
        text_with_padding "📝 Generating sample subtitles" "[$Current_Count/$Total_Count]" 1
        {
            echo -e "[Script Info]"
            echo -e "Title: Test Subtitle"
            echo -e "ScriptType: v4.00+"
            echo -e ""
            echo -e "[V4+ Styles]"
            echo -e "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding"
            echo -e "Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,10,0"
            echo -e ""
            echo -e "[Events]"
            echo -e "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text"
            echo -e "Dialogue: 0,0:00:01.00,0:00:05.00,Default,,0,0,0,,Test subtitle"
        } >$SampleSubs
        End_Time=$(date +%s)
        text_with_padding "✅ Sample subtitles generated" "[$((End_Time - Start_Time))s]" 1
    fi

    if [ $Total_Count -gt 0 ]; then
        printf "%${TOTAL_WIDTH_TEXT}s\n" | tr ' ' '-'
    fi
}

# Required test — failure = broken build
run_test() {
    local name=$1
    local command=$2
    local expected_output=$3
    local test_output exit_code

    REQUIRED_TOTAL=$((REQUIRED_TOTAL + 1))
    name=$(echo $name | tr '[:lower:]' '[:upper:]')

    text_with_padding "🧪 Testing ${name}" "[${REQUIRED_TOTAL}]" 1
    Start_Time=$(date +%s)

    test_output=$(eval "${Workspace}/ffmpeg $command" 2>&1)
    exit_code=$?
    End_Time=$(date +%s)
    local elapsed="$((End_Time - Start_Time))s"

    if [[ $exit_code -eq 0 ]] && echo "$test_output" | grep -q "$expected_output"; then
        text_with_padding "✅ ${name} passed" "[${elapsed}]" 1
        REQUIRED_PASSED=$((REQUIRED_PASSED + 1))
    else
        text_with_padding "❌ ${name} FAILED" "[${elapsed}]" 1
        REQUIRED_FAILED=$((REQUIRED_FAILED + 1))
    fi
}

# Hardware test — failure = no GPU, not a bug
run_hw_test() {
    local name=$1
    local command=$2
    local expected_output=$3
    local test_output exit_code

    HW_TOTAL=$((HW_TOTAL + 1))
    name=$(echo $name | tr '[:lower:]' '[:upper:]')

    text_with_padding "🔌 Testing ${name}" "[${HW_TOTAL}]" 1
    Start_Time=$(date +%s)

    test_output=$(eval "${Workspace}/ffmpeg $command" 2>&1)
    exit_code=$?
    End_Time=$(date +%s)
    local elapsed="$((End_Time - Start_Time))s"

    if [[ $exit_code -eq 0 ]] && echo "$test_output" | grep -q "$expected_output"; then
        text_with_padding "✅ ${name} passed" "[${elapsed}]" 1
        HW_PASSED=$((HW_PASSED + 1))
    else
        text_with_padding "➖ ${name} unavailable" "[${elapsed}]" 1
        HW_UNAVAILABLE=$((HW_UNAVAILABLE + 1))
    fi
}

# ══════════════════════════════════════════════════════════════
# Main execution
# ══════════════════════════════════════════════════════════════

printf "%${TOTAL_WIDTH_TEXT}s\n" | tr ' ' '-'
printf "%s\n" "        _   _       __  __                      "
printf "%s\n" "       | \ | | ___ |  \/  | ___ _ __ ___ _   _  "
printf "%s\n" "       |  \| |/ _ \| |\/| |/ _ \ '__/ __| | | | "
printf "%s\n" "       | |\  | (_) | |  | |  __/ | | (__| |_| | "
printf "%s\n" "       |_| \_|\___/|_|  |_|\___|_|  \___|\__, | "
printf "%s\n" "         _____ _____ __  __ ____  _____ _|___/  "
printf "%s\n" "        |  ___|  ___|  \/  |  _ \| ____/ ___|   "
printf "%s\n" "        | |_  | |_  | |\/| | |_) |  _|| |  _    "
printf "%s\n" "        |  _| |  _| | |  | |  __/| |__| |_| |   "
printf "%s\n" "        |_|   |_|   |_|  |_|_|   |_____\____|   "
printf "%s\n" ""
printf "%${TOTAL_WIDTH_TEXT}s\n" | tr ' ' '-'

check_command
generate_samples

# ── Required tests (failures = broken build) ─────────────────
printf "%${TOTAL_WIDTH_TEXT}s\n" | tr ' ' '-'
text_with_padding "🔒 Required tests" "(must pass)"
printf "%${TOTAL_WIDTH_TEXT}s\n" | tr ' ' '-'

run_test "version" "-version" "ffmpeg version"

# Video codecs
run_test "libx264" "-y -i ${SampleVideo} -c:v libx264 ${TestRoot}/test_h264.mp4" "x264"
run_test "libx265" "-y -i ${SampleVideo} -c:v libx265 ${TestRoot}/test_h265.mp4" "x265"
run_test "libvpx" "-y -i ${SampleVideo} -c:v libvpx-vp9 ${TestRoot}/test_vp9.webm" "vp9"
run_test "libaom" "-y -i ${SampleVideo} -c:v libaom-av1 ${TestRoot}/test_av1.mkv" "av1"
run_test "libtheora" "-y -i ${SampleVideo} -c:v libtheora ${TestRoot}/test_theora.ogv" "theora"

# Audio codecs
run_test "libfdk_aac" "-y -i ${SampleAudio} -c:a libfdk_aac ${TestRoot}/test_aac.m4a" "aac"
run_test "libopus" "-y -i ${SampleAudio} -c:a libopus ${TestRoot}/test_opus.opus" "opus"
run_test "libmp3lame" "-y -i ${SampleAudio} -c:a libmp3lame ${TestRoot}/test_mp3.mp3" "mp3"

# Image codecs
run_test "libwebp" "-y -i ${SampleImage} -c:v libwebp ${TestRoot}/test_webp.webp" "webp"
run_test "libopenjpeg" "-y -i ${SampleImage} -c:v libopenjpeg ${TestRoot}/test_jp2.jp2" "openjpeg"

# Subtitle codecs
run_test "libass" "-y -i ${SampleVideo} -vf \"ass=${SampleSubs}\" ${TestRoot}/test_ass.mp4" "ass"
run_test "vobsub_muxer" "-hide_banner -muxers" "vobsub"
run_test "spritevtt_muxer" "-hide_banner -muxers" "spritevtt"
run_test "chapters_vtt_muxer" "-hide_banner -muxers" "chapters_vtt"

# Auto-create directories
run_test "auto_mkdir" "-y -f lavfi -i \"testsrc=duration=1:size=320x240:rate=1\" -frames:v 1 ${TestRoot}/subdir_test/nested/output.png" "output.png"

# Library presence
run_test "libbluray" "-hide_banner -protocols | grep bluray" "bluray"
run_test "libdvdread" "-hide_banner -version | grep dvdread" "dvdread"
run_test "libcdio" "-hide_banner -version | grep cdio" "cdio"
run_test "libfribidi" "-hide_banner -version | grep fribidi" "fribidi"
run_test "libsrt" "-hide_banner -version | grep srt" "srt"
run_test "libxml2" "-hide_banner -version | grep xml" "xml"
run_test "libdav1d" "-hide_banner -decoders" "dav1d"
run_test "librav1e" "-hide_banner -encoders" "rav1e"
run_test "ocr_subtitle" "-hide_banner -encoders" "ocr_subtitle"

# ── Hardware tests (failures = no GPU, not a bug) ────────────
printf "%${TOTAL_WIDTH_TEXT}s\n" | tr ' ' '-'
text_with_padding "🔌 Hardware tests" "(allowed to fail)"
printf "%${TOTAL_WIDTH_TEXT}s\n" | tr ' ' '-'

run_hw_test "NVENC" "-y -i ${SampleVideo} -c:v h264_nvenc ${TestRoot}/test_nvenc.mp4" "nvenc"
run_hw_test "VPL" "-y -i ${SampleVideo} -c:v h264_vpl ${TestRoot}/test_vpl.mp4" "vpl"
run_hw_test "AMF" "-y -i ${SampleVideo} -c:v h264_amf ${TestRoot}/test_amf.mp4" "amf"

# ── Summary ──────────────────────────────────────────────────
printf "%${TOTAL_WIDTH_TEXT}s\n" | tr ' ' '-'
text_with_padding "📊 Required:" "${REQUIRED_PASSED}/${REQUIRED_TOTAL} passed"
if [ ${REQUIRED_FAILED} -gt 0 ]; then
    text_with_padding "   ❌ Failures:" "${REQUIRED_FAILED}"
fi
text_with_padding "📊 Hardware:" "${HW_PASSED}/${HW_TOTAL} available"
printf "%${TOTAL_WIDTH_TEXT}s\n" | tr ' ' '-'
echo ""

# cleanup
rm -rf "${TestRoot}"

# Only required failures cause a non-zero exit
if [ "${REQUIRED_FAILED}" -gt 0 ]; then
    exit 1
fi
exit 0
