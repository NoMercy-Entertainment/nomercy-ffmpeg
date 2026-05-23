param (
    [string]$Workspace = $(throw "Workspace path is required")
)

$TOTAL_WIDTH_TEXT = 54
$script:TOTAL = 0
$script:PASSED = 0
$script:FAILED = 0

[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ICON_PASS = [char]0x2714
$ICON_FAIL = [char]0x2718

$TestRoot = "$Workspace\test_files"
$SampleVideo = "$TestRoot\sample.mp4"
$SampleAudio = "$TestRoot\sample.wav"
$SampleImage = "$TestRoot\sample.png"
$SampleSubs = "$TestRoot\test.ass"

Remove-Item -Recurse -Force -Path $TestRoot -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $TestRoot -ErrorAction SilentlyContinue | Out-Null

function text_with_padding {
    param ($text_before, $text_after, $extra_padding = 0)
    $text_length = $text_before.Length + $text_after.Length
    $padding = $TOTAL_WIDTH_TEXT - $text_length - $extra_padding
    if ($padding -lt 1) { $padding = 1 }
    Write-Host -NoNewline $text_before
    Write-Host -NoNewline (" " * $padding)
    Write-Host $text_after
}

function check_command {
    if (-Not (Test-Path "$Workspace\ffmpeg.exe")) {
        Write-Host "$ICON_FAIL FFmpeg executable not found"
        exit 1
    }
}

function generate_samples {
    $Total_Count = 0
    $Current_Count = 0

    if (-Not (Test-Path $SampleVideo)) { $Total_Count++ }
    if (-Not (Test-Path $SampleAudio)) { $Total_Count++ }
    if (-Not (Test-Path $SampleImage)) { $Total_Count++ }
    if (-Not (Test-Path $SampleSubs)) { $Total_Count++ }

    if (-Not (Test-Path $SampleVideo)) {
        $Start_Time = Get-Date
        $Current_Count++
        & "$Workspace\ffmpeg.exe" -hide_banner -y -f lavfi -i "testsrc=duration=10:size=1280x720:rate=30" -c:v libx264 -crf 23 "$SampleVideo" 2>&1 | Out-Null
        $elapsed = (New-TimeSpan -Start $Start_Time -End (Get-Date)).TotalSeconds.ToString('0')
        text_with_padding "     $ICON_PASS Sample video" "[${elapsed}s]"
    }

    if (-Not (Test-Path $SampleAudio)) {
        $Start_Time = Get-Date
        $Current_Count++
        & "$Workspace\ffmpeg.exe" -hide_banner -y -f lavfi -i "sine=frequency=1000:duration=10" -c:a pcm_s16le "$SampleAudio" 2>&1 | Out-Null
        $elapsed = (New-TimeSpan -Start $Start_Time -End (Get-Date)).TotalSeconds.ToString('0')
        text_with_padding "     $ICON_PASS Sample audio" "[${elapsed}s]"
    }

    if (-Not (Test-Path $SampleImage)) {
        $Start_Time = Get-Date
        $Current_Count++
        & "$Workspace\ffmpeg.exe" -hide_banner -y -f lavfi -i "testsrc=duration=1:size=640x480:rate=1" -frames:v 1 "$SampleImage" 2>&1 | Out-Null
        $elapsed = (New-TimeSpan -Start $Start_Time -End (Get-Date)).TotalSeconds.ToString('0')
        text_with_padding "     $ICON_PASS Sample image" "[${elapsed}s]"
    }

    if (-Not (Test-Path $SampleSubs)) {
        $Current_Count++
        $assContent = @(
            '[Script Info]'
            'Title: Test Subtitle'
            'ScriptType: v4.00+'
            ''
            '[V4+ Styles]'
            'Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding'
            'Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,10,0'
            ''
            '[Events]'
            'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text'
            'Dialogue: 0,0:00:01.00,0:00:05.00,Default,,0,0,0,,Test subtitle'
        ) -join "`n"
        [System.IO.File]::WriteAllText($SampleSubs, $assContent)
        text_with_padding "     $ICON_PASS Sample subtitles" "[0s]"
    }

    if ($Current_Count -gt 0) {
        Write-Host ([string]::new('-', $TOTAL_WIDTH_TEXT))
    }
}

function run_test {
    param ($name, $command, $expected_output)

    $script:TOTAL++
    $name = $name.ToUpper()
    $num = $script:TOTAL.ToString().PadLeft(2)
    $Start_Time = Get-Date
    $test_output = Invoke-Expression "$Workspace\ffmpeg.exe $command 2>&1" | Out-String
    $End_Time = Get-Date
    $elapsed = "$((New-TimeSpan -Start $Start_Time -End $End_Time).Seconds)s"
    if ( $test_output -cmatch $expected_output ) {
        text_with_padding " ${num}. $ICON_PASS ${name}" "[ ${elapsed} ]"
        $script:PASSED++
    }
    else {
        text_with_padding " ${num}. $ICON_FAIL ${name}" "[ ${elapsed} ]"
        $script:FAILED++
    }
}

function check_compiled {
    param ($name, $type, $symbol)

    $script:TOTAL++
    $name = $name.ToUpper()
    $num = $script:TOTAL.ToString().PadLeft(2)

    $list_output = Invoke-Expression "$Workspace\ffmpeg.exe -hide_banner -${type} 2>&1" | Out-String
    if ($list_output -match $symbol) {
        text_with_padding " ${num}. $ICON_PASS ${name}" "[compiled]"
        $script:PASSED++
    }
    else {
        text_with_padding " ${num}. $ICON_FAIL ${name}" "[missing]"
        $script:FAILED++
    }
}

# ==============================================================
Write-Host ([string]::new('-', $TOTAL_WIDTH_TEXT))
Write-Host '  NoMercy FFmpeg Test Suite'
Write-Host ([string]::new('-', $TOTAL_WIDTH_TEXT))

check_command
generate_samples

Write-Host ([string]::new('-', $TOTAL_WIDTH_TEXT))

run_test "version" "-version" "ffmpeg version"
run_test "libx264" "-y -i $SampleVideo -c:v libx264 $TestRoot\test_h264.mp4" "x264"
run_test "libx265" "-y -i $SampleVideo -c:v libx265 $TestRoot\test_h265.mp4" "x265"
run_test "libvpx" "-y -i $SampleVideo -c:v libvpx-vp9 -frames:v 1 $TestRoot\test_vp9.webm" "vp9"
run_test "libaom" "-y -i $SampleVideo -c:v libaom-av1 -frames:v 1 $TestRoot\test_av1.mkv" "av1"
run_test "libtheora" "-y -i $SampleVideo -c:v libtheora -frames:v 1 $TestRoot\test_theora.ogv" "theora"
run_test "libfdk_aac" "-y -i $SampleAudio -c:a libfdk_aac $TestRoot\test_aac.m4a" "aac"
run_test "libopus" "-y -i $SampleAudio -c:a libopus $TestRoot\test_opus.opus" "opus"
run_test "libmp3lame" "-y -i $SampleAudio -c:a libmp3lame $TestRoot\test_mp3.mp3" "mp3"
run_test "libwebp" "-y -i $SampleImage -c:v libwebp -f webp $TestRoot\test_webp.webp" "webp"
run_test "libopenjpeg" "-y -i $SampleImage -c:v libopenjpeg $TestRoot\test_jp2.jp2" "openjpeg"
run_test "libass" "-y -i $SampleVideo -vf ass=$($SampleSubs.Replace('\','/')) $TestRoot\test_ass.mp4" "ass"
run_test "auto_mkdir" "-y -f lavfi -i `"testsrc=duration=1:size=320x240:rate=1`" -frames:v 1 $TestRoot\subdir_test\nested\output.png" "output.png"

Write-Host ([string]::new('-', $TOTAL_WIDTH_TEXT))

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
check_compiled "nvenc" "encoders" "h264_nvenc"
check_compiled "amf" "encoders" "h264_amf"

Write-Host ([string]::new('-', $TOTAL_WIDTH_TEXT))
text_with_padding " Results:" "$script:PASSED/$script:TOTAL passed"
if ($script:FAILED -gt 0) {
    text_with_padding " $ICON_FAIL FAILED:" "$script:FAILED"
}
Write-Host ([string]::new('-', $TOTAL_WIDTH_TEXT))
Write-Host ""

Remove-Item -Recurse -Force -Path $TestRoot -ErrorAction SilentlyContinue

if ($script:FAILED -gt 0) { exit 1 }
exit 0
