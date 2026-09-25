#!/bin/bash
# Assert the LINKED ffmpeg binary still carries every ggml CPU variant this
# platform packed.
#
# COMDAT folding at the real ffmpeg link is this design's named silent
# failure mode: every check up to this point (nm_pack_variant's own
# leftover-symbol assertions, 48-whisper.sh's post-archive reg-symbol count)
# runs against libggml-cpu-variants.a in isolation, before it is ever linked
# alongside libwhisper.a/libggml-base.a/the rest of ffmpeg. A linker that
# folds two variants' COMDAT groups together produces a binary that still
# links and runs -- it just silently loses one variant's code, keeping only
# its (now-shared) prefixed symbol name pointing at another variant's
# implementation. Nothing upstream of the real link can catch that; this has
# to run against the actual linked ffmpeg.
#
# Run this after `make -j` has produced /build/ffmpeg/ffmpeg_g (ffmpeg's own
# Makefile links ffmpeg_g first, unstripped, then copies+strips it into
# ffmpeg as part of the same `make` invocation) and before that build
# directory is removed. Must run on every platform that packs ggml CPU
# variants (linux-x86_64, linux-aarch64, freebsd-x86_64, windows-x86_64,
# windows-aarch64) and must NOT run on darwin, which carries no variants by
# design -- it builds ggml at one fixed instruction level instead (see
# ggml_cpu_dispatch.c's NM_GGML_CPU_FIXED mode) -- so this script exits
# cleanly without checking anything there.
#
# Expects PREFIX, NM and TARGET_OS already exported by the calling
# dockerfile, matching how 48-whisper.sh itself is invoked.
set -eu

if [[ ${TARGET_OS} == "darwin" ]]; then
    echo "verify_ggml_cpu_link: skipping, darwin carries no ggml cpu variants by design"
    exit 0
fi

nm_g=$(find /build/ffmpeg -maxdepth 1 -name 'ffmpeg_g*' 2>/dev/null | head -1)
if [[ -z ${nm_g} ]]; then
    echo "verify_ggml_cpu_link: no ffmpeg_g in /build/ffmpeg -- run this right after 'make' links ffmpeg and before /build/ffmpeg is removed" >&2
    exit 1
fi

variants_lib="${PREFIX}/lib/libggml-cpu-variants.a"
if [[ ! -f ${variants_lib} ]]; then
    echo "verify_ggml_cpu_link: ${variants_lib} not found; every non-darwin platform is expected to have packed ggml cpu variants (see 48-whisper.sh)" >&2
    exit 1
fi

nm_tool="${NM:-nm}"

# The set of distinct prefixed entry points the variant archive is SUPPOSED
# to contribute to the link, established independently of anything the link
# itself did.
expected=$("${nm_tool}" --defined-only "${variants_lib}" 2>/dev/null \
    | grep -oE "nm_v[0-9]+_ggml_backend_cpu_reg" | sort -u | wc -l)
if [[ ${expected} -eq 0 ]]; then
    echo "verify_ggml_cpu_link: no prefixed ggml_backend_cpu_reg symbols found in ${variants_lib}; ${nm_tool} may have failed silently" >&2
    exit 1
fi

# What actually reached the linked, pre-strip binary.
got=$("${nm_tool}" --defined-only "${nm_g}" 2>/dev/null \
    | grep -oE "nm_v[0-9]+_ggml_backend_cpu_reg" | sort -u | wc -l)
unprefixed=$("${nm_tool}" --defined-only "${nm_g}" 2>/dev/null \
    | grep -cE " T ggml_backend_cpu_reg$")

echo "verify_ggml_cpu_link: ${variants_lib} contributes ${expected} distinct variants; ${nm_g} carries ${got} distinct + ${unprefixed} unprefixed ggml_backend_cpu_reg"

if [[ ${got} -ne ${expected} || ${unprefixed} -ne 1 ]]; then
    echo "verify_ggml_cpu_link: FAIL -- the ffmpeg link folded ggml CPU variants together. Expected ${expected} distinct prefixed ggml_backend_cpu_reg symbols and exactly 1 unprefixed copy, found ${got} distinct and ${unprefixed} unprefixed in ${nm_g}." >&2
    exit 1
fi

echo "verify_ggml_cpu_link: OK, all ${expected} ggml cpu variants survived the ffmpeg link"
