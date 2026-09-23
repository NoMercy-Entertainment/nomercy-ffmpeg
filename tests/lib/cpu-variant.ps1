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
    $m = Select-String -Path $Bin -Pattern 'NOMERCY_GGML_CPU' -Encoding Latin1 -SimpleMatch -ErrorAction SilentlyContinue
    return $null -ne $m
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
