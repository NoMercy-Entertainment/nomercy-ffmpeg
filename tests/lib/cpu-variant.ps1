# Assert the ggml CPU variant dispatcher keeps working in the built binary.
# Mirrors tests/lib/cpu-variant.sh exactly -- see that file for the full
# rationale (no model in tests.sh/tests.ps1's own environment; darwin has no
# dispatcher to test). Kept in lockstep with the bash version deliberately.
#
# Test-CpuVariantStartup (the always-on half) is factored out so
# tests/smoke.ps1 -- the script CI actually runs on every Windows platform,
# unlike this one -- can assert the same startup guarantee without
# duplicating it. smoke.ps1 still makes its own darwin/baseline decision
# (there is none to make on Windows, but the shape matches smoke.sh) because
# it has its own Fail/Note reporting and its own cross-exec handling that
# must run first.

# --------------------------------------------------------------------------
# Searching a binary for a literal string, on any PowerShell
# --------------------------------------------------------------------------
# `Select-String -Encoding Latin1` works on pwsh 7 (which is what CI uses:
# main.yml runs smoke.ps1 with `shell: pwsh`) but is a PARAMETER BINDING
# ERROR on Windows PowerShell 5.1, whose -Encoding ValidateSet has no Latin1.
# -ErrorAction SilentlyContinue does not suppress that, so the cmdlet returns
# nothing and the caller reads "string not found" - a check that is red for
# everyone outside CI, for a reason that has nothing to do with the binary.
# That is the same shape as the windows CPU-variant check which sat broken
# from the day it was written because nobody trusted it enough to look.
#
# Encoding 28591 is ISO-8859-1 by codepage number, which both versions
# resolve, and a byte-for-byte mapping is what we want: we are looking for
# ASCII literals inside an executable, not decoding text. Read in chunks with
# an overlap so a 100 MB binary does not become a 200 MB string, and so a
# needle straddling a chunk boundary is still found.
function Test-BinaryContainsString {
    param([string]$Bin, [string]$Needle)
    $enc = [System.Text.Encoding]::GetEncoding(28591)
    $chunk = 1MB
    $overlap = 256    # comfortably longer than any needle below
    $buf = New-Object byte[] $chunk
    $stream = [System.IO.File]::OpenRead($Bin)
    try {
        $tail = ''
        while (($read = $stream.Read($buf, 0, $chunk)) -gt 0) {
            $text = $tail + $enc.GetString($buf, 0, $read)
            if ($text.Contains($Needle)) { return $true }
            $tail = if ($text.Length -gt $overlap) { $text.Substring($text.Length - $overlap) } else { $text }
        }
    } finally { $stream.Dispose() }
    return $false
}

# True if the platform tag carries no ggml cpu dispatcher at all (fixed
# instruction level, Task 6) -- NOMERCY_GGML_CPU is a no-op there.
function Test-CpuVariantIsDarwin {
    param([string]$Platform)
    return $Platform -match 'darwin'
}

# The baseline variant name for a platform tag: the one guaranteed to run on
# every machine the binary supports, x86_64 or aarch64.
function Get-CpuVariantBaseline {
    param([string]$Platform)
    if ($Platform -match 'aarch64|arm64') { return 'armv8.0' } else { return 'x64' }
}

# True if the binary was actually compiled with the dispatcher. Added after a
# first round of review pointed out that Test-CpuVariantStartup below is
# trivially true for ANY binary, old or new: an old, pre-dispatcher binary
# never reads NOMERCY_GGML_CPU at all, so it "starts cleanly" with it set for
# exactly the wrong reason, and a smoke check built only on that can never
# fail -- which manufactures false confidence instead of catching a
# regression. NOMERCY_GGML_CPU is read via getenv() exactly once, inside
# nm_select() (scripts/includes/ggml_cpu_dispatch.c), so the literal
# environment-variable name survives as a string constant in the binary even
# stripped of symbols -- confirmed empirically (see task-8 report): 0
# occurrences in a real pre-dispatcher release binary, 1 in a
# dispatcher-enabled build, on both the linux and windows binaries tested.
# Deliberately not asserted on darwin: NM_GGML_CPU_FIXED mode (Task 6)
# compiles out nm_select()/getenv() entirely there, so a darwin binary
# legitimately never contains this string -- that is the correct state, not
# a failure, so darwin skips this check the same way it skips the rest.
function Test-CpuVariantDispatcherPresent {
    param([string]$Bin)
    return Test-BinaryContainsString -Bin $Bin -Needle 'NOMERCY_GGML_CPU'
}

# The always-on guarantee: NOMERCY_GGML_CPU can never stop the binary from
# starting, unset, forced to the platform baseline, or forced to garbage.
# Needs no model, so it is reachable everywhere the binary can be executed at
# all. Returns @{ Ok = $true } or @{ Ok = $false; Reason = ...; Output = ... }.
function Test-CpuVariantStartup {
    param(
        [string]$FFmpegExe,
        [string]$Baseline
    )
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($value in @($null, $Baseline, 'definitely-not-a-real-variant')) {
        if ($null -ne $value) { $env:NOMERCY_GGML_CPU = $value } else { Remove-Item Env:NOMERCY_GGML_CPU -ErrorAction SilentlyContinue }
        $out = & $FFmpegExe -hide_banner -version 2>&1 | Out-String
        $code = $LASTEXITCODE
        Remove-Item Env:NOMERCY_GGML_CPU -ErrorAction SilentlyContinue
        if ($code -ne 0) {
            $lines.Add("FAIL: '$FFmpegExe -version' did not start with NOMERCY_GGML_CPU='$value' (exit $code)")
            $lines.Add($out)
            return @{ Ok = $false; Reason = "startup failed with NOMERCY_GGML_CPU='$value'"; Output = ($lines -join "`n") }
        }
    }
    return @{ Ok = $true }
}

function Test-CpuVariant {
    param(
        [string]$FFmpegExe,
        [string]$Platform
    )

    $lines = New-Object System.Collections.Generic.List[string]

    if (Test-CpuVariantIsDarwin $Platform) {
        return @{
            Status = 'Skip'
            Reason = "$Platform carries no ggml cpu dispatcher (fixed instruction level, Task 6); NOMERCY_GGML_CPU is a no-op there"
            Output = ''
        }
    }

    $baseline = Get-CpuVariantBaseline $Platform
    $lines.Add("platform baseline: $baseline")

    # --- always-on guarantee: the variable can never make a machine unbootable ---
    $startup = Test-CpuVariantStartup -FFmpegExe $FFmpegExe -Baseline $baseline
    if (-not $startup.Ok) {
        $lines.Add($startup.Output)
        return @{ Status = 'Fail'; Reason = $startup.Reason; Output = ($lines -join "`n") }
    }
    $lines.Add("startup guarantee held: default, forced baseline ($baseline) and a nonsense override all start cleanly")

    # --- model-gated: does the dispatcher actually pick what it claims to? ---
    $model = $env:TEST_MODEL
    $audio = $env:TEST_MP3
    $binDir = Split-Path -Parent $FFmpegExe

    if (-not $model) {
        $candidate = Join-Path $binDir 'spleeter-2stems-f16.gguf'
        if (Test-Path $candidate) { $model = $candidate }
    }
    if (-not $audio) {
        $candidate = Get-ChildItem -Path $binDir -Filter '*.mp3' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($candidate) { $audio = $candidate.FullName }
    }

    if (-not $model -or -not (Test-Path $model) -or -not $audio -or -not (Test-Path $audio)) {
        $lines.Add("SKIP: no stemsplit model available in this environment (published as a release asset, not shipped in the platform archive; set TEST_MODEL/TEST_MP3 to exercise the full check) - startup guarantee above still held")
        return @{ Status = 'Skip'; Reason = 'no stemsplit model available in this environment'; Output = ($lines -join "`n") }
    }
    $lines.Add("model: $model")
    $lines.Add("audio: $audio")

    # avfilter's option-string parser treats ':' as the key=value separator,
    # so an absolute Windows model path (e.g. "C:\Users\...") breaks parsing
    # right after the drive letter -- confirmed while verifying this test:
    # "-af stemsplit=model=C:\Users\...:stem=..." fails with "Error parsing a
    # filter description", and escaping just the colon isn't enough either
    # (the backslash path separators then collide with avfilter's own
    # backslash-escaping). Sidestepping both by running ffmpeg with its
    # working directory set to the model's folder and passing only the leaf
    # filename avoids the whole class of escaping bugs.
    $modelDir = Split-Path -Parent $model
    $modelLeaf = Split-Path -Leaf $model

    function Invoke-CpuVariantProbe {
        param([string]$Value)
        if ($Value) { $env:NOMERCY_GGML_CPU = $Value } else { Remove-Item Env:NOMERCY_GGML_CPU -ErrorAction SilentlyContinue }
        $af = "stemsplit=model=${modelLeaf}:stem=accompaniment,ametadata=mode=print:key=lavfi.stemsplit.cpu_variant"
        Push-Location $modelDir
        try {
            $out = & $FFmpegExe -hide_banner -loglevel info -nostats -t 8 -i $audio -vn -af $af -f null - 2>&1 | Out-String
        } finally {
            Pop-Location
        }
        Remove-Item Env:NOMERCY_GGML_CPU -ErrorAction SilentlyContinue
        $m = [regex]::Match($out, 'lavfi\.stemsplit\.cpu_variant=([a-z0-9.+_]+)')
        if ($m.Success) { return $m.Groups[1].Value } else { return '' }
    }

    $autoVariant = Invoke-CpuVariantProbe -Value $null
    if (-not $autoVariant) {
        $lines.Add("FAIL: no lavfi.stemsplit.cpu_variant metadata with automatic selection (old, dispatcher-less binary?)")
        return @{ Status = 'Fail'; Reason = 'no cpu_variant metadata with automatic selection'; Output = ($lines -join "`n") }
    }
    $lines.Add("automatic: $autoVariant")

    $forcedVariant = Invoke-CpuVariantProbe -Value $baseline
    if ($forcedVariant -ne $baseline) {
        $lines.Add("FAIL: NOMERCY_GGML_CPU=$baseline selected '$forcedVariant', not '$baseline'")
        return @{ Status = 'Fail'; Reason = "forced baseline selected '$forcedVariant'"; Output = ($lines -join "`n") }
    }
    $lines.Add("forced baseline: $forcedVariant")

    $bogusVariant = Invoke-CpuVariantProbe -Value 'definitely-not-a-real-variant'
    if ($bogusVariant -ne $autoVariant) {
        $lines.Add("FAIL: an unknown NOMERCY_GGML_CPU fell back to '$bogusVariant', not the automatic choice '$autoVariant'")
        return @{ Status = 'Fail'; Reason = "unknown override fell back to '$bogusVariant'"; Output = ($lines -join "`n") }
    }
    $lines.Add("unknown override falls back to automatic: $bogusVariant")

    $lines.Add("selected $autoVariant automatically; baseline override selects $baseline; unknown override falls back safely")
    return @{ Status = 'Pass'; Reason = ''; Output = ($lines -join "`n") }
}

# --------------------------------------------------------------------------
# ggml Vulkan GPU backend (2026-09-23-ggml-vulkan-backend plan, Task 6)
# --------------------------------------------------------------------------
# Mirrors the Vulkan half of tests/lib/cpu-variant.sh exactly. See that file
# for the full rationale behind each one; the comments here are deliberately
# short so the two stay easy to diff.
#
# On the PowerShell side the only platforms that reach these are
# windows-x86_64 and windows-aarch64, so in practice
# Test-VulkanPlatformHasBackend is always true here and
# Test-VulkanPlatformHasGuard is always false. Both are written out in full
# anyway rather than hard-coded: the value of the guard check on Windows is
# precisely that it asserts ABSENCE, and a hard-coded "Windows has no guard"
# would assert nothing at all.

# Four of the seven platforms carry Vulkan. darwin gets Metal in a later
# phase; freebsd links statically against a libc.a whose dlopen() always
# fails, so the loader shim could never open a loader there.
function Test-VulkanPlatformHasBackend {
    param([string]$Platform)
    return ($Platform -notmatch 'darwin' -and $Platform -notmatch 'freebsd')
}

# The fork-and-probe ICD guard is compiled only for non-Windows, non-Apple.
function Test-VulkanPlatformHasGuard {
    param([string]$Platform)
    return ($Platform -notmatch 'windows' -and $Platform -notmatch 'darwin' -and $Platform -notmatch 'freebsd')
}

# Both halves must be there: ggml-vulkan itself, and the loader shim that
# resolves its three undefined loader symbols. A build that kept the backend
# and lost the shim could not open a loader on any machine.
function Test-VulkanBackendPresent {
    param([string]$Bin)
    foreach ($needle in @('ggml_vulkan', 'vkGetInstanceProcAddr')) {
        if (-not (Test-BinaryContainsString -Bin $Bin -Needle $needle)) { return $false }
    }
    return $true
}

# A notice only the guarded code can print. NOT 'software rasteriser', which
# is also in nm_vk_scan's device-name table and is therefore present in a
# correct Windows binary whose guard is correctly absent.
function Test-VulkanGuardPresent {
    param([string]$Bin)
    return Test-BinaryContainsString -Bin $Bin -Needle 'crash a statically linked'
}

# The guard's three verdicts - an observed crash, a precaution, and a clean
# machine - must never be confused in what the user is told. Two of the four
# review rounds on this branch were exactly that wording collapsing.
function Test-VulkanGuardVerdictsDistinct {
    param([string]$Bin)
    $missing = New-Object System.Collections.Generic.List[string]
    $phrases = @(
        'vulkan disabled for this process',
        'not a report that anything is broken',
        'the loader configuration is unchanged',
        'NOMERCY_VK_GUARD_MS',
        'NOMERCY_VK_ICD_GUARD'
    )
    foreach ($p in $phrases) {
        if (-not (Test-BinaryContainsString -Bin $Bin -Needle $p)) { $missing.Add("    missing: `"$p`"") }
    }
    if ($missing.Count -gt 0) {
        return @{ Ok = $false; Output = ("FAIL: the guard's verdict wording has been collapsed or lost:`n" + ($missing -join "`n")) }
    }
    return @{ Ok = $true }
}

# Nothing may regress for a user without a GPU. A CI runner is that user.
function Test-VulkanStartup {
    param([string]$FFmpegExe)
    $cases = @(
        @{ Label = 'as the runner is';   Vars = @{} },
        @{ Label = 'no driver findable'; Vars = @{ VK_ICD_FILENAMES = '/nonexistent.json'; VK_DRIVER_FILES = '/nonexistent.json' } },
        @{ Label = 'guard disabled';     Vars = @{ NOMERCY_VK_ICD_GUARD = '0' } },
        @{ Label = 'gpu disabled';       Vars = @{ NOMERCY_GGML_GPU = '0' } }
    )
    foreach ($c in $cases) {
        foreach ($k in $c.Vars.Keys) { Set-Item -Path "Env:$k" -Value $c.Vars[$k] }
        $out = & $FFmpegExe -hide_banner -version 2>&1 | Out-String
        $code = $LASTEXITCODE
        foreach ($k in $c.Vars.Keys) { Remove-Item -Path "Env:$k" -ErrorAction SilentlyContinue }
        if ($code -ne 0) {
            return @{ Ok = $false
                      Reason = "startup failed ($($c.Label))"
                      Output = "FAIL: '$FFmpegExe -version' did not start ($($c.Label)), exit $code`n$out" }
        }
    }
    return @{ Ok = $true }
}
