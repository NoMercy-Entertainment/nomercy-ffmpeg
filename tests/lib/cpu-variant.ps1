# Assert the ggml CPU variant dispatcher keeps working in the built binary.
# Mirrors tests/lib/cpu-variant.sh exactly -- see that file for the full
# rationale (no model in tests.sh/tests.ps1's own environment; darwin has no
# dispatcher to test). Kept in lockstep with the bash version deliberately.
function Test-CpuVariant {
    param(
        [string]$FFmpegExe,
        [string]$Platform
    )

    $lines = New-Object System.Collections.Generic.List[string]

    if ($Platform -match 'darwin') {
        return @{
            Status = 'Skip'
            Reason = "$Platform carries no ggml cpu dispatcher (fixed instruction level, Task 6); NOMERCY_GGML_CPU is a no-op there"
            Output = ''
        }
    }

    $baseline = if ($Platform -match 'aarch64|arm64') { 'armv8.0' } else { 'x64' }
    $lines.Add("platform baseline: $baseline")

    # --- always-on guarantee: the variable can never make a machine unbootable ---
    foreach ($value in @($null, $baseline, 'definitely-not-a-real-variant')) {
        if ($null -ne $value) { $env:NOMERCY_GGML_CPU = $value } else { Remove-Item Env:NOMERCY_GGML_CPU -ErrorAction SilentlyContinue }
        $out = & $FFmpegExe -hide_banner -version 2>&1 | Out-String
        $code = $LASTEXITCODE
        Remove-Item Env:NOMERCY_GGML_CPU -ErrorAction SilentlyContinue
        if ($code -ne 0) {
            $lines.Add("FAIL: '$FFmpegExe -version' did not start with NOMERCY_GGML_CPU='$value' (exit $code)")
            $lines.Add($out)
            return @{ Status = 'Fail'; Reason = "startup failed with NOMERCY_GGML_CPU='$value'"; Output = ($lines -join "`n") }
        }
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
