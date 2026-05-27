# Minimal CI smoke gate for Windows: assert ffmpeg.exe/ffprobe.exe run, report
# the expected version, and exit cleanly. NOT the full codec suite (tests.ps1).
param(
    [Parameter(Mandatory = $true)][string]$Workspace,
    [Parameter(Mandatory = $true)][string]$ExpectedVersion
)
$ErrorActionPreference = 'Stop'

function Fail($msg) { Write-Host "❌ $msg"; exit 1 }

$ffmpeg  = Join-Path $Workspace 'ffmpeg.exe'
$ffprobe = Join-Path $Workspace 'ffprobe.exe'

if (-not (Test-Path $ffmpeg))  { Fail "ffmpeg.exe not found at $ffmpeg" }
if (-not (Test-Path $ffprobe)) { Fail "ffprobe.exe not found at $ffprobe" }

function Assert-Version($bin, $banner) {
    $out = & $bin -version 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Write-Host $out; Fail "$bin -version exited $LASTEXITCODE" }
    if ($out -notmatch [regex]::Escape($banner)) { Write-Host $out; Fail "missing '$banner' banner" }
    if ($out -notmatch [regex]::Escape($ExpectedVersion)) { Write-Host $out; Fail "expected version $ExpectedVersion not found" }
    Write-Host "✅ $(Split-Path $bin -Leaf) reports version $ExpectedVersion and exits 0"
}

Assert-Version $ffmpeg  'ffmpeg version'
Assert-Version $ffprobe 'ffprobe version'
Write-Host '✅ Smoke test passed.'
exit 0
