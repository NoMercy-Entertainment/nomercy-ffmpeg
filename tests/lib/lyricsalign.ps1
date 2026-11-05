# The lyricsalign checks on Windows: the same functions as
# tests/lib/lyricsalign.sh, run THROUGH that file under Git Bash, the way
# tests/lib/stemsplit.ps1 runs the stemsplit gates.
#
#   Test-Lyricsalign -Function <test_lyricsalign_...>   one check
#   Get-LyricsalignFunctions                            every check's name
#
# Why delegation and not a PowerShell port: the checks validate JSON with
# python3 and drive ffmpeg from a work directory with relative paths (the
# colon of a Windows drive letter breaks avfilter's option parser); once Git
# Bash and Python are on the machine, the one bash implementation runs here
# too, and there is one set of checks to keep right instead of two.
# windows-latest has both; a contributor's machine with Git for Windows has
# Git Bash. Without it, every check skips with a reason, never a silent pass.
#
# Inputs: LYRICSALIGN_ASSETS_DIR (the directory tests/lib/lyricsalign-assets.sh
# filled), or a lyricsalign-assets\ directory next to the binary under test.
#
# Each function returns run_custom_test's hashtable: Status Pass/Skip/Fail,
# Reason, Output. Works on Windows PowerShell 5.1 and pwsh 7.

function Get-LyricsalignGitBash {
    $candidates = @()
    if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles 'Git\bin\bash.exe') }
    if (${env:ProgramFiles(x86)}) { $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Git\bin\bash.exe') }
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        $root = Split-Path -Parent (Split-Path -Parent $git.Source)
        $candidates += (Join-Path $root 'bin\bash.exe')
    }
    foreach ($c in $candidates) {
        if (Test-Path $c) { return (Resolve-Path $c).Path }
    }
    return $null
}

$script:LyricsalignFunctions = @(
    'test_lyricsalign_shape', 'test_lyricsalign_jfk_gate_c', 'test_lyricsalign_gate_a',
    'test_lyricsalign_deterministic', 'test_lyricsalign_init_failures', 'test_lyricsalign_destination_pipe',
    'test_lyricsalign_empty_line', 'test_lyricsalign_blend_zero', 'test_lyricsalign_no_alignment',
    'test_lyricsalign_text_forms', 'test_lyricsalign_odd_lines', 'test_lyricsalign_backing_lengths',
    'test_lyricsalign_short_audio', 'test_lyricsalign_metadata', 'test_lyricsalign_gpu'
)

function Get-LyricsalignFunctions { return $script:LyricsalignFunctions }

# Runs one function of tests/lib/lyricsalign.sh under Git Bash and maps its
# exit-code protocol (0 pass, 2 skip, else fail) onto the hashtable.
function Test-Lyricsalign {
    param([string]$Function, [string]$FFmpegExe, [string]$Platform)

    $bash = Get-LyricsalignGitBash
    if (-not $bash) {
        return @{ Status = 'Skip'; Reason = 'Git Bash is needed to run the lyricsalign checks (they are bash with python3) and was not found'; Output = '' }
    }
    if (-not (Test-Path $FFmpegExe)) {
        return @{ Status = 'Fail'; Reason = "no ffmpeg at $FFmpegExe"; Output = '' }
    }
    $here = Split-Path -Parent $PSCommandPath
    $lib = ($here -replace '\\', '/')
    $exe = ((Resolve-Path $FFmpegExe).Path -replace '\\', '/')
    $assets = $env:LYRICSALIGN_ASSETS_DIR
    if (-not $assets) {
        $next = Join-Path (Split-Path -Parent (Resolve-Path $FFmpegExe).Path) 'lyricsalign-assets'
        if (Test-Path $next) { $assets = $next }
    }
    if (-not $assets -or -not (Test-Path $assets)) {
        return @{ Status = 'Skip'; Reason = 'no lyricsalign assets in this environment (run tests/lib/lyricsalign-assets.sh <dir> and set LYRICSALIGN_ASSETS_DIR=<dir>)'; Output = '' }
    }
    $assets = ((Resolve-Path $assets).Path -replace '\\', '/')
    $gpu = if ($env:LYRICSALIGN_TEST_GPU) { $env:LYRICSALIGN_TEST_GPU } else { '0' }

    $script = "source '$lib/lyricsalign.sh' && " +
              "FFMPEG='$exe' Platform='$Platform' LYRICSALIGN_ASSETS_DIR='$assets' LYRICSALIGN_TEST_GPU='$gpu' $Function"

    # Through System.Diagnostics.Process, so stderr merges as plain text on
    # Windows PowerShell 5.1 too (its native-stderr handling under
    # $ErrorActionPreference = 'Stop' would abort on the first line).
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $bash
    $psi.Arguments = '-c ' + '"' + ($script -replace '"', '\"') + '"'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.EnvironmentVariables['MSYS_NO_PATHCONV'] = '1'
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $errTask = $p.StandardError.ReadToEndAsync()
    $out = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    $all = ($out + $errTask.Result).TrimEnd()
    $code = $p.ExitCode

    switch ($code) {
        0 { return @{ Status = 'Pass'; Reason = ''; Output = $all } }
        2 {
            $reason = ($all -split "`r?`n" | Where-Object { $_ -match '^SKIP: ' } | Select-Object -First 1) -replace '^SKIP: ', ''
            if (-not $reason) { $reason = 'skipped' }
            return @{ Status = 'Skip'; Reason = $reason; Output = $all }
        }
        default {
            $reason = ($all -split "`r?`n" | Where-Object { $_ -match '^FAIL: ' } | Select-Object -Last 1) -replace '^FAIL: ', ''
            if (-not $reason) { $reason = "exit $code" }
            return @{ Status = 'Fail'; Reason = $reason; Output = $all }
        }
    }
}
