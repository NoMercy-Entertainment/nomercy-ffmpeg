#!/bin/bash

#/******************************/#
#/*  Made by Phillippe Pelzer  */#
#/*  https://github.com/Fill84 */#
#/******************************/#

# The lyricsalign audio filter (#126): known lyric text placed on a vocal stem
# by CTC forced alignment, on the ggml whisper.cpp already carries
# (scripts/48-whisper.sh) and the espeak-ng of scripts/65-espeak-ng.sh. The
# filter and its headers live in scripts/includes and are copied next to the
# other libavfilter sources; the build steps below mirror 61-trailing-silence.sh.

rm -f /ffmpeg_build.log
touch /ffmpeg_build.log

for f in af_lyricsalign.c nm_lyricsalign_align.h nm_lyricsalign_phones.h nm_lyricsalign_unicode.inc \
         nm_lyricsalign_w2v2.h nm_ggml_threads.h nm_whisper_words.h; do
    cp "/scripts/includes/${f}" "/build/ffmpeg/libavfilter/${f}" \
        || { log "  ✗ ERROR: copying ${f} into libavfilter failed"; exit 1; }
done
log "Step 0: sources copied into libavfilter"

for need in "${PREFIX}/lib/libespeak-ng.a" "${PREFIX}/include/espeak-ng/speak_lib.h" "${PREFIX}/lib/pkgconfig/whisper.pc"; do
    if [[ ! -f "${need}" ]]; then
        log "  ✗ ERROR: ${need} is missing (65-espeak-ng.sh and 48-whisper.sh must have run)"
        exit 1
    fi
done

log "Step 1: Adding extern declaration to allfilters.c"
if ! grep -q "ff_af_lyricsalign" /build/ffmpeg/libavfilter/allfilters.c; then
    sed -i '0,/^extern const FFFilter ff_af_volumedetect;$/s//&\nextern const FFFilter ff_af_lyricsalign;/' /build/ffmpeg/libavfilter/allfilters.c
    log "  ✓ Added extern declaration"
else
    log "  ✓ Extern declaration already exists"
fi
if grep -q "ff_af_lyricsalign" /build/ffmpeg/libavfilter/allfilters.c; then
    log "  ✓ Verified in allfilters.c"
else
    log "  ✗ ERROR: Verification failed!"
    exit 1
fi

log "Step 2: Adding to Makefile"
if ! grep -q "af_lyricsalign.o" /build/ffmpeg/libavfilter/Makefile; then
    sed -i '/^OBJS-\$(CONFIG_ABENCH_FILTER)/a\
OBJS-$(CONFIG_LYRICSALIGN_FILTER)        += af_lyricsalign.o' /build/ffmpeg/libavfilter/Makefile
    log "  ✓ Added to Makefile"
else
    log "  ✓ Makefile entry already exists"
fi
if grep -q "af_lyricsalign.o" /build/ffmpeg/libavfilter/Makefile; then
    log "  ✓ Verified in Makefile"
else
    log "  ✗ ERROR: Verification failed!"
    exit 1
fi

log "Step 3: Adding filter dependencies to configure script"
# whisper brings ggml (the model runs on it) and the include path; swresample
# turns any input into the 16 kHz mono the model wants. espeak-ng is not a
# configure component: its archives ride on --extra-libs (65-espeak-ng.sh).
DEPS="whisper swresample"
if grep -q "^lyricsalign_filter_deps=\"${DEPS}\"$" /build/ffmpeg/configure; then
    log "  ✓ Filter dependencies already correct"
elif grep -q "^lyricsalign_filter_deps=" /build/ffmpeg/configure; then
    sed -i "s|^lyricsalign_filter_deps=.*|lyricsalign_filter_deps=\"${DEPS}\"|" /build/ffmpeg/configure
    log "  ✓ Updated filter dependencies"
else
    sed -i "/^whisper_filter_deps=/a lyricsalign_filter_deps=\"${DEPS}\"" /build/ffmpeg/configure
    log "  ✓ Added filter dependencies"
fi
if grep -q "lyricsalign_filter_deps" /build/ffmpeg/configure; then
    log "  ✓ Verified in configure"
else
    log "  ✗ ERROR: Verification failed!"
    exit 1
fi

log "Step 4: Verifying configure actually resolves the dependency"
# The same throwaway, scoped configure 61-trailing-silence.sh runs, for the
# same reason: the seds above prove the text landed, not that configure
# enables the filter. This one must enable whisper and swresample too, since
# those are the dependencies under test. Only one outcome fails the build:
# configure ran and disabled lyricsalign_filter.
la_target_os="${TARGET_OS}"
[[ "${TARGET_OS}" == "windows" ]] && la_target_os="mingw32"
case "${TARGET_OS}" in
    darwin)
        la_extra_cflags="-arch ${ARCH} -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET%.0}"
        la_extra_ldflags="${la_extra_cflags}"
        ;;
    freebsd)
        la_extra_cflags="-static"
        la_extra_ldflags="-static"
        ;;
    *)
        la_extra_cflags="-static -static-libgcc -static-libstdc++"
        la_extra_ldflags="${la_extra_cflags}"
        ;;
esac
la_extra_libs="-lpthread -lm $(cat /build/extra_libflags.txt 2>/dev/null | tr '\n' ' ')"
[[ "${TARGET_OS}" == "freebsd" ]] && la_extra_libs="${la_extra_libs} -lmd"
la_cc_args=()
[[ -n "${CC:-}" ]] && la_cc_args+=(--cc="${CC}")
[[ -n "${CXX:-}" ]] && la_cc_args+=(--cxx="${CXX}")
la_check_log="$(mktemp)"
la_configure_rc=0
(
    cd /build/ffmpeg
    PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH:-}" \
    CFLAGS="${CFLAGS} $(cat /build/cflags.txt 2>/dev/null)" \
    LDFLAGS="${LDFLAGS} $(cat /build/ldflags.txt 2>/dev/null)" \
    ./configure \
        --arch="${ARCH}" \
        --target-os="${la_target_os}" \
        --cross-prefix="${CROSS_PREFIX:-}" \
        ${la_cc_args[@]+"${la_cc_args[@]}"} \
        --enable-cross-compile \
        --pkg-config-flags=--static \
        --disable-everything \
        --enable-gpl --enable-version3 \
        --enable-avfilter --enable-swresample --enable-whisper \
        --enable-filter=lyricsalign \
        --extra-cflags="${la_extra_cflags} -I${PREFIX}/include" \
        --extra-ldflags="${la_extra_ldflags} -L${PREFIX}/lib" \
        --extra-libs="${la_extra_libs}"
) >"${la_check_log}" 2>&1 || la_configure_rc=$?

if grep -q "Disabled lyricsalign_filter" "${la_check_log}"; then
    log "  ✗ ERROR: configure disabled lyricsalign_filter:"
    log "  $(grep "Disabled lyricsalign_filter" "${la_check_log}")"
    rm -f "${la_check_log}"
    exit 1
fi
if [[ ${la_configure_rc} -ne 0 ]]; then
    log "  ⚠ WARNING: the throwaway configure did not run (exit ${la_configure_rc})."
    log "  ⚠ lyricsalign's dependencies are UNVERIFIED on this platform; continuing."
    tail -n 40 "${la_check_log}" | log -a
elif ! grep -qw "lyricsalign" "${la_check_log}"; then
    log "  ⚠ WARNING: configure ran but never mentioned lyricsalign."
    log "  ⚠ lyricsalign's dependencies are UNVERIFIED on this platform; continuing."
    tail -n 40 "${la_check_log}" | log -a
else
    log "  ✓ configure resolves the dependencies and enables lyricsalign"
fi
rm -f "${la_check_log}"

exit 0
