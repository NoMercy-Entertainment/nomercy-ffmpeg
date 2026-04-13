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
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

TestRoot="${Workspace}/test_files"
SampleVideo="${TestRoot}/sample.mp4"
SampleAudio="${TestRoot}/sample.wav"
SampleImage="${TestRoot}/sample.png"
SampleSubs="${TestRoot}/test.ass"

# Cleanup and create test directory
rm -rf "${TestRoot}"
mkdir -p "${TestRoot}"

get_test_runs_count() {
    local searchString="$1"
    local filePath="$0"
    local fileContent
    local matches
    local m_count
    fileContent=$(<"$filePath")
    _matches=$(grep -o "$searchString" <<<"$fileContent")
    matches_count=$(echo "$_matches" | wc -l)
    if [ "$matches_count" -gt 0 ]; then
        matches_count=$((matches_count - 1))
    fi
    echo "$matches_count"
}

TOTAL_RUNS=$(get_test_runs_count 'run_test "')

generate_samples() {
    local Total_Count=0
    local Current_Count=0
    local Start_Time End_Time

    # Count needed samples
    [[ ! -f "$SampleVideo" ]] && ((Total_Count++))
    [[ ! -f "$SampleAudio" ]] && ((Total_Count++))
    [[ ! -f "$SampleImage" ]] && ((Total_Count++))
    [[ ! -f "$SampleSubs" ]] && ((Total_Count++))

    # Generate samples
    if [[ ! -f "$SampleVideo" ]]; then
        Start_Time=$(date +%s)
        Current_Count=$((Current_Count + 1))
        text_with_padding "📹 Generating sample video" "[$Current_Count/$Total_Count]" 1
        ffmpeg_command="-hide_banner -y -f lavfi -i \"testsrc=duration=10:size=1280x720:rate=30\" -c:v libx264 -crf 23 \"$SampleVideo\""
        output=$(eval "${Workspace}/ffmpeg $ffmpeg_command" 2>&1)
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
        ffmpeg_command="-hide_banner -y -f lavfi -i \"sine=frequency=1000:duration=10\" -c:a pcm_s16le \"$SampleAudio\""
        output=$(eval "${Workspace}/ffmpeg $ffmpeg_command" 2>&1)
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
        ffmpeg_command="-hide_banner -y -f lavfi -i \"testsrc=duration=1:size=640x480:rate=1\" -frames:v 1 \"$SampleImage\""
        output=$(eval "${Workspace}/ffmpeg $ffmpeg_command" 2>&1)
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
        printf "%${TOTAL_WIDTH_TEXT}s\n" | tr ' ' '-' # Print a horizontal line
    fi
}

text_with_padding() {
    local text_before=$1
    local text_after=$2
    local extra_padding=${3:-0}
    local text_length=$((${#text_before} + ${#text_after}))
    local padding=$((TOTAL_WIDTH_TEXT - text_length - extra_padding))
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

run_test() {
    local name=$1
    local command=$2
    local expected_output=$3
    local test_output
    local exit_code

    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    name=$(echo $name | tr '[:lower:]' '[:upper:]')

    text_with_padding "🧪 Testing ${name}" "[${TOTAL_TESTS}/${TOTAL_RUNS}]" 1
    Start_Time=$(date +%s)

    test_output=$(eval "${Workspace}/ffmpeg $command" 2>&1)
    exit_code=$?
    if [[ $exit_code -eq 0 ]] && echo "$test_output" | grep -q "$expected_output"; then
        End_Time=$(date +%s)
        text_with_padding "✅ ${name} test passed" "[$((End_Time - Start_Time))s]" 1
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        End_Time=$(date +%s)
        text_with_padding "❌ ${name} test failed" "[$((End_Time - Start_Time))s]" 1
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
}

# Main execution
printf "%${TOTAL_WIDTH_TEXT}s\n" | tr ' ' '-' # Print a horizontal line
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
printf "%${TOTAL_WIDTH_TEXT}s\n" | tr ' ' '-' # Print a horizontal line

check_command
generate_samples

# Basic tests
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

# Hardware acceleration (may fail if no hardware support)
run_test "NVENC" "-y -i ${SampleVideo} -c:v h264_nvenc ${TestRoot}/test_nvenc.mp4" "nvenc"
run_test "VPL" "-y -i ${SampleVideo} -c:v h264_vpl ${TestRoot}/test_vpl.mp4" "vpl"
run_test "AMF" "-y -i ${SampleVideo} -c:v h264_amf ${TestRoot}/test_amf.mp4" "amf"

# Additional format tests
run_test "libbluray" "-hide_banner -protocols | grep bluray" "bluray"
run_test "libdvdread" "-hide_banner -version | grep dvdread" "dvdread"
run_test "libcdio" "-hide_banner -version | grep cdio" "cdio"
run_test "libfribidi" "-hide_banner -version | grep fribidi" "fribidi"
run_test "libsrt" "-hide_banner -version | grep srt" "srt"
run_test "libxml2" "-hide_banner -version | grep xml" "xml"

# AV1 codec tests
run_test "libdav1d" "-hide_banner -decoders" "dav1d"
run_test "librav1e" "-hide_banner -encoders" "rav1e"

# OCR subtitle encoder
run_test "ocr_subtitle" "-hide_banner -encoders" "ocr_subtitle"

# Print summary
printf "%${TOTAL_WIDTH_TEXT}s\n" | tr ' ' '-' # Print a horizontal line
text_with_padding "📊 Summary:" ""
text_with_padding "Total tests:" "${TOTAL_TESTS}"
text_with_padding "Passed tests:" "${PASSED_TESTS}"
text_with_padding "Failed tests:" "${FAILED_TESTS}"
printf "%${TOTAL_WIDTH_TEXT}s\n" | tr ' ' '-' # Print a horizontal line
echo ""

# cleanup
rm -rf "${TestRoot}"

# Exit with failure if any tests failed
if [ "${FAILED_TESTS}" -gt 0 ]; then
    exit $FAILED_TESTS
fi
exit 0
