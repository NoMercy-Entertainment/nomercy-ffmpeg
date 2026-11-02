# The stemsplit release gates on Windows: the same three checks as
# tests/lib/stemsplit.sh, run THROUGH that file under Git Bash.
#
#   Test-StemsplitSuite        the stemsplit tag's own suite (tiny RoFormer
#                              models + Spleeter)
#   Test-StemsplitCleanExit    20/20 clean exits, Spleeter and RoFormer
#   Test-StemsplitSpleeterAB   Spleeter stems byte-identical with the previous
#                              release
#
# Why delegation and not a PowerShell port: the suite is a POSIX sh script with
# Python checkers, so Git Bash and Python are needed on this machine either
# way; once they are, the two smaller checks run through the same bash code the
# other six platforms run, and there is one implementation to keep right
# instead of two kept in step by hand. windows-latest has Git Bash and Python;
# a contributor's machine with Git for Windows has Git Bash. Without it, every
# check skips with a reason, never a silent pass.
#
# Inputs: STEMSPLIT_ASSETS_DIR (the directory tests/lib/stemsplit-assets.sh
# filled), or a stemsplit-assets\ directory next to the binary under test.
#
# Each function returns run_custom_test's hashtable: Status Pass/Skip/Fail,
# Reason, Output. Works on Windows PowerShell 5.1 and pwsh 7.

# Git for Windows' bash, never the WSL launcher in System32 (which is also
# called bash.exe and runs a different operating system).
function Get-GitBash {
    $candidates = @()
    if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles 'Git\bin\bash.exe') }
    if (${env:ProgramFiles(x86)}) { $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Git\bin\bash.exe') }
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        # <root>\cmd\git.exe or <root>\bin\git.exe -> <root>\bin\bash.exe
        $root = Split-Path -Parent (Split-Path -Parent $git.Source)
        $candidates += (Join-Path $root 'bin\bash.exe')
    }
    foreach ($c in $candidates) {
        if (Test-Path $c) { return (Resolve-Path $c).Path }
    }
    return $null
}

# Runs one function of tests/lib/stemsplit.sh under Git Bash and maps its
# exit-code protocol (0 pass, 2 skip, else fail) onto the hashtable.
function Invoke-StemsplitBashCheck {
    param([string]$Function, [string]$FFmpegExe, [string]$Platform)

    $bash = Get-GitBash
    if (-not $bash) {
        return @{ Status = 'Skip'; Reason = 'Git Bash is needed to run the stemsplit checks (the suite is a POSIX sh script) and was not found'; Output = '' }
    }
    $here = Split-Path -Parent $PSCommandPath
    # Mixed C:/... paths: bash accepts them, and nothing here lands in a filter
    # option (the library runs ffmpeg with relative paths; see its header).
    $lib = ($here -replace '\\', '/')
    $exe = ((Resolve-Path $FFmpegExe).Path -replace '\\', '/')
    $assets = $env:STEMSPLIT_ASSETS_DIR
    if (-not $assets) {
        $next = Join-Path (Split-Path -Parent (Resolve-Path $FFmpegExe).Path) 'stemsplit-assets'
        if (Test-Path $next) { $assets = $next }
    }
    if (-not $assets -or -not (Test-Path $assets)) {
        return @{ Status = 'Skip'; Reason = 'no stemsplit assets in this environment (run tests/lib/stemsplit-assets.sh <platform> <dir> and set STEMSPLIT_ASSETS_DIR=<dir>)'; Output = '' }
    }
    $assets = ((Resolve-Path $assets).Path -replace '\\', '/')

    $script = "source '$lib/cpu-variant.sh' && source '$lib/stemsplit.sh' && " +
              "FFMPEG='$exe' Platform='$Platform' STEMSPLIT_ASSETS_DIR='$assets' $Function"

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

function Test-StemsplitSuite {
    param([string]$FFmpegExe, [string]$Platform)
    return Invoke-StemsplitBashCheck -Function 'test_stemsplit_suite' -FFmpegExe $FFmpegExe -Platform $Platform
}

function Test-StemsplitCleanExit {
    param([string]$FFmpegExe, [string]$Platform)
    return Invoke-StemsplitBashCheck -Function 'test_stemsplit_clean_exit' -FFmpegExe $FFmpegExe -Platform $Platform
}

function Test-StemsplitSpleeterAB {
    param([string]$FFmpegExe, [string]$Platform)
    return Invoke-StemsplitBashCheck -Function 'test_stemsplit_spleeter_ab' -FFmpegExe $FFmpegExe -Platform $Platform
}
