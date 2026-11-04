param(
    [string]$FFmpegPath,
    [string]$ResultsDirectory,
    [string]$Image = 'nomercy-gpu-check:local',
    [string]$ExpectedGPU = 'RTX 3070',
    [string]$LabName,
    [switch]$Build,
    [switch]$SystemControl
)
# Windows PowerShell 5.1 wraps native stderr as ErrorRecords; inspect the
# native exit code explicitly while keeping filesystem failures terminating.
$ErrorActionPreference = 'Continue'
Get-Command docker -ErrorAction Stop | Out-Null
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if (-not $ResultsDirectory) { $ResultsDirectory = Join-Path $repo 'output/gpu-container' }
New-Item -ItemType Directory -Force -Path $ResultsDirectory -ErrorAction Stop | Out-Null
$results = (Resolve-Path -LiteralPath $ResultsDirectory -ErrorAction Stop).Path

$mountedFFmpeg = $null
if ($FFmpegPath) {
    $mountedFFmpeg = (Resolve-Path -LiteralPath $FFmpegPath -ErrorAction Stop).Path
    $stream = [IO.File]::OpenRead($mountedFFmpeg)
    try { $header = New-Object byte[] 8; $read = $stream.Read($header, 0, 8) }
    finally { $stream.Dispose() }
    if ($read -ne 8 -or $header[0] -ne 127 -or $header[1] -ne 69 -or $header[2] -ne 76 -or $header[3] -ne 70) {
        throw 'This container requires a Linux ELF FFmpeg executable.'
    }
    if ($header[7] -eq 9) { throw 'A FreeBSD executable needs a FreeBSD kernel; this container tests Linux/WSL2 only.' }
}

$imageExists = $false
try { & docker image inspect $Image *> $null; $imageExists = $LASTEXITCODE -eq 0 }
catch { $imageExists = $false }
if ($Build -or -not $imageExists) {
    & docker build --cpuset-cpus 0,1 -t $Image $PSScriptRoot
    if ($LASTEXITCODE -ne 0) { throw 'GPU validation image build failed.' }
}
$arguments = @('run', '--gpus', 'all', '--ulimit', 'core=0', '--device', '/dev/dxg',
    '--mount', 'type=bind,source=/usr/lib/wsl/lib,target=/usr/lib/wsl/lib,readonly',
    '--mount', 'type=bind,source=/usr/lib/wsl/drivers,target=/usr/lib/wsl/drivers,readonly',
    '--mount', "type=bind,source=$results,target=/results")
if ($mountedFFmpeg) { $arguments += @('--mount', "type=bind,source=$mountedFFmpeg,target=/ffmpeg/ffmpeg,readonly") }
$probeArguments = @('--expect-gpu', $ExpectedGPU)
if ($mountedFFmpeg) { $probeArguments += @('--ffmpeg', '/ffmpeg/ffmpeg') }
if ($SystemControl) { $probeArguments += '--system-control' }
if ($LabName) {
    $exists = $false
    try { & docker container inspect $LabName *> $null; $exists = $LASTEXITCODE -eq 0 }
    catch { $exists = $false }
    if ($exists) { throw "Container '$LabName' already exists; choose another name to preserve it." }
    $arguments += @('-d', '--name', $LabName, '--entrypoint', 'sleep', $Image, 'infinity')
    & docker @arguments
    if ($LASTEXITCODE -ne 0) { throw 'GPU lab container could not start.' }
    & docker exec $LabName python3 /tools/probe.py @probeArguments
    Write-Host "Linux/WSL2 GPU lab remains running: $LabName"
} else {
    $arguments += @('--rm', $Image)
    $arguments += $probeArguments
    & docker @arguments
}
$status = $LASTEXITCODE
Write-Host "Linux/WSL2 report: $results/report.json"
exit $status
