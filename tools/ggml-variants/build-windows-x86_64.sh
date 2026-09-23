#!/bin/bash
# Cross-build a minimal windows-x86_64 ffmpeg against the variant-enabled
# whisper. The container only builds; the resulting ffmpeg.exe is a real
# Windows PE binary and must be run on the Windows host (Git Bash or
# PowerShell), since the Linux build container cannot execute it.
#
# DEVIATION from the task-5 brief's version of this file: the brief's draft
# exported NM_NM=x86_64-w64-mingw32-nm / NM_OBJCOPY=.../ NM_LD=... in *this*
# host-side script before calling build-common.sh. That has no effect: the
# actual build (and the nm_pack_variant call) happens inside the container
# build-common.sh launches, and scripts/48-whisper.sh sets NM_NM/NM_OBJCOPY/
# NM_LD itself from the container's own NM/CROSS_PREFIX/LD (lifted from
# ffmpeg-windows-x86_64.dockerfile's ENV lines: NM=x86_64-w64-mingw32-gcc-nm,
# CROSS_PREFIX=x86_64-w64-mingw32-, LD=x86_64-w64-mingw32-ld). Host-side
# exports of these three names never reach that container. Left out here to
# avoid implying they do something; see task-5-report.md for the full
# reasoning and the (dead-code) diff against the brief's draft.
set -eu
REPO="${REPO:-$(cd "$(dirname "$0")/../.." && pwd)}"
WORK="${WORK:-/tmp/nm-windows-x86_64}"

mkdir -p "${WORK}"

# DEVIATION from the brief: build-common.sh needed two fixes to work at all
# on windows-x86_64 (see task-5-report.md for the full story):
#   1. the base image has no mingw-w64 cross toolchain -- that is installed
#      by a RUN apt-get in ffmpeg-windows-x86_64.dockerfile, a layer this
#      harness never builds (it only lifts the dockerfile's ENV lines).
#   2. 48-whisper.sh only turns on GGML_BLAS if ${PREFIX}/lib/libopenblas.a
#      already exists -- but nothing in this harness (build-common.sh runs
#      48-whisper.sh/60-stemsplit.sh only, not the full init.sh pipeline
#      that would normally build OpenBLAS first) ever puts it there, so the
#      windows-x64 whisper.pc branch would unconditionally list -lggml-blas
#      for a ggml-blas.a that was never built.
# build-common.sh now installs the mingw-w64 packages itself when
# TARGET_OS=windows, and accepts an optional NM_SEED_PREFIX host directory
# copied into PREFIX before the build -- used here to seed a prebuilt
# windows-x86_64 OpenBLAS (libopenblas.a + headers) out of the project's
# ffblas-vol docker volume, exactly what a real earlier-numbered-script run
# would have put there.
if [[ -z "${NM_SEED_PREFIX:-}" && "${NM_SKIP_OPENBLAS_SEED:-0}" != "1" ]]; then
    seed="${WORK}/openblas-seed"
    if [[ ! -f "${seed}/lib/libopenblas.a" ]]; then
        mkdir -p "${seed}/lib/pkgconfig" "${seed}/include"
        MSYS_NO_PATHCONV=1 docker run --rm -v ffblas-vol:/vol:ro -v "$(cygpath -w "${seed}")":/out alpine sh -c '
            set -eu
            [[ -f /vol/pfx-cur/lib/libopenblas.a ]] || { echo "no prebuilt windows OpenBLAS in ffblas-vol:/pfx-cur"; exit 1; }
            cp /vol/pfx-cur/lib/libopenblas.a /out/lib/
            cp -r /vol/pfx-cur/include/openblas /out/include/
            cp /vol/pfx-cur/lib/pkgconfig/openblas.pc /out/lib/pkgconfig/ 2>/dev/null || true
        '
    fi
    export NM_SEED_PREFIX="${seed}"
fi

# Build whisper + variants exactly as scripts/48-whisper.sh does for windows
# (COFF packing, x64/sse42/ivybridge/haswell matrix, OpenBLAS via ggml-blas),
# then a minimal ffmpeg against it.
bash "${REPO}/tools/ggml-variants/build-common.sh" windows x86_64 "${WORK}"

[[ -f "${WORK}/ffmpeg.exe" ]] || { echo "FAIL: ${WORK}/ffmpeg.exe was not built"; exit 1; }

cat > "${WORK}/check-windows.ps1" <<'PS'
param([string]$Dir = $PSScriptRoot)
$ff = Join-Path $Dir 'ffmpeg.exe'
$model = Join-Path $Dir 'spleeter-2stems-f16.gguf'
$input = Join-Path $Dir 'input.mp3'
if ((Get-Item $ff).Length -eq 0) { Write-Host 'FAIL: ffmpeg.exe is empty - COFF packing renamed section symbols'; exit 1 }

function Run-Split([string]$variant, [string]$out) {
    $env:NOMERCY_GGML_CPU = $variant
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & $ff -hide_banner -loglevel error -nostats -y -t 30 -i $input -vn `
        -af "stemsplit=model=$model:stem=accompaniment" -f wav $out | Out-Null
    $sw.ElapsedMilliseconds
}
$auto = Run-Split '' (Join-Path $Dir 'auto.wav')
$base = Run-Split 'x64' (Join-Path $Dir 'base.wav')
$env:NOMERCY_GGML_CPU = ''
$logged = (& $ff -hide_banner -v verbose -nostats -t 12 -i $input -vn `
    -af "stemsplit=model=$model:stem=accompaniment" -f wav NUL 2>&1 |
    Select-String -Pattern "cpu variant '([a-z0-9.+_]+)'" | Select-Object -First 1).Matches.Value
"  auto: $auto ms, forced baseline: $base ms"
"  logged: $logged"

$fail = 0
if ($auto -ge ($base * 2 / 3)) { Write-Host '  FAIL: automatic choice is not faster than baseline'; $fail = 1 }
if (-not $logged)              { Write-Host '  FAIL: no variant logged'; $fail = 1 }
if ($fail -eq 0) { Write-Host 'PASS' } else { exit 1 }
PS

echo "built ${WORK}/ffmpeg.exe - now run check-windows.ps1 (or the bash equivalent) on the Windows host"
