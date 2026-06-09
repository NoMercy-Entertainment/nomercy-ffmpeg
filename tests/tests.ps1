param (
    [string]$Workspace = $(throw "Workspace path is required")
)

$TOTAL_WIDTH_TEXT = 54
$script:TOTAL_TESTS = 0
$script:PASSED_TESTS = 0
$script:SKIPPED_TESTS = 0
$script:FAILED_TESTS = 0

$TestRoot = "$Workspace\sample_files"
$SampleVideo = "$TestRoot\sample.mp4"
$SampleAudio = "$TestRoot\sample.wav"
$SampleImage = "$TestRoot\sample.png"
$SampleSubs = "$TestRoot\sample.ass"
$AssSubPath = $SampleSubs -replace '\\','/'
$AssSubPath = $AssSubPath -replace ':','\\:'

Remove-Item -Recurse -Force -Path $TestRoot -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $TestRoot -ErrorAction SilentlyContinue | Out-Null

function get_test_runs_count {
    param (
        [string]$searchString
    )
    $filePath = $PSCommandPath
    $fileContent = Get-Content -Path $filePath -Raw
    $_matches = [regex]::Matches($fileContent, [regex]::Escape($searchString))
    $matches_count = $_matches.Count
    if ( $matches_count -gt 0 ) {
        $matches_count--
    }
    return $matches_count
}

$TOTAL_RUNS = get_test_runs_count -searchString 'run_test "'

function generate_samples {
    $Total_Count = 0
    $Current_Count = 0
    $Start_Time = $null
    $End_Time = $null

    # Count needed samples
    if (-Not (Test-Path $SampleVideo)) { $Total_Count++ }
    if (-Not (Test-Path $SampleAudio)) { $Total_Count++ }
    if (-Not (Test-Path $SampleImage)) { $Total_Count++ }
    if (-Not (Test-Path $SampleSubs)) { $Total_Count++ }

    # Generate samples
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

        $elapsed = (New-TimeSpan -Start $Start_Time -End (Get-Date)).TotalSeconds.ToString('0')
        text_with_padding "     $ICON_PASS Sample subtitles" "[${elapsed}s]"
    }

    if ($Current_Count -gt 0) {
        Write-Host ([string]::new('-', $TOTAL_WIDTH_TEXT))
    }
}

function text_with_padding {
    param (
        $text_before,
        $text_after,
        $extra_padding = 0
    )
    $text_length = $text_before.Length + $text_after.Length
    $padding = $TOTAL_WIDTH_TEXT - $text_length - $extra_padding
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

function run_test {
    param (
        $name,
        $command,
        $expected_output
    )

    $script:TOTAL_TESTS++
    $name = $name.ToUpper()
    text_with_padding "🧪 Testing ${name}" "[$script:TOTAL_TESTS/$TOTAL_RUNS]"
    $Start_Time = Get-Date
    $test_output = Invoke-Expression "$Workspace\ffmpeg.exe $command 2>&1" | Out-String
    if ( $LASTEXITCODE -eq 0 -and $test_output -cmatch $expected_output ) {
        $End_Time = Get-Date
        text_with_padding "✅ ${name} test passed" "[ $((New-TimeSpan -Start $Start_Time -End $End_Time).Seconds)s ]" 1
        $script:PASSED_TESTS++
    }
    else {
        $End_Time = Get-Date
        text_with_padding "❌ ${name} test failed" "[ $((New-TimeSpan -Start $Start_Time -End $End_Time).Seconds)s ]" 1
        $script:FAILED_TESTS++
    }
}

function test_support {
    param (
        [ValidateSet("AMF", "VPL")]
        [string]$Feature
    )

    # Vraag video controllers op (eenmalig, wel zo efficiënt)
    $gpus = Get-CimInstance Win32_VideoController

    if ($Feature -eq "AMF") {
        $hasAmdGpu = $gpus | Where-Object { $_.DriverProvider -like "*AMD*" -or $_.Caption -like "*AMD*" -or $_.Caption -like "*Radeon*" }
        $hasAmfDll = Test-Path "$env:SystemRoot\System32\amfrt64.dll"
        
        return [bool]($hasAmdGpu -and $hasAmfDll)
    }
    elseif ($Feature -eq "VPL") {
        $hasIntelGpu = $gpus | Where-Object { $_.DriverProvider -like "*Intel*" -or $_.Caption -like "*Intel*" }
        $hasVplDll = (Test-Path "$env:SystemRoot\System32\libvplintel_preview64.dll") -or 
                     (Test-Path "$env:SystemRoot\System32\mfxplugin64.dll") -or 
                     (Test-Path "$env:SystemRoot\System32\libvpl.dll")
        
        return [bool]($hasIntelGpu -and $hasVplDll)
    }

    return $false
}

# Main execution
Write-Host ([string]::new('-', $TOTAL_WIDTH_TEXT))
Write-Host '  NoMercy FFmpeg Test Suite'
Write-Host ([string]::new('-', $TOTAL_WIDTH_TEXT))

check_command
generate_samples

# Basic tests
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
run_test "libass" "-y -i '${SampleVideo}' -vf ass='${AssSubPath}' '${TestRoot}/test_ass.mp4'" "ass"
run_test "auto_mkdir" "-y -f lavfi -i `"testsrc=duration=1:size=320x240:rate=1`" -frames:v 1 $TestRoot\subdir_test\nested\output.png" "output.png"

# Hardware acceleration (may fail if no hardware support)
run_test "NVENC" "-y -i $SampleVideo -c:v h264_nvenc $TestRoot\test_nvenc.mp4" "nvenc"
# Check for Intel GPU/driver otherwise skip
if (test_support "VPL") {
    run_test "VPL" "-y -i $SampleVideo -c:v h264_vpl $TestRoot\test_vpl.mp4" "vpl"
}
else {
    $script:TOTAL_TESTS++
    text_with_padding "🧪 Testing VPL" "[$script:TOTAL_TESTS/$TOTAL_RUNS]"
    text_with_padding "➖ VPL was skipped" "[ 0s ]" 1
    $script:SKIPPED_TESTS++
}
# Check for AMD GPU/driver otherwise skip
if (test_support "AMF") {
    run_test "AMF" "-y -i $SampleVideo -c:v h264_amf $TestRoot\test_amf.mp4" "amf"
}
else {
    $script:TOTAL_TESTS++
    text_with_padding "🧪 Testing AMF" "[$script:TOTAL_TESTS/$TOTAL_RUNS]"
    text_with_padding "➖ AMF was skipped" "[ 0s ]" 1
    $script:SKIPPED_TESTS++
}

# Additional format tests
run_test "libbluray" "-hide_banner -protocols | findstr bluray" "bluray"
run_test "libdvdread" "-hide_banner -version | findstr dvdread" "dvdread"
run_test "libcdio" "-hide_banner -version | findstr cdio" "cdio"
run_test "libfribidi" "-hide_banner -version | findstr fribidi" "fribidi"
run_test "libsrt" "-hide_banner -version | findstr srt" "srt"
run_test "libxml2" "-hide_banner -version | findstr xml" "xml"

# AV1 codec tests
run_test "libdav1d" "-hide_banner -decoders" "dav1d"
run_test "librav1e" "-hide_banner -encoders" "rav1e"

# OCR subtitle encoder
run_test "ocr_subtitle" "-hide_banner -encoders" "ocr_subtitle"

# Print summary
Write-Host ([string]::new('-', $TOTAL_WIDTH_TEXT))
text_with_padding "📊 Summary:" ""
text_with_padding "Passed tests:" "$script:PASSED_TESTS"
text_with_padding "Skipped tests:" "$script:SKIPPED_TESTS"
text_with_padding "Failed tests:" "$script:FAILED_TESTS"
text_with_padding "Total tests:" "$script:TOTAL_TESTS"
Write-Host ([string]::new('-', $TOTAL_WIDTH_TEXT))
Write-Host ""

Remove-Item -Recurse -Force -Path $TestRoot -ErrorAction SilentlyContinue

# Exit with failure if any tests failed
if ($FAILED_TESTS -gt 0) {
    exit $FAILED_TESTS
}
exit 0
