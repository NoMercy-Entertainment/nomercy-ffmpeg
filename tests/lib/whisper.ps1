# Real-model tests for the whisper filter options of issue #112.
# Mirrors tests/lib/whisper.sh check for check -- see that file for the
# reasoning behind each one. Kept in lockstep with the bash version.
#
#   Test-WhisperOptions          the new options do what they say
#   Test-WhisperDefaultsUnchanged without them, output is byte-identical to
#                                 a reference build (v1.0.44)
#
# Inputs: WHISPER_TEST_MODEL (ggml-base.en.bin), WHISPER_TEST_AUDIO (jfk.wav)
# and, for the defaults check, WHISPER_TEST_REFERENCE_FFMPEG (a v1.0.44
# ffmpeg.exe). Unset, ggml-base.en.bin and jfk.wav next to the binary are
# used if present; otherwise both tests skip with a reason.
#
# ffmpeg runs through System.Diagnostics.Process, not `& ffmpeg > file`:
# PowerShell re-encodes redirected native output line by line (UTF-16 on
# Windows PowerShell 5.1), which would make every byte comparison here
# meaningless. Works on Windows PowerShell 5.1 and pwsh 7.

function Get-WhisperTestInputs {
    param([string]$FFmpegExe)
    $binDir = Split-Path -Parent $FFmpegExe
    $model = $env:WHISPER_TEST_MODEL
    $audio = $env:WHISPER_TEST_AUDIO
    if (-not $model -and (Test-Path (Join-Path $binDir 'ggml-base.en.bin'))) { $model = Join-Path $binDir 'ggml-base.en.bin' }
    if (-not $audio -and (Test-Path (Join-Path $binDir 'jfk.wav'))) { $audio = Join-Path $binDir 'jfk.wav' }
    if (-not $model -or -not (Test-Path $model) -or -not $audio -or -not (Test-Path $audio)) {
        return $null
    }
    return @{ Model = (Resolve-Path $model).Path; Audio = (Resolve-Path $audio).Path }
}

# A scratch directory with the model as model.bin. avfilter treats ':' as its
# option separator, so a drive letter in model= or prompt_file= breaks the
# filter description; running in here with leaf names avoids that.
function New-WhisperTestDir {
    param([string]$Model)
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("nm-whisper-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $target = Join-Path $dir 'model.bin'
    try {
        New-Item -ItemType HardLink -Path $target -Target $Model -ErrorAction Stop | Out-Null
    } catch {
        Copy-Item -Path $Model -Destination $target
    }
    return $dir
}

# Runs the filter over the clip, stdout to $OutFile as raw bytes, stderr to
# $ErrFile. CPU only, one filter thread, and the baseline ggml variant when
# $Ctx.Baseline is set (the defaults check).
#
# stdin is redirected and closed at once, and ffmpeg also gets -nostdin: on
# Windows PowerShell 5.1 started from another shell, an ffmpeg that inherited
# stdin sat for over ten minutes on a plain `-h filter=whisper` (seen while
# writing this file).
function Invoke-NativeToFiles {
    param(
        [string]$Exe,
        [string]$Arguments,
        [string]$WorkDir,
        [string]$OutFile,
        [string]$ErrFile,
        [string]$Baseline = ''
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.WorkingDirectory = $WorkDir
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    if ($Baseline) { $psi.EnvironmentVariables['NOMERCY_GGML_CPU'] = $Baseline }
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $errTask = $p.StandardError.ReadToEndAsync()
    $fs = [System.IO.File]::Create($OutFile)
    try { $p.StandardOutput.BaseStream.CopyTo($fs) } finally { $fs.Dispose() }
    $p.WaitForExit()
    [System.IO.File]::WriteAllText($ErrFile, $errTask.Result)
    return $p.ExitCode
}

function Invoke-WhisperRun {
    param(
        [string]$Exe,
        [hashtable]$Ctx,
        [string]$OutFile,
        [string]$ErrFile,
        [string]$Options
    )
    $arguments = ('-hide_banner -nostdin -nostats -filter_threads 1 -i "{0}" -af "whisper=model=model.bin:use_gpu=0:{1}" -f null -' -f $Ctx.Audio, $Options)
    return (Invoke-NativeToFiles -Exe $Exe -Arguments $arguments -WorkDir $Ctx.Dir -OutFile $OutFile -ErrFile $ErrFile -Baseline $Ctx.Baseline)
}

function Test-SameBytes {
    param([string]$A, [string]$B)
    return (Get-FileHash -Algorithm SHA256 $A).Hash -eq (Get-FileHash -Algorithm SHA256 $B).Hash
}

function Get-WhisperNormalized {
    param([string]$Text)
    return [regex]::Replace($Text.ToLowerInvariant(), '[^\w]+', '')
}

# Same rules as _whisper_check_json in whisper.sh. Returns '' when the file
# passes, otherwise the reason. $Mode is '' or 'words'; $NoDtwFile, when
# given, must have at least one word start that differs.
function Test-WhisperJson {
    param([string]$Path, [string]$Mode = '', [string]$NoDtwFile = '')

    function Read-Segments([string]$File) {
        $text = [System.IO.File]::ReadAllText($File, [System.Text.Encoding]::UTF8)
        $lines = @($text -split "`n" | Where-Object { $_ -ne '' })
        if ($lines.Count -eq 0) { throw "${File}: no output at all" }
        $objs = @()
        $i = 0
        foreach ($line in $lines) {
            $i++
            try { $objs += , ($line | ConvertFrom-Json) } catch { throw "${File}:${i}: not valid JSON: $line" }
        }
        if ($null -eq $objs[0].detected_language) { throw "${File}: first line is not the detected_language line" }
        if ($objs.Count -lt 2) { throw "${File}: no segments after the language line" }
        return , @($objs | Select-Object -Skip 1)
    }

    try {
        $segs = Read-Segments $Path
        $n = 0
        foreach ($s in $segs) {
            $n++
            foreach ($k in 'start', 'end', 'text') {
                if ($null -eq $s.$k) { return "${Path}: segment $n has no '$k'" }
            }
            if ($Mode -ne 'words') {
                if ($null -ne $s.words) { return "${Path}: segment $n has a words array nobody asked for" }
                continue
            }
            $w = @($s.words)
            if ($null -eq $s.words -or $w.Count -eq 0) { return "${Path}: segment $n has no words" }
            $prev = $null
            foreach ($x in $w) {
                if ($x.p -lt 0 -or $x.p -gt 1) { return "${Path}: segment ${n}: p out of range ($($x.p))" }
                if (-not ($s.start -le $x.start -and $x.start -le $x.end -and $x.end -le $s.end)) {
                    return "${Path}: segment ${n}: word '$($x.text)' [$($x.start), $($x.end)] outside [$($s.start), $($s.end)]"
                }
                if ($null -ne $prev -and $x.start -lt $prev) { return "${Path}: segment ${n}: word starts go backwards at '$($x.text)'" }
                $prev = $x.start
            }
            $joined = ($w | ForEach-Object { $_.text }) -join ' '
            if ((Get-WhisperNormalized $joined) -ne (Get-WhisperNormalized $s.text)) {
                return "${Path}: segment ${n}: words '$joined' do not make up text '$($s.text)'"
            }
        }
        if ($NoDtwFile) {
            $other = Read-Segments $NoDtwFile
            $a = ($segs | ForEach-Object { $_.words | ForEach-Object { $_.start } }) -join ','
            $b = ($other | ForEach-Object { $_.words | ForEach-Object { $_.start } }) -join ','
            if ($a -eq $b) { return "${Path}: every word start equals the run without DTW; DTW did not take effect" }
        }
    } catch {
        return $_.Exception.Message
    }
    return ''
}

function Test-WhisperOptions {
    param([string]$FFmpegExe, [string]$Platform)

    $lines = New-Object System.Collections.Generic.List[string]
    $inputs = Get-WhisperTestInputs -FFmpegExe $FFmpegExe
    if (-not $inputs) {
        return @{ Status = 'Skip'; Reason = 'no whisper model and clip in this environment (set WHISPER_TEST_MODEL to ggml-base.en.bin and WHISPER_TEST_AUDIO to jfk.wav)'; Output = '' }
    }
    $dir = New-WhisperTestDir -Model $inputs.Model
    # No forced variant here: the baseline is several times slower, and these
    # checks only compare runs of one binary. See _whisper_run in whisper.sh.
    $ctx = @{ Dir = $dir; Audio = $inputs.Audio; Baseline = '' }

    function Fail([string]$Reason) {
        $lines.Add("FAIL: $Reason")
        return @{ Status = 'Fail'; Reason = $Reason; Output = ($lines -join "`n") }
    }
    function F([string]$Name) { return (Join-Path $dir $Name) }
    function Run([string]$Out, [string]$Err, [string]$Opts) {
        return (Invoke-WhisperRun -Exe $FFmpegExe -Ctx $ctx -OutFile (F $Out) -ErrFile (F $Err) -Options $Opts)
    }
    function ErrHas([string]$Err, [string]$Pattern) {
        return [System.IO.File]::ReadAllText((F $Err)) -match $Pattern
    }

    try {
        $lines.Add("model: $($inputs.Model)")
        $lines.Add("audio: $($inputs.Audio)")

        # 1. Plain JSON.
        if ((Run 'plain.json' 'plain.err' 'format=json:destination=-') -ne 0) { return (Fail 'format=json run exited non-zero') }
        $why = Test-WhisperJson (F 'plain.json')
        if ($why) { return (Fail $why) }
        $lines.Add('plain json OK')

        # 2. -h filter=whisper lists the six options.
        $null = Invoke-NativeToFiles -Exe $FFmpegExe -Arguments '-hide_banner -nostdin -h filter=whisper' -WorkDir $dir -OutFile (F 'help.txt') -ErrFile (F 'help.err')
        $help = [System.IO.File]::ReadAllText((F 'help.txt'))
        foreach ($opt in 'dtw', 'word_timestamps', 'prompt', 'prompt_file', 'beam_size', 'best_of') {
            if ($help -notmatch "(?m)^ +$opt ") { return (Fail "-h filter=whisper does not list $opt") }
        }
        $lines.Add('-h filter=whisper lists all six options')

        # 3. A missing prompt_file fails and names the path.
        if ((Run 'x.out' 'missing.err' 'format=json:destination=-:prompt_file=no-such-prompt.txt') -eq 0) { return (Fail 'a missing prompt_file did not fail') }
        if (-not (ErrHas 'missing.err' 'no-such-prompt\.txt')) { return (Fail 'the prompt_file error does not name the path') }
        $lines.Add('missing prompt_file fails and names the path')

        # 4. prompt_file wins over prompt, and prompts do change the output.
        [System.IO.File]::WriteAllText((F 'prompt.txt'), "Hello Kennedy.`n")
        if ((Run 'both.json' 'both.err' 'format=json:destination=-:prompt=Zebra zebra zebra:prompt_file=prompt.txt') -ne 0) { return (Fail 'prompt + prompt_file run failed') }
        if ((Run 'file.json' 'file.err' 'format=json:destination=-:prompt=Hello Kennedy.') -ne 0) { return (Fail 'prompt run failed') }
        if ((Run 'zebra.json' 'zebra.err' 'format=json:destination=-:prompt=Zebra zebra zebra') -ne 0) { return (Fail 'prompt run failed') }
        if (-not (Test-SameBytes (F 'both.json') (F 'file.json'))) { return (Fail 'with both set, the output is not the prompt_file output') }
        if (Test-SameBytes (F 'both.json') (F 'zebra.json')) { return (Fail 'the two prompts give identical output, so this check cannot tell which one won') }
        if (-not (ErrHas 'both.err' 'using prompt_file')) { return (Fail 'no warning that prompt_file overrides prompt') }
        $lines.Add('prompt_file wins over prompt (and the prompts do change the output)')

        # 5. Beam search.
        if ((Run 'beam.json' 'beam.err' 'format=json:destination=-:beam_size=5:best_of=3') -ne 0) { return (Fail 'beam_size=5:best_of=3 failed') }
        $why = Test-WhisperJson (F 'beam.json')
        if ($why) { return (Fail $why) }
        if (Test-SameBytes (F 'beam.json') (F 'plain.json')) { return (Fail 'beam_size=5 gives the same output as greedy decoding; was it applied?') }
        if ((Run 'x.out' 'beam9.err' 'format=json:destination=-:beam_size=9') -eq 0 -or -not (ErrHas 'beam9.err' 'beam_size')) {
            return (Fail "beam_size=9 (above whisper.cpp's 8 decoders) was not rejected")
        }
        $lines.Add('beam search changes the output; beam_size above 8 is rejected')

        # 6. DTW really on; unknown and mismatched presets fail.
        if ((Run 'dtw.json' 'dtw.err' 'format=json:destination=-:dtw=base.en:word_timestamps=1') -ne 0) { return (Fail 'dtw=base.en:word_timestamps=1 failed') }
        if (-not (ErrHas 'dtw.err' 'DTW on \(preset base\.en\); flash attention turned off')) { return (Fail "no 'flash attention turned off' line with dtw=base.en") }
        if (ErrHas 'dtw.err' 'not supported with flash_attn') { return (Fail 'whisper.cpp still switched DTW off because of flash attention') }
        if ((Run 'x.out' 'bogus.err' 'format=json:destination=-:dtw=bogus') -eq 0 -or -not (ErrHas 'bogus.err' "Unknown dtw preset 'bogus'.*large\.v3\.turbo")) {
            return (Fail 'an unknown dtw preset did not fail with the list of presets')
        }
        foreach ($preset in 'base', 'large.v3') {
            if ((Run 'x.out' 'mis.err' "format=json:destination=-:dtw=$preset") -eq 0 -or -not (ErrHas 'mis.err' ("dtw=" + [regex]::Escape($preset) + " does not match this model"))) {
                return (Fail "dtw=$preset on base.en did not fail naming the preset")
            }
        }
        $lines.Add('DTW active with base.en; unknown and mismatched presets fail')

        # 7. Word timestamps without and with DTW.
        if ((Run 'words.json' 'words.err' 'format=json:destination=-:word_timestamps=1') -ne 0) { return (Fail 'word_timestamps=1 failed') }
        $why = Test-WhisperJson (F 'words.json') 'words'
        if ($why) { return (Fail $why) }
        $why = Test-WhisperJson (F 'dtw.json') 'words' (F 'words.json')
        if ($why) { return (Fail $why) }
        $lines.Add('word timestamps OK, and DTW changes the word starts')

        # 8. word_timestamps with format=srt warns and changes nothing.
        if ((Run 'a.srt' 'a.err' 'format=srt:destination=-:word_timestamps=1') -ne 0) { return (Fail 'srt run with word_timestamps failed') }
        if ((Run 'b.srt' 'b.err' 'format=srt:destination=-') -ne 0) { return (Fail 'srt run failed') }
        if ((Get-Item (F 'b.srt')).Length -eq 0) { return (Fail 'format=srt wrote nothing') }
        if (-not (ErrHas 'a.err' 'word_timestamps only applies to format=json')) { return (Fail 'no warning for word_timestamps with format=srt') }
        if (-not (Test-SameBytes (F 'a.srt') (F 'b.srt'))) { return (Fail 'word_timestamps changed the srt output') }
        $lines.Add('word_timestamps with format=srt warns and leaves the output alone')

        # 9. destination=- and an escaped pipe:1 write the same bytes.
        if ((Run 'pipe.json' 'pipe.err' 'format=json:destination=pipe\\:1') -ne 0) { return (Fail 'destination=pipe\:1 failed') }
        if ((Get-Item (F 'pipe.json')).Length -eq 0) { return (Fail 'destination=pipe\:1 wrote nothing') }
        if (-not (Test-SameBytes (F 'plain.json') (F 'pipe.json'))) { return (Fail 'destination=- and pipe\:1 differ') }
        $lines.Add('destination=- and destination=pipe\:1 give the same bytes')

        return @{ Status = 'Pass'; Reason = ''; Output = ($lines -join "`n") }
    } finally {
        Remove-Item -Recurse -Force -Path $dir -ErrorAction SilentlyContinue
    }
}

function Test-WhisperDefaultsUnchanged {
    param([string]$FFmpegExe, [string]$Platform)

    $inputs = Get-WhisperTestInputs -FFmpegExe $FFmpegExe
    if (-not $inputs) {
        return @{ Status = 'Skip'; Reason = 'no whisper model and clip in this environment (set WHISPER_TEST_MODEL to ggml-base.en.bin and WHISPER_TEST_AUDIO to jfk.wav)'; Output = '' }
    }
    $ref = $env:WHISPER_TEST_REFERENCE_FFMPEG
    if (-not $ref -or -not (Test-Path $ref)) {
        return @{ Status = 'Skip'; Reason = 'no reference ffmpeg (set WHISPER_TEST_REFERENCE_FFMPEG to a v1.0.44 build)'; Output = '' }
    }
    $dir = New-WhisperTestDir -Model $inputs.Model
    $ctx = @{ Dir = $dir; Audio = $inputs.Audio; Baseline = (Get-CpuVariantBaseline $Platform) }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("reference: $ref")
    try {
        foreach ($fmt in 'json', 'srt') {
            $new = Join-Path $dir "new.$fmt"
            $old = Join-Path $dir "ref.$fmt"
            if ((Invoke-WhisperRun -Exe $FFmpegExe -Ctx $ctx -OutFile $new -ErrFile (Join-Path $dir 'new.err') -Options "format=${fmt}:destination=-") -ne 0) {
                return @{ Status = 'Fail'; Reason = "format=$fmt run of the build under test failed"; Output = ($lines -join "`n") }
            }
            if ((Invoke-WhisperRun -Exe $ref -Ctx $ctx -OutFile $old -ErrFile (Join-Path $dir 'ref.err') -Options "format=${fmt}:destination=-") -ne 0) {
                return @{ Status = 'Fail'; Reason = "format=$fmt run of the reference failed"; Output = ($lines -join "`n") }
            }
            # Two empty files hash the same; that must not count as a pass.
            if ((Get-Item $old).Length -eq 0) {
                return @{ Status = 'Fail'; Reason = "the reference wrote no $fmt"; Output = ($lines -join "`n") }
            }
            if (-not (Test-SameBytes $new $old)) {
                return @{ Status = 'Fail'; Reason = "default format=$fmt output differs from the reference"; Output = ($lines -join "`n") }
            }
            $lines.Add("format=${fmt}: byte-identical to the reference ($((Get-Item $new).Length) bytes)")
        }
        return @{ Status = 'Pass'; Reason = ''; Output = ($lines -join "`n") }
    } finally {
        Remove-Item -Recurse -Force -Path $dir -ErrorAction SilentlyContinue
    }
}
