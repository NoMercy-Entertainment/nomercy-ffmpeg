#Requires -Version 7.0
# Runs the repository's codec suite (tests/tests.ps1) against an unpacked
# windows-aarch64 FFmpeg, on a Windows ARM64 machine with native ARM64 pwsh.
# Ported from wsl-windows-arm/scripts/Invoke-FFmpegSuite.ps1 unchanged except
# for this header: the suite itself has lived here all along, only the wrapper
# was in the provisioning package.
#
# Refuses anything that is not a genuine ARM64 run: an x64 or ARM64EC
# ffmpeg.exe that Windows would quietly execute through its own emulation would
# pass the suite without ever running the ARM64 code we ship.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepositoryPath,
    [Parameter(Mandatory)][string]$FfmpegDirectory,
    [string]$ResultsRoot = 'C:\ffmpeg-test-results',
    [ValidateSet('unknown', 'native', 'qemu-tcg')][string]$ExecutionEnvironment = 'unknown',
    [switch]$RequireHardwareEncoding
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Native stderr is part of FFmpeg's normal diagnostic output.
$PSNativeCommandUseErrorActionPreference = $false

if (-not $IsWindows) { throw 'Run this script on Windows ARM64.' }
$osArch = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
$processArch = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
if ($osArch -ne 'Arm64' -or $processArch -ne 'Arm64') {
    throw "Windows ARM64 and native ARM64 PowerShell 7 are required. OS=$osArch; process=$processArch"
}

$repository = (Resolve-Path -LiteralPath $RepositoryPath).Path
$source = (Resolve-Path -LiteralPath $FfmpegDirectory).Path
$suite = Join-Path $repository 'tests/tests.ps1'
$binary = Join-Path $source 'ffmpeg.exe'
foreach ($file in @($suite, $binary)) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Missing file: $file" }
}

# Reject x64 and ARM64EC binaries that Windows could otherwise execute via emulation.
$reader = [IO.BinaryReader]::new([IO.File]::OpenRead($binary))
try {
    if ($reader.ReadUInt16() -ne 0x5A4D) { throw 'ffmpeg.exe is not a PE executable.' }
    $reader.BaseStream.Position = 0x3C
    $peOffset = $reader.ReadInt32()
    if ($peOffset -lt 64 -or $peOffset -gt ($reader.BaseStream.Length - 6)) {
        throw 'Invalid PE header offset.'
    }
    $reader.BaseStream.Position = $peOffset
    if ($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne 0xAA64) {
        throw 'ffmpeg.exe must be a native Windows ARM64 (0xAA64) executable.'
    }
}
finally { $reader.Dispose() }

$root = [IO.Path]::GetFullPath($ResultsRoot)
# The upstream suite constructs command strings without quoting all paths.
if ($root -notmatch '^[A-Za-z]:\\[A-Za-z0-9_\\-]+$') {
    throw 'Use a local results path containing only letters, digits, underscores, hyphens and backslashes.'
}
if ($root.TrimEnd('\').Equals($source.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase) -or
    $root.StartsWith($source.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'ResultsRoot must be outside FfmpegDirectory to prevent recursive copying.'
}
$runId = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N')
$runDirectory = Join-Path $root $runId
$workspace = Join-Path $runDirectory 'bin'
New-Item -ItemType Directory -Path $workspace -Force | Out-Null
Get-ChildItem -LiteralPath $source -Force | Copy-Item -Destination $workspace -Recurse -Force

$reportPath = Join-Path $runDirectory 'suite.json'
$logPath = Join-Path $runDirectory 'suite.log'
$summaryPath = Join-Path $runDirectory 'summary.json'
$testedBinary = Join-Path $workspace 'ffmpeg.exe'
$adapters = @()
$adapterError = $null
try {
    $adapters = @(Get-CimInstance Win32_VideoController |
        Select-Object Name, AdapterCompatibility, DriverVersion, PNPDeviceID)
}
catch { $adapterError = $_.Exception.Message }

$summary = [ordered]@{
    schema = 1
    platform = 'windows-aarch64'
    os_architecture = $osArch
    process_architecture = $processArch
    execution_environment = $ExecutionEnvironment
    repository = $repository
    ffmpeg_sha256 = (Get-FileHash -LiteralPath $testedBinary -Algorithm SHA256).Hash.ToLowerInvariant()
    video_adapters = $adapters
    video_adapter_query_error = $adapterError
    suite_passed = $false
    suite_exit_code = $null
    hardware_encoding = 'not_verified'
    hardware_decoding = 'not_tested'
    hardware_tests = @()
    error = $null
}
$exitCode = 1
try {
    # A child process isolates the upstream script's exit and cleanup operations.
    $powerShell = Join-Path $PSHOME 'pwsh.exe'
    & $powerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $suite -Workspace $workspace `
        -Platform windows-aarch64 -JsonReport $reportPath 2>&1 |
        Tee-Object -FilePath $logPath | Out-Host
    $suiteExit = $LASTEXITCODE
    $summary.suite_exit_code = $suiteExit
    if (-not (Test-Path -LiteralPath $reportPath)) { throw 'The suite produced no JSON report.' }
    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
    if ($report.platform -ne 'windows-aarch64' -or $report.totals.total -le 0) {
        throw 'The suite report has no tests or an unexpected platform.'
    }
    $summary.suite_passed = ($suiteExit -eq 0 -and $report.totals.failed -eq 0)
    $hardwareTests = @($report.tests | Where-Object { $_.name -in @('NVENC', 'VPL', 'AMF') })
    $summary.hardware_tests = $hardwareTests
    if (@($hardwareTests | Where-Object status -eq 'failed').Count -gt 0) {
        $summary.hardware_encoding = 'failed'
    }
    elseif (@($hardwareTests | Where-Object status -eq 'passed').Count -gt 0) {
        $summary.hardware_encoding = 'passed'
    }
    elseif ($hardwareTests.Count -gt 0) { $summary.hardware_encoding = 'not_exercised' }

    if ($summary.suite_passed) {
        $exitCode = 0
        if ($RequireHardwareEncoding -and $summary.hardware_encoding -ne 'passed') { $exitCode = 2 }
    }
}
catch {
    $summary.error = $_.Exception.Message
    Write-Warning $summary.error
}
finally {
    $summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $summaryPath -Encoding utf8
    Write-Host "Results: $runDirectory"
    Write-Host ('Suite passed: {0}; hardware encoding: {1}; hardware decoding: {2}' -f
        $summary.suite_passed, $summary.hardware_encoding, $summary.hardware_decoding)
}
exit $exitCode
