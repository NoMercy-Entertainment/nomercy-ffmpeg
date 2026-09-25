# Minimal CI smoke gate for Windows: assert ffmpeg.exe/ffprobe.exe run, report
# the expected version, and exit cleanly. NOT the full codec suite (tests.ps1).
#
# Cross-exec note (mirrors the same handling in smoke.sh): windows-aarch64 is
# built for ARM64, and the windows-latest runner is x64. Windows-on-ARM can run
# x64 binaries through emulation, but not the reverse, so an ARM64 PE cannot be
# executed here at all. For those platforms we never execute — we validate the
# PE header (MZ/PE signatures + Machine field) instead, which also catches a
# mislabeled or truncated artifact. Native platforms are always executed, so a
# broken native binary can never slip through.
param(
    [Parameter(Mandatory = $true)][string]$Workspace,
    [Parameter(Mandatory = $true)][string]$ExpectedVersion,
    [string]$Platform = ''
)
$ErrorActionPreference = 'Stop'

$HERE = Split-Path -Parent $PSCommandPath
. "$HERE/lib/cpu-variant.ps1"

function Fail($msg) { Write-Host "❌ $msg"; exit 1 }
function Note($msg) { Write-Host "ℹ️  $msg" }

# ggml CPU variant dispatcher: two checks. Defined up here, before the
# cross-exec early-return below, because the first of them needs no
# execution at all and must run even for a binary this runner cannot execute
# — see the call sites for why.
#
# 1. The binary must actually carry the dispatcher. This is what makes the
#    check below able to fail at all: a binary that never reads
#    NOMERCY_GGML_CPU "starts cleanly" with it set to anything, trivially, so
#    a check built only on process exit codes can never distinguish a
#    dispatcher-enabled build from an old one that predates this feature --
#    it would always pass, manufacturing confidence rather than catching a
#    regression. Test-CpuVariantDispatcherPresent searches the binary for the
#    literal env-var name instead (see its comment in lib/cpu-variant.ps1 for
#    why that's reliable even stripped, and the empirical before/after
#    counts). Skipped on darwin: it legitimately never contains that string
#    (darwin never reaches THIS script — it's routed to smoke.sh instead,
#    which has the identical check; this PowerShell copy only exists so the
#    shape matches smoke.sh, in case Windows ever gains a darwin-like fixed
#    build). It is a search over the file, not an execution, so unlike the
#    startup check below it also runs for windows-aarch64, which this x64
#    runner cannot execute at all — that platform has never actually been
#    executed by any CI runner here, so skipping this check for it would
#    leave it with zero automated dispatcher coverage, same reasoning as
#    smoke.sh's linux-aarch64/freebsd-x86_64 cross-exec platforms.
#
# 2. NOMERCY_GGML_CPU must never stop the binary from starting, unset, forced
#    to the platform baseline (old hardware keeps working), or forced to
#    garbage (a bad override can't brick a machine). Needs no model, so
#    unlike tests/tests.ps1's fuller, model-gated check (run manually, on
#    real hardware, with a real model) this runs on every CI build that can
#    actually execute the binary.
function Assert-CpuVariantDispatcherPresent($bin, $platform) {
    if (Test-CpuVariantIsDarwin $platform) {
        Note "$(Split-Path $bin -Leaf): $platform carries no ggml cpu dispatcher (fixed instruction level); dispatcher-presence check skipped"
        return
    }

    if (Test-CpuVariantDispatcherPresent -Bin $bin) {
        Write-Host "✅ $(Split-Path $bin -Leaf): carries the ggml cpu dispatcher (NOMERCY_GGML_CPU compiled in)"
    } else {
        Fail "$(Split-Path $bin -Leaf): does not carry the ggml cpu dispatcher (NOMERCY_GGML_CPU not found in the binary)"
    }
}

function Assert-CpuVariantStartup($bin, $platform) {
    if (Test-CpuVariantIsDarwin $platform) {
        Note "$(Split-Path $bin -Leaf): $platform carries no ggml cpu dispatcher (fixed instruction level); NOMERCY_GGML_CPU startup check skipped"
        return
    }

    $baseline = Get-CpuVariantBaseline $platform
    $result = Test-CpuVariantStartup -FFmpegExe $bin -Baseline $baseline
    if ($result.Ok) {
        Write-Host "✅ $(Split-Path $bin -Leaf): starts cleanly with NOMERCY_GGML_CPU unset, forced to baseline ($baseline), and forced to a nonsense value"
    } else {
        Write-Host $result.Output
        Fail "$(Split-Path $bin -Leaf): NOMERCY_GGML_CPU startup guarantee failed (baseline $baseline)"
    }
}

# Platforms whose binary is built for a different CPU arch than this runner and
# therefore cannot be executed on it. Maps platform to the expected PE Machine
# value. Keep in sync with the build matrix if another Windows arch is added.
function Get-CrossExecMachine($platform) {
    switch ($platform) {
        'windows-aarch64' { return 0xAA64 }  # IMAGE_FILE_MACHINE_ARM64
        default           { return $null }
    }
}

# Reads the COFF Machine field: e_lfanew is a 4-byte LE offset at 0x3C, the
# "PE\0\0" signature sits there, and Machine is the 2 bytes immediately after.
function Get-PeMachine($path) {
    $fs = [System.IO.File]::OpenRead($path)
    try {
        $br = New-Object System.IO.BinaryReader($fs)
        if ($fs.Length -lt 0x40) { return $null }
        $fs.Position = 0
        if ($br.ReadUInt16() -ne 0x5A4D) { return $null }   # 'MZ'
        $fs.Position = 0x3C
        $peOff = $br.ReadInt32()
        if ($peOff -le 0 -or ($peOff + 6) -gt $fs.Length) { return $null }
        $fs.Position = $peOff
        if ($br.ReadUInt32() -ne 0x00004550) { return $null }  # 'PE\0\0'
        return $br.ReadUInt16()
    } finally { $fs.Close() }
}

function Assert-PeMachine($bin, $expected) {
    $got = Get-PeMachine $bin
    if ($null -eq $got) { Fail "$(Split-Path $bin -Leaf): not a valid PE image" }
    if ($got -ne $expected) {
        Fail ("{0}: PE machine=0x{1:X4}, expected 0x{2:X4}" -f (Split-Path $bin -Leaf), $got, $expected)
    }
}

$ffmpeg  = Join-Path $Workspace 'ffmpeg.exe'
$ffprobe = Join-Path $Workspace 'ffprobe.exe'

if (-not (Test-Path $ffmpeg))  { Fail "ffmpeg.exe not found at $ffmpeg" }
if (-not (Test-Path $ffprobe)) { Fail "ffprobe.exe not found at $ffprobe" }
if ((Get-Item $ffmpeg).Length  -eq 0) { Fail 'ffmpeg.exe is empty' }
if ((Get-Item $ffprobe).Length -eq 0) { Fail 'ffprobe.exe is empty' }

# ggml Vulkan GPU backend, mirroring smoke.sh. The presence checks are string
# searches over the file, so they run for windows-aarch64 too - the platform
# no runner here can execute and therefore the one with the least other
# evidence behind it.
function Assert-VulkanBackendPresent($bin, $platform) {
    if (-not (Test-VulkanPlatformHasBackend $platform)) {
        Note "$(Split-Path $bin -Leaf): $platform carries no Vulkan by design; check skipped"
        return
    }

    if (Test-VulkanBackendPresent -Bin $bin) {
        Write-Host "✅ $(Split-Path $bin -Leaf): ggml Vulkan backend and loader shim are both linked in"
    } else {
        Fail "$(Split-Path $bin -Leaf): does not carry the ggml Vulkan backend (or the loader shim it needs)"
    }

    # Asserted in BOTH directions. On Windows the guard must be absent, and an
    # assertion that only ever checks for presence would pass a Windows build
    # that had wrongly acquired it.
    if (Test-VulkanPlatformHasGuard $platform) {
        if (-not (Test-VulkanGuardPresent -Bin $bin)) {
            Fail "$(Split-Path $bin -Leaf): the ICD guard is missing from $platform, which needs it"
        }
        $verdicts = Test-VulkanGuardVocabularyIntact -Bin $bin
        if (-not $verdicts.Ok) {
            Write-Host $verdicts.Output
            Fail "$(Split-Path $bin -Leaf): the ICD guard's verdict vocabulary has been lost on $platform"
        }
        Write-Host "✅ $(Split-Path $bin -Leaf): ICD guard present, and all four verdict messages plus both escape hatches survive in the binary"
    } else {
        if (Test-VulkanGuardPresent -Bin $bin) {
            Fail "$(Split-Path $bin -Leaf): the ICD guard is compiled into $platform, which must not have it"
        }
        Write-Host "✅ $(Split-Path $bin -Leaf): ICD guard correctly absent on $platform"
    }
}

# Nothing may regress for a user without a GPU - the constraint that outranks
# every performance goal on this branch. A CI runner has no GPU.
function Assert-VulkanStartup($bin, $platform) {
    if (-not (Test-VulkanPlatformHasBackend $platform)) {
        Note "$(Split-Path $bin -Leaf): $platform carries no Vulkan; startup check skipped"
        return
    }
    $result = Test-VulkanStartup -FFmpegExe $bin
    if ($result.Ok) {
        if ($result.Output) { Write-Host $result.Output }
        Write-Host "✅ $(Split-Path $bin -Leaf): a ggml filter initialises and returns with no driver, with the loader pointed at nothing, and with the GPU switched off"
    } elseif ($result.Crash) {
        Write-Host $result.Output
        Fail "$(Split-Path $bin -Leaf): crashes initialising a ggml filter on a machine with no usable GPU driver"
    } else {
        Write-Host $result.Output
        Note "$(Split-Path $bin -Leaf): could not instantiate a ggml filter on this build - the no-GPU guarantee is NOT asserted here"
    }
}

# Runs regardless of whether this runner can execute the binary at all — see
# the comment on Assert-CpuVariantDispatcherPresent above for why it has to
# come before the cross-exec early-return, not after it.
Assert-CpuVariantDispatcherPresent $ffmpeg $Platform
Assert-VulkanBackendPresent $ffmpeg $Platform

# Cross-exec platforms: never execute — validate PE headers and stop here.
$machine = Get-CrossExecMachine $Platform
if ($null -ne $machine) {
    Assert-PeMachine $ffmpeg  $machine
    Assert-PeMachine $ffprobe $machine
    Note ("Cross-exec ({0}): binaries cannot run on this x64 runner — validated PE headers instead (machine=0x{1:X4})." -f $Platform, $machine)
    Write-Host '✅ Smoke (presence + PE header) passed for cross-exec binaries.'
    exit 0
}

function Assert-Version($bin, $banner) {
    $out = & $bin -version 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Write-Host $out; Fail "$bin -version exited $LASTEXITCODE" }
    if ($out -notmatch [regex]::Escape($banner)) { Write-Host $out; Fail "missing '$banner' banner" }
    if ($out -notmatch [regex]::Escape($ExpectedVersion)) { Write-Host $out; Fail "expected version $ExpectedVersion not found" }
    Write-Host "✅ $(Split-Path $bin -Leaf) reports version $ExpectedVersion and exits 0"
}

Assert-Version $ffmpeg  'ffmpeg version'
Assert-Version $ffprobe 'ffprobe version'

# Needs to actually execute the binary, so only reachable here, past the
# cross-exec early-return.
Assert-CpuVariantStartup $ffmpeg $Platform
Assert-VulkanStartup $ffmpeg $Platform
Write-Host '✅ Smoke test passed.'
exit 0
