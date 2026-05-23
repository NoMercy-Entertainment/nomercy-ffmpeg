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
TOTAL=0
PASSED=0
FAILED=0

TestRoot="${Workspace}/test_files"
SampleVideo="${TestRoot}/sample.mp4"
SampleAudio="${TestRoot}/sample.wav"
SampleImage="${TestRoot}/sample.png"
SampleSubs="${TestRoot}/test.ass"

rm -rf "${TestRoot}"
mkdir -p "${TestRoot}"

line() {
    local left="$1" right="$2"
    local left_len=$(printf '%s' "$left" | wc -m)
    local right_len=$(printf '%s' "$right" | wc -m)
    local gap=$((TOTAL_WIDTH_TEXT - left_len - right_len))
    [ $gap -lt 1 ] && gap=1
    printf "%s%*s%s\n" "$left" "$gap" "" "$right"
}

hr() {
    printf '%54s\n' | tr ' ' '-'
}

check_command() {
    if [[ ! -f ${Workspace}/ffmpeg ]]; then
        printf "%s\n" "x FFmpeg executable not found in current directory"
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
        output=$(eval "${Workspace}/ffmpeg -hide_banner -y -f lavfi -i \"testsrc=duration=10:size=1280x720:rate=30\" -c:v libx264 -crf 23 \"$SampleVideo\"" 2>&1)
        if [[ $? -ne 0 ]]; then line "     x Sample video" "[FAIL]"; echo "$output"; exit 1; fi
        line "     + Sample video" "[$(($(date +%s) - Start_Time))s]"
    fi

    if [[ ! -f "$SampleAudio" ]]; then
        Start_Time=$(date +%s)
        output=$(eval "${Workspace}/ffmpeg -hide_banner -y -f lavfi -i \"sine=frequency=1000:duration=10\" -c:a pcm_s16le \"$SampleAudio\"" 2>&1)
        if [[ $? -ne 0 ]]; then line "     x Sample audio" "[FAIL]"; echo "$output"; exit 1; fi
        line "     + Sample audio" "[$(($(date +%s) - Start_Time))s]"
    fi

    if [[ ! -f "$SampleImage" ]]; then
        Start_Time=$(date +%s)
        output=$(eval "${Workspace}/ffmpeg -hide_banner -y -f lavfi -i \"testsrc=duration=1:size=640x480:rate=1\" -frames:v 1 \"$SampleImage\"" 2>&1)
        if [[ $? -ne 0 ]]; then line "     x Sample image" "[FAIL]"; echo "$output"; exit 1; fi
        line "     + Sample image" "[$(($(date +%s) - Start_Time))s]"
    fi

    if [[ ! -f "$SampleSubs" ]]; then
        {
            echo "[Script Info]"
            echo "Title: Test Subtitle"
            echo "ScriptType: v4.00+"
            echo ""
            echo "[V4+ Styles]"
            echo "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding"
            echo "Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,10,0"
            echo ""
            echo "[Events]"
            echo "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text"
            echo "Dialogue: 0,0:00:01.00,0:00:05.00,Default,,0,0,0,,Test subtitle"
        } >$SampleSubs
        line "     + Sample subtitles" "[0s]"
    fi
}

run_test() {
    local name=$1 command=$2 expected_output=$3
    TOTAL=$((TOTAL + 1))
    name=$(echo $name | tr '[:lower:]' '[:upper:]')
    local num=$(printf "%2d" $TOTAL)
    local Start_Time=$(date +%s)

    test_output=$(eval "${Workspace}/ffmpeg $command" 2>&1)
    exit_code=$?
    local elapsed="$(($(date +%s) - Start_Time))s"

    if [[ $exit_code -eq 0 ]] && echo "$test_output" | grep -q "$expected_output"; then
        line " ${num}. + ${name}" "[${elapsed}]"
        PASSED=$((PASSED + 1))
    else
        line " ${num}. x ${name}" "[${elapsed}]"
        FAILED=$((FAILED + 1))
    fi
}

check_compiled() {
    local name=$1 type=$2 symbol=$3
    TOTAL=$((TOTAL + 1))
    name=$(echo $name | tr '[:lower:]' '[:upper:]')
    local num=$(printf "%2d" $TOTAL)

    local list_output
    list_output=$(eval "${Workspace}/ffmpeg -hide_banner -${type}" 2>&1)

    if echo "$list_output" | grep -q "$symbol"; then
        line " ${num}. + ${name}" "[compiled]"
        PASSED=$((PASSED + 1))
    else
        line " ${num}. x ${name}" "[missing]"
        FAILED=$((FAILED + 1))
    fi
}

# ==============================================================
hr
printf "%s\n" "  NoMercy FFmpeg Test Suite"
hr

check_command
generate_samples
hr

run_test "version" "-version" "ffmpeg version"
run_test "libx264" "-y -i ${SampleVideo} -c:v libx264 ${TestRoot}/test_h264.mp4" "x264"
run_test "libx265" "-y -i ${SampleVideo} -c:v libx265 ${TestRoot}/test_h265.mp4" "x265"
run_test "libvpx" "-y -i ${SampleVideo} -c:v libvpx-vp9 -frames:v 1 ${TestRoot}/test_vp9.webm" "vp9"
run_test "libaom" "-y -i ${SampleVideo} -c:v libaom-av1 -frames:v 1 ${TestRoot}/test_av1.mkv" "av1"
run_test "libtheora" "-y -i ${SampleVideo} -c:v libtheora -frames:v 1 ${TestRoot}/test_theora.ogv" "theora"
run_test "libfdk_aac" "-y -i ${SampleAudio} -c:a libfdk_aac ${TestRoot}/test_aac.m4a" "aac"
run_test "libopus" "-y -i ${SampleAudio} -c:a libopus ${TestRoot}/test_opus.opus" "opus"
run_test "libmp3lame" "-y -i ${SampleAudio} -c:a libmp3lame ${TestRoot}/test_mp3.mp3" "mp3"
run_test "libwebp" "-y -i ${SampleImage} -c:v libwebp -f webp ${TestRoot}/test_webp.webp" "webp"
run_test "libopenjpeg" "-y -i ${SampleImage} -c:v libopenjpeg ${TestRoot}/test_jp2.jp2" "openjpeg"
run_test "libass" "-y -i ${SampleVideo} -vf \"ass=${SampleSubs}\" ${TestRoot}/test_ass.mp4" "ass"
run_test "auto_mkdir" "-y -f lavfi -i \"testsrc=duration=1:size=320x240:rate=1\" -frames:v 1 ${TestRoot}/subdir_test/nested/output.png" "output.png"

hr

check_compiled "vobsub muxer" "muxers" "vobsub"
check_compiled "spritevtt muxer" "muxers" "spritevtt"
check_compiled "chapter_vtt muxer" "muxers" "chapters_vtt"
check_compiled "ocr_subtitle encoder" "encoders" "ocr_subtitle"
check_compiled "libbluray" "protocols" "bluray"
check_compiled "libfribidi" "version" "fribidi"
check_compiled "libsrt" "version" "srt"
check_compiled "libxml2" "version" "xml"
check_compiled "libdav1d" "decoders" "dav1d"
check_compiled "librav1e" "encoders" "rav1e"

OS_TYPE="$(uname -s)"
case "$OS_TYPE" in
    Darwin)
        check_compiled "videotoolbox h264" "encoders" "h264_videotoolbox"
        check_compiled "videotoolbox hevc" "encoders" "hevc_videotoolbox"
        ;;
    Linux)
        check_compiled "nvenc" "encoders" "h264_nvenc"
        check_compiled "vaapi" "encoders" "h264_vaapi"
        ;;
esac
check_compiled "amf" "encoders" "h264_amf"

hr
line " Results:" "${PASSED}/${TOTAL} passed"
if [ ${FAILED} -gt 0 ]; then
    line " FAILED:" "${FAILED}"
fi
hr
echo ""

rm -rf "${TestRoot}"

if [ "${FAILED}" -gt 0 ]; then exit 1; fi
exit 0
