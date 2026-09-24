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

# The guard's VOCABULARY, not its behaviour. Four verdicts - an observed crash
# fully identified, an observed crash the bisect could not finish attributing,
# a precaution, and a clean machine - which must never be confused in what the
# user is told. Two of the four review rounds on this branch were exactly that
# wording collapsing.
#
# Proves the phrases survive, NOT that each arm still prints its own: a
# refactor that made one arm print another's wording would pass here. That
# claim needs the arms observed on a machine with misbehaving drivers and lives
# in build-linux-x86_64.sh's Mesa block. Kept as a string search deliberately -
# on windows-aarch64 no runner here can execute the binary, so this is the only
# automated coverage it can get.
function Test-VulkanGuardVocabularyIntact {
    param([string]$Bin)
    $missing = New-Object System.Collections.Generic.List[string]
    # 'could not finish identifying which' is the arm 7b98498 added; it was
    # missing from this list until the Task 6 review caught it, so the arm
    # round 5 exists to create could have been deleted with this check green.
    $phrases = @(
        'vulkan disabled for this process',
        'could not finish identifying which',
        'not a report that anything is broken',
        'the loader configuration is unchanged',
        'NOMERCY_VK_GUARD_MS',
        'NOMERCY_VK_ICD_GUARD'
    )
    foreach ($p in $phrases) {
        if (-not (Test-BinaryContainsString -Bin $Bin -Needle $p)) { $missing.Add("    missing: `"$p`"") }
    }
    if ($missing.Count -gt 0) {
        return @{ Ok = $false; Output = ("FAIL: the guard's verdict vocabulary has been collapsed or lost:`n" + ($missing -join "`n")) }
    }
    return @{ Ok = $true }
}

# Nothing may regress for a user without a GPU. A CI runner is that user.
#
# Mirrors the bash vulkan_startup_ok, including the bug it was written to fix:
# this used to run `ffmpeg -version`, which never builds a filtergraph and so
# never reaches the ggml backend registry that actually crashes. It reported
# PASS for configurations measured to segfault a real filter. It now
# instantiates the whisper filter, whose init() runs the guard and
# ggml_backend_load_all() BEFORE it rejects a missing model, so the
# "No whisper model path specified" error is positive proof that ggml init was
# reached and survived.
#
# Which configurations may crash: the default, no-driver and NOMERCY_GGML_GPU=0
# arms must never crash. NOMERCY_VK_ICD_GUARD=0 means "opt out of the driver
# check", so on a machine whose drivers really do kill a static binary a crash
# there is the documented consequence, not a regression - it is reported, not
# failed. (Windows has no driver check at all, so in practice that arm is inert
# here; the shape is kept identical to the bash side on purpose.)
function Test-VulkanStartup {
    param([string]$FFmpegExe)

    # A Windows crash arrives as an NTSTATUS exception code, which PowerShell
    # surfaces as a large negative $LASTEXITCODE (0xC0000005 -> -1073741819).
    # NOT "code >= 128": ffmpeg exits with 256+AVERROR, so an ordinary
    # AVERROR(EINVAL) is 234 and reading that as a signal death would turn
    # every healthy run into a reported crash.
    $probe = {
        # $inSpec, NOT $input: $input is a PowerShell automatic variable and a
        # scriptblock rebinds it to its own pipeline input, so the parameter
        # reads as empty and ffmpeg gets -i with nothing after it. That is the
        # identical trap that kept check-windows.ps1 broken from the day it was
        # written, hit again here while fixing G1.
        param($exe, $inSpec)
        # ffmpeg writes everything to stderr, and capturing that from a NATIVE
        # command needs both halves of this: 2>&1 alone drops it when
        # $ErrorActionPreference is SilentlyContinue (measured: $out came back
        # empty and the marker was missed, which would have been read as
        # "could not instantiate"), and without .ToString() the merged items
        # are ErrorRecords rather than text.
        $ErrorActionPreference = 'Continue'
        if ($inSpec -eq 'lavfi') {
            $out = (& $exe -hide_banner -loglevel error -nostats `
                -f lavfi -i 'anullsrc=channel_layout=mono:sample_rate=16000' -t 0.1 `
                -af whisper -f null - 2>&1 | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
        } else {
            $out = (& $exe -hide_banner -loglevel error -nostats `
                -i $inSpec -t 0.1 -af whisper -f null - 2>&1 | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
        }
        $code = $LASTEXITCODE

        # Positive proof first, and it is the real discriminator.
        if ($out -match 'No whisper model path specified') { return @{ R = 0 } }

        # Then the exit code, and only a BOUNDED NTSTATUS exception range.
        # Three traps here, all of them measured rather than reasoned:
        #   * On Windows ffmpeg returns the raw AVERROR, so the missing model
        #     is -22, not the 234 a POSIX shell would show. "$code -lt 0"
        #     would call every healthy run a crash.
        #   * The range has an upper bound too. -22 unsigned is 0xFFFFFFEA,
        #     which is ABOVE 0xC0000000 -- so ">= 0xC0000000" misclassifies it
        #     just as badly. Real exception codes are 0xC0000005 (access
        #     violation), 0xC000001D, 0xC0000374 and friends: 0xC0000000 to
        #     0xCFFFFFFF. FFmpeg's own FFERRTAG values sit below that
        #     (AVERROR_INVALIDDATA is 0xBEBBB1B7), so neither end collides.
        #   * The bounds are written in decimal. A PowerShell hex literal of
        #     0xC0000000 is a NEGATIVE Int32, so "$u -ge 0xC0000000" is true
        #     for 0 -- which is how this check first reported a clean run as a
        #     segfault.
        $unsigned = if ($code -lt 0) { [long]$code + 4294967296L } else { [long]$code }
        if ($unsigned -ge 3221225472L -and $unsigned -le 3489660927L) {
            return @{ R = 1; Out = "crashed: exit $code (0x$(('{0:X8}' -f $unsigned)))`n$out" }
        }
        return @{ R = 2; Out = "could not instantiate the whisper filter here (exit $code); this configuration proved nothing`n$out" }
    }

    $inSpec = 'lavfi'
    if ((& $probe $FFmpegExe 'lavfi').R -eq 2) {
        # Minimal builds have no lavfi input device; write 0.1 s of 16 kHz
        # mono silence rather than quietly proving nothing.
        $wav = Join-Path ([System.IO.Path]::GetTempPath()) ("nm-vk-silence-" + [guid]::NewGuid().ToString('N') + '.wav')
        $n = 3200; $bytes = $n * 2
        $ms = New-Object System.IO.MemoryStream
        $bw = New-Object System.IO.BinaryWriter($ms)
        $bw.Write([char[]]'RIFF'); $bw.Write([int]($bytes + 36)); $bw.Write([char[]]'WAVE')
        $bw.Write([char[]]'fmt '); $bw.Write([int]16); $bw.Write([int16]1); $bw.Write([int16]1)
        $bw.Write([int]16000); $bw.Write([int]32000); $bw.Write([int16]2); $bw.Write([int16]16)
        $bw.Write([char[]]'data'); $bw.Write([int]$bytes); $bw.Write((New-Object byte[] $bytes))
        $bw.Flush(); [System.IO.File]::WriteAllBytes($wav, $ms.ToArray()); $bw.Dispose()
        $inSpec = $wav
    }

    # Label, may-crash, environment
    $cases = @(
        @{ Label = 'as the runner is';   MayCrash = $false; Vars = @{} },
        @{ Label = 'no driver findable'; MayCrash = $false; Vars = @{ VK_ICD_FILENAMES = '/nonexistent.json'; VK_DRIVER_FILES = '/nonexistent.json' } },
        @{ Label = 'gpu disabled';       MayCrash = $false; Vars = @{ NOMERCY_GGML_GPU = '0' } },
        @{ Label = 'guard disabled';     MayCrash = $true;  Vars = @{ NOMERCY_VK_ICD_GUARD = '0' } }
    )
    $notes = New-Object System.Collections.Generic.List[string]
    $inconclusive = $false
    foreach ($c in $cases) {
        foreach ($k in $c.Vars.Keys) { Set-Item -Path "Env:$k" -Value $c.Vars[$k] }
        $r = & $probe $FFmpegExe $inSpec
        foreach ($k in $c.Vars.Keys) { Remove-Item -Path "Env:$k" -ErrorAction SilentlyContinue }
        switch ($r.R) {
            0 { }
            1 {
                if ($c.MayCrash) {
                    $notes.Add("note: $($c.Label): this machine's drivers do kill a static binary, so the guard is load-bearing here - which is what opting out of it means, not a failure")
                } else {
                    return @{ Ok = $false; Crash = $true
                              Reason = "crashed instantiating a ggml filter ($($c.Label))"
                              Output = "FAIL: the binary died instantiating a ggml filter ($($c.Label))`n$($r.Out)" }
                }
            }
            default { $notes.Add("note: $($c.Label): $($r.Out)"); $inconclusive = $true }
        }
    }
    if ($inconclusive) {
        return @{ Ok = $false; Crash = $false; Reason = 'could not instantiate a ggml filter on this build'; Output = ($notes -join "`n") }
    }
    return @{ Ok = $true; Output = ($notes -join "`n") }
}
