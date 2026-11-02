#Requires -Version 7.0
# Downloads a published release's windows-aarch64 archive, verifies it against
# the release manifest, fetches the source at the commit the manifest names,
# and runs the codec suite from that commit against the archive's ffmpeg.exe.
#
# Ported from wsl-windows-arm/scripts/Invoke-ReleaseTest.ps1. Two things
# differ. The work directory is a parameter (the package hard-coded
# C:\ffmpeg-releases; the runner's work drive here is D:), and nothing is copied
# to a Mac share -- the workflow uploads the reports as an artifact instead.
# The probe of 2026-10-10 found the runner: Windows 11 ARM64, native pwsh 7.6.6,
# 8 CPUs, 8 GB, D: with 119 GB free, no video adapter, roughly 100x slower
# than native for PowerShell itself; the suite's ffmpeg runs are native ARM64
# code under TCG, which is faster than that.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')][string]$Tag,
    [ValidatePattern('^[a-fA-F0-9]{40}$')][string]$ExpectedCommit,
    [Parameter(Mandatory)][string]$WorkRoot,
    [switch]$RequireHardwareEncoding
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$PSNativeCommandUseErrorActionPreference = $false
if (-not $IsWindows -or
    [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -ne 'Arm64' -or
    [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString() -ne 'Arm64') {
    throw 'Run on Windows ARM64 with native ARM64 PowerShell 7.'
}

$repo = 'NoMercy-Entertainment/nomercy-ffmpeg'
$runId = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N')
$work = Join-Path ([IO.Path]::GetFullPath($WorkRoot)) $runId
New-Item -ItemType Directory -Path $work -Force | Out-Null
if ($env:GITHUB_OUTPUT) {
    "results-root=$work" | Add-Content -LiteralPath $env:GITHUB_OUTPUT -Encoding utf8
}
$releaseUrl = "https://github.com/$repo/releases/download/$Tag"
$manifestPath = Join-Path $work 'manifest.json'
Invoke-WebRequest -Uri "$releaseUrl/manifest.json" -OutFile $manifestPath
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.repo -ne $repo -or $manifest.tag -ne $Tag -or $manifest.commit_sha -notmatch '^[a-fA-F0-9]{40}$') {
    throw 'Manifest repository, tag or commit is invalid.'
}
if ($ExpectedCommit -and $manifest.commit_sha -ne $ExpectedCommit) {
    throw 'The release was replaced after CI resolved it: manifest commit does not match.'
}
$assets = @($manifest.assets | Where-Object { $_.name -match '^ffmpeg-[A-Za-z0-9._-]+-windows-aarch64-[A-Za-z0-9._-]+\.zip$' })
if ($assets.Count -ne 1 -or $assets[0].sha256 -notmatch '^[a-fA-F0-9]{64}$') {
    throw 'Expected exactly one Windows ARM64 ZIP and its SHA-256 in the manifest.'
}
$asset = $assets[0]
$archive = Join-Path $work $asset.name
Invoke-WebRequest -Uri "$releaseUrl/$($asset.name)" -OutFile $archive
$sha = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
if ($sha -ne $asset.sha256) { throw 'FFmpeg archive SHA-256 mismatch.' }
$binaryDirectory = Join-Path $work 'ffmpeg'
Expand-Archive -LiteralPath $archive -DestinationPath $binaryDirectory

# Get the suite from the exact build commit recorded by the release manifest.
$sourceArchive = Join-Path $work 'source.zip'
$commit = $manifest.commit_sha
Invoke-WebRequest -Uri "https://github.com/$repo/archive/$commit.zip" -OutFile $sourceArchive
$sourceDirectory = Join-Path $work 'source'
Expand-Archive -LiteralPath $sourceArchive -DestinationPath $sourceDirectory
$repository = Join-Path $sourceDirectory "nomercy-ffmpeg-$commit"
$resultsRoot = Join-Path $work 'results'

$provenance = [ordered]@{
    tag = $Tag
    commit = $commit
    archive = $asset.name
    archive_sha256 = $sha
    integrity_verified = $true
    execution = 'qemu-tcg'
    description = 'Emulated Windows ARM64; not a native-hardware verification verdict.'
}
$provenance | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $work 'release.json') -Encoding utf8
$wrapper = Join-Path $PSScriptRoot 'Invoke-FFmpegSuite.ps1'
$arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wrapper, '-RepositoryPath', $repository,
    '-FfmpegDirectory', $binaryDirectory, '-ResultsRoot', $resultsRoot, '-ExecutionEnvironment', 'qemu-tcg')
if ($RequireHardwareEncoding) { $arguments += '-RequireHardwareEncoding' }
& (Join-Path $PSHOME 'pwsh.exe') @arguments
$testExit = $LASTEXITCODE
Write-Host "Local files: $work"
exit $testExit
