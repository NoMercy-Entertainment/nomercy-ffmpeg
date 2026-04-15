param (
    [string]$Workspace = $(throw "Workspace path is required")
)

$TOTAL_WIDTH_TEXT = 54
$script:REQUIRED_TOTAL = 0
$script:REQUIRED_PASSED = 0
$script:REQUIRED_FAILED = 0
$script:HW_TOTAL = 0
$script:HW_PASSED = 0
$script:HW_UNAVAILABLE = 0

$TestRoot = "$Workspace\test_files"
$SampleVideo = "$TestRoot\sample.mp4"
$SampleAudio = "$TestRoot\sample.wav"
$SampleImage = "$TestRoot\sample.png"
$SampleSubs = "$TestRoot\test.ass"

# Cleanup and create test directory
Remove-Item -Recurse -Force -Path $TestRoot -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $TestRoot -ErrorAction SilentlyContinue | Out-Null

function text_with_padding {
    param (
        $text_before,
        $text_after,
        $extra_padding = 0
    )
    $text_length = $text_before.Length + $text_after.Length
    $padding = $TOTAL_WIDTH_TEXT - $text_length - $extra_padding
    if ($padding -lt 1) { $padding = 1 }
    Write-Host -NoNewline $text_before
    Write-Host -NoNewline (" " * $padding)
    Write-Host $text_after
}

function check_command {
    if (-Not (Test-Path "$Workspace\ffmpeg.exe")) {
        Write-Host "❌ FFmpeg executable not found in current directory"
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
        text_with_padding "📹 Generating sample video" "[$Current_Count/$Total_Count]"
        & "$Workspace\ffmpeg.exe" -hide_banner -y -f lavfi -i "testsrc=duration=10:size=1280x720:rate=30" -c:v libx264 -crf 23 "$SampleVideo" 2>&1 | Out-Null
        $End_Time = Get-Date
        text_with_padding "✅ Sample video generated" "[$((New-TimeSpan -Start $Start_Time -End $End_Time).TotalSeconds.ToString("0"))s]" 1
    }

    if (-Not (Test-Path $SampleAudio)) {
        $Start_Time = Get-Date
        $Current_Count++
        text_with_padding "🔊 Generating sample audio" "[$Current_Count/$Total_Count]"
        & "$Workspace\ffmpeg.exe" -hide_banner -y -f lavfi -i "sine=frequency=1000:duration=10" -c:a pcm_s16le "$SampleAudio" 2>&1 | Out-Null
        $End_Time = Get-Date
        text_with_padding "✅ Sample audio generated" "[$((New-TimeSpan -Start $Start_Time -End $End_Time).TotalSeconds.ToString("0"))s]" 1
    }

    if (-Not (Test-Path $SampleImage)) {
        $Start_Time = Get-Date
        $Current_Count++
        text_with_padding "🖼️ Generating sample image" "[$Current_Count/$Total_Count]" -1
        & "$Workspace\ffmpeg.exe" -hide_banner -y -f lavfi -i "testsrc=duration=1:size=640x480:rate=1" -frames:v 1 "$SampleImage" 2>&1 | Out-Null
        $End_Time = Get-Date
        text_with_padding "✅ Sample image generated" "[$((New-TimeSpan -Start $Start_Time -End $End_Time).TotalSeconds.ToString("0"))s]" 1
    }

    if (-Not (Test-Path $SampleSubs)) {
        $Start_Time = Get-Date
        $Current_Count++
        text_with_padding "📝 Generating sample subtitles" "[$Current_Count/$Total_Count]"
        @"
[Script Info]
Title: Test Subtitle
ScriptType: v4.00+

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,10,0

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:05.00,Default,,0,0,0,,Test subtitle
"@ | Out-File -FilePath $SampleSubs -Encoding ASCII
        $End_Time = Get-Date
        text_with_padding "✅ Sample subtitles generated" "[$((New-TimeSpan -Start $Start_Time -End $End_Time).TotalSeconds.ToString("0"))s]" 1
    }

    if ($Current_Count -gt 0) {
        Write-Host ([string]::new('-', $TOTAL_WIDTH_TEXT))
    }
}

function run_test {
    param (
        $name,
        $command,
        $expected_output
    )

    $script:REQUIRED_TOTAL++
    $name = $name.ToUpper()
    text_with_padding "🧪 Testing ${name}" "[$script:REQUIRED_TOTAL]"
    $Start_Time = Get-Date
    $test_output = Invoke-Expression "$Workspace\ffmpeg.exe $command 2>&1" | Out-String
    $End_Time = Get-Date
    $elapsed = "$((New-TimeSpan -Start $Start_Time -End $End_Time).Seconds)s"
    if ( $LASTEXITCODE -eq 0 -and $test_output -cmatch $expected_output ) {
        text_with_padding "✅ ${name} passed" "[ ${elapsed} ]" 1
        $script:REQUIRED_PASSED++
    }
    else {
        text_with_padding "❌ ${name} FAILED" "[ ${elapsed} ]" 1
        $script:REQUIRED_FAILED++
    }
}

function run_hw_test {
    param (
        $name,
        $command,
        $expected_output
    )

    $script:HW_TOTAL++
    $name = $name.ToUpper()
    text_with_padding "🔌 Testing ${name}" "[$script:HW_TOTAL]"
    $Start_Time = Get-Date
    $test_output = Invoke-Expression "$Workspace\ffmpeg.exe $command 2>&1" | Out-String
    $End_Time = Get-Date
    $elapsed = "$((New-TimeSpan -Start $Start_Time -End $End_Time).Seconds)s"
    if ( $LASTEXITCODE -eq 0 -and $test_output -cmatch $expected_output ) {
        text_with_padding "✅ ${name} passed" "[ ${elapsed} ]" 1
        $script:HW_PASSED++
    }
    else {
        text_with_padding "➖ ${name} unavailable" "[ ${elapsed} ]" 1
        $script:HW_UNAVAILABLE++
    }
}

# ══════════════════════════════════════════════════════════════
# Main execution
# ══════════════════════════════════════════════════════════════

Write-Host ([string]::new('-', $TOTAL_WIDTH_TEXT))
Write-Host "        _   _       __  __                      "
Write-Host "       | \ | | ___ |  \/  | ___ _ __ ___ _   _  "
Write-Host "       |  \| |/ _ \| |\/| |/ _ \ '__/ __| | | | "
Write-Host "       | |\  | (_) | |  | |  __/ | | (__| |_| | "
Write-Host "       |_| \_|\___/|_|  |_|\___|_|  \___|\__, | "
Write-Host "         _____ _____ __  __ ____  _____ _|___/  "
Write-Host "        |  ___|  ___|  \/  |  _ \| ____/ ___|   "
Write-Host "        | |_  | |_  | |\/| | |_) |  _|| |  _    "
Write-Host "        |  _| |  _| | |  | |  __/| |__| |_| |   "
Write-Host "        |_|   |_|   |_|  |_|_|   |_____\____|   "
Write-Host ""
Write-Host ([string]::new('-', $TOTAL_WIDTH_TEXT))

check_command
generate_samples

# ── Required tests (failures = broken build) ─────────────────
Write-Host ([string]::new('-', $TOTAL_WIDTH_TEXT))
text_with_padding "🔒 Required tests" "(must pass)"
Write-Host ([string]::new('-', $TOTAL_WIDTH_TEXT))

run_test "version" "-version" "ffmpeg version"

# Video codecs
run_test "libx264" "-y -i $SampleVideo -c:v libx264 $TestRoot\test_h264.mp4" "x264"
run_test "libx265" "-y -i $SampleVideo -c:v libx265 $TestRoot\test_h265.mp4" "x265"
run_test "libvpx" "-y -i $SampleVideo -c:v libvpx-vp9 $TestRoot\test_vp9.webm" "vp9"
run_test "libaom" "-y -i $SampleVideo -c:v libaom-av1 $TestRoot\test_av1.mkv" "av1"
run_test "libtheora" "-y -i $SampleVideo -c:v libtheora $TestRoot\test_theora.ogv" "theora"

# Audio codecs
run_test "libfdk_aac" "-y -i $SampleAudio -c:a libfdk_aac $TestRoot\test_aac.m4a" "aac"
run_test "libopus" "-y -i $SampleAudio -c:a libopus $TestRoot\test_opus.opus" "opus"
run_test "libmp3lame" "-y -i $SampleAudio -c:a libmp3lame $TestRoot\test_mp3.mp3" "mp3"

# Image codecs
run_test "libwebp" "-y -i $SampleImage -c:v libwebp $TestRoot\test_webp.webp" "webp"
run_test "libopenjpeg" "-y -i $SampleImage -c:v libopenjpeg $TestRoot\test_jp2.jp2" "openjpeg"

# Subtitle codecs
run_test "libass" "-y -i $SampleVideo -vf `"ass=$SampleSubs`" $TestRoot\test_ass.mp4" "ass"
run_test "vobsub_muxer" "-hide_banner -muxers" "vobsub"
run_test "spritevtt_muxer" "-hide_banner -muxers" "spritevtt"
run_test "chapters_vtt_muxer" "-hide_banner -muxers" "chapters_vtt"

# Auto-create directories
run_test "auto_mkdir" "-y -f lavfi -i `"testsrc=duration=1:size=320x240:rate=1`" -frames:v 1 $TestRoot\subdir_test\nested\output.png" "output.png"

# Library presence
run_test "libbluray" "-hide_banner -protocols | findstr bluray" "bluray"
run_test "libdvdread" "-hide_banner -version | findstr dvdread" "dvdread"
run_test "libcdio" "-hide_banner -version | findstr cdio" "cdio"
run_test "libfribidi" "-hide_banner -version | findstr fribidi" "fribidi"
run_test "libsrt" "-hide_banner -version | findstr srt" "srt"
run_test "libxml2" "-hide_banner -version | findstr xml" "xml"
run_test "libdav1d" "-hide_banner -decoders" "dav1d"
run_test "librav1e" "-hide_banner -encoders" "rav1e"
run_test "ocr_subtitle" "-hide_banner -encoders" "ocr_subtitle"

# ── Hardware tests (failures = no GPU, not a bug) ────────────
Write-Host ([string]::new('-', $TOTAL_WIDTH_TEXT))
text_with_padding "🔌 Hardware tests" "(allowed to fail)"
Write-Host ([string]::new('-', $TOTAL_WIDTH_TEXT))

run_hw_test "NVENC" "-y -i $SampleVideo -c:v h264_nvenc $TestRoot\test_nvenc.mp4" "nvenc"
run_hw_test "VPL" "-y -i $SampleVideo -c:v h264_vpl $TestRoot\test_vpl.mp4" "vpl"
run_hw_test "AMF" "-y -i $SampleVideo -c:v h264_amf $TestRoot\test_amf.mp4" "amf"

# ── Summary ──────────────────────────────────────────────────
Write-Host ([string]::new('-', $TOTAL_WIDTH_TEXT))
text_with_padding "📊 Required:" "$script:REQUIRED_PASSED/$script:REQUIRED_TOTAL passed"
if ($script:REQUIRED_FAILED -gt 0) {
    text_with_padding "   ❌ Failures:" "$script:REQUIRED_FAILED"
}
text_with_padding "📊 Hardware:" "$script:HW_PASSED/$script:HW_TOTAL available"
Write-Host ([string]::new('-', $TOTAL_WIDTH_TEXT))
Write-Host ""

# Cleanup
Remove-Item -Recurse -Force -Path $TestRoot -ErrorAction SilentlyContinue

# Only required failures cause a non-zero exit
if ($script:REQUIRED_FAILED -gt 0) {
    exit 1
}
exit 0
