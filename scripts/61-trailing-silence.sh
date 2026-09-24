#!/bin/bash

#/******************************/#
#/*  Made by Phillippe Pelzer  */#
#/*  https://github.com/Fill84 */#
#/******************************/#

cp /scripts/includes/af_trailingsilence.c /build/ffmpeg/libavfilter/af_trailingsilence.c

log "Step 1: Adding extern declaration to allfilters.c"
if ! grep -q "ff_af_trailingsilence" /build/ffmpeg/libavfilter/allfilters.c; then
    sed -i '0,/^extern const FFFilter ff_af_volumedetect;$/s//&\nextern const FFFilter ff_af_trailingsilence;/' /build/ffmpeg/libavfilter/allfilters.c
    log "  ✓ Added extern declaration"
else
    log "  ✓ Extern declaration already exists"
fi

if grep -q "ff_af_trailingsilence" /build/ffmpeg/libavfilter/allfilters.c; then
    log "  ✓ Verified in allfilters.c"
else
    log "  ✗ ERROR: Verification failed!"
    exit 1
fi

log "Step 2: Adding to Makefile"
if ! grep -q "af_trailingsilence.o" /build/ffmpeg/libavfilter/Makefile; then
    sed -i '/^OBJS-\$(CONFIG_ABENCH_FILTER)/a\
OBJS-$(CONFIG_TRAILINGSILENCE_FILTER)    += af_trailingsilence.o' /build/ffmpeg/libavfilter/Makefile
    log "  ✓ Added to Makefile"
else
    log "  ✓ Makefile entry already exists"
fi

if grep -q "af_trailingsilence.o" /build/ffmpeg/libavfilter/Makefile; then
    log "  ✓ Verified in Makefile"
else
    log "  ✗ ERROR: Verification failed!"
    exit 1
fi

log "Step 3: Adding filter dependencies to configure script"
# Two things drifted from the brief since it was written, both symptoms of
# the same FFmpeg version bump scripts/60-stemsplit.sh already ran into:
#   1. The anchor (abench_filter_deps=) no longer exists; whisper_filter_deps=
#      does, and sits in the same audio-filter-deps block.
#   2. "check_lib libm math.h sin -lm" registers the component as "libm", not
#      "lm" -- configure's check_deps requires the exact component name, so
#      "lm" never resolves and the filter is silently disabled.
if ! grep -q "trailingsilence_filter_deps" /build/ffmpeg/configure; then
    sed -i '/^whisper_filter_deps=/a trailingsilence_filter_deps="libm"' /build/ffmpeg/configure
fi

if grep -q "trailingsilence_filter_deps" /build/ffmpeg/configure; then
    log "  ✓ Added filter dependencies"
else
    log "  ✗ ERROR: Verification failed!"
    exit 1
fi

log "Step 4: Verifying configure actually resolves the dependency"
# Steps 1-3 only prove the sed landed in the right files. That is not the
# same thing as the filter being buildable: a dependency name configure does
# not recognize (this is exactly how "lm" vs "libm" was found) leaves the
# filter silently disabled while every check above still passes and the
# script still exits 0. This script runs before the real ./configure, so the
# only place that can catch the drift at build time -- in seconds, not after
# a full platform build -- is a throwaway configure invocation of our own,
# scoped to just this filter, read for its actual verdict.
#
# This invocation mirrors each ffmpeg-*.dockerfile's real configure as
# closely as a shared script can. What it matches and what it deliberately
# does not:
#
#   matched:     --arch, --target-os, --cross-prefix, --enable-cross-compile,
#                --cc/--cxx, the accumulated CFLAGS/LDFLAGS, and the
#                per-platform --extra-cflags/--extra-ldflags/--extra-libs.
#   not matched: --prefix, --pkg-config*, the gpl/version3/nonfree/static
#                switches and ${FFMPEG_ENABLES} + --enable-filter=all. Those
#                only widen the component set; this check is deliberately
#                --disable-everything so it costs seconds instead of the
#                minutes a full-component configure takes, and none of them
#                can affect whether trailingsilence's own dependency resolves.
#
# --cc/--cxx are the load-bearing part: on both darwin dockerfiles
# CC=${CROSS_PREFIX}clang while configure's default is ${CROSS_PREFIX}gcc,
# and no dockerfile creates that gcc alias. Without --cc the throwaway
# configure cannot run at all there.
ts_target_os="${TARGET_OS}"
[[ "${TARGET_OS}" == "windows" ]] && ts_target_os="mingw32" # matches every ffmpeg-windows-*.dockerfile's --target-os

# The dockerfiles hardcode --extra-cflags/--extra-ldflags per platform rather
# than exporting them, so they cannot be read from the environment; this case
# block reproduces them literally.
case "${TARGET_OS}" in
    darwin)
        # The dockerfile strips the trailing ".0" before configure; do the same.
        ts_extra_cflags="-arch ${ARCH} -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET%.0}"
        ts_extra_ldflags="${ts_extra_cflags}"
        ;;
    freebsd)
        ts_extra_cflags="-static"
        ts_extra_ldflags="-static"
        ;;
    *) # linux and windows
        ts_extra_cflags="-static -static-libgcc -static-libstdc++"
        ts_extra_ldflags="${ts_extra_cflags}"
        ;;
esac

# --extra-libs: the dockerfiles pass "-lpthread -lm" (freebsd adds -lmd) plus
# the contents of /build/extra_libflags.txt. Only the constant head is
# reproduced. That file is still being appended to by scripts that run after
# this one and is not collapsed into its final single-line form until init.sh
# finishes, so its value here is not what the real configure will see; and
# under --disable-everything no third-party library is linked anyway, while
# the one dependency actually under test (libm) is covered by -lm.
ts_extra_libs="-lpthread -lm"
[[ "${TARGET_OS}" == "freebsd" ]] && ts_extra_libs="-lpthread -lm -lmd"

# Only pass --cc/--cxx when the environment actually defines them, so a
# future dockerfile that leaves them unset gets configure's own default
# rather than an empty --cc= that guarantees failure.
ts_cc_args=()
[[ -n "${CC:-}" ]] && ts_cc_args+=(--cc="${CC}")
[[ -n "${CXX:-}" ]] && ts_cc_args+=(--cxx="${CXX}")

ts_check_log="$(mktemp)"
ts_configure_rc=0
(
    cd /build/ffmpeg
    CFLAGS="${CFLAGS} $(cat /build/cflags.txt 2>/dev/null)" \
    LDFLAGS="${LDFLAGS} $(cat /build/ldflags.txt 2>/dev/null)" \
    ./configure \
        --arch="${ARCH}" \
        --target-os="${ts_target_os}" \
        --cross-prefix="${CROSS_PREFIX}" \
        ${ts_cc_args[@]+"${ts_cc_args[@]}"} \
        --enable-cross-compile \
        --disable-everything \
        --enable-avfilter \
        --enable-filter=trailingsilence \
        --extra-cflags="${ts_extra_cflags}" \
        --extra-ldflags="${ts_extra_ldflags}" \
        --extra-libs="${ts_extra_libs}"
) >"${ts_check_log}" 2>&1 || ts_configure_rc=$?

# Exactly one outcome is a build-breaking failure: configure ran and said it
# disabled the filter. That is the drift this check exists to catch and it is
# always a real defect.
#
# Every other way this can go wrong -- configure failing to run, a toolchain
# quirk on a platform this throwaway has never been exercised on, output that
# simply does not mention the filter -- is reported loudly and then let
# through. Those say nothing about the filter's dependency, and turning them
# into exit 1 would let an unrelated configure hiccup fail an entire platform
# release from inside a feature script. The real ./configure runs in the next
# layer and fails on its own if the environment is genuinely broken.
if grep -q "Disabled trailingsilence_filter" "${ts_check_log}"; then
    log "  ✗ ERROR: configure disabled trailingsilence_filter:"
    log "  $(grep "Disabled trailingsilence_filter" "${ts_check_log}")"
    rm -f "${ts_check_log}"
    exit 1
fi

if [[ ${ts_configure_rc} -ne 0 ]]; then
    log "  ⚠ WARNING: the throwaway configure did not run (exit ${ts_configure_rc})."
    log "  ⚠ trailingsilence's dependency is UNVERIFIED on this platform; continuing."
    # log -a, not bare log: log with no argument runs "tee /ffmpeg_build.log",
    # which truncates the build log; -a appends instead.
    tail -n 40 "${ts_check_log}" | log -a
elif ! grep -qw "trailingsilence" "${ts_check_log}"; then
    log "  ⚠ WARNING: configure ran but never mentioned trailingsilence."
    log "  ⚠ trailingsilence's dependency is UNVERIFIED on this platform; continuing."
    # log -a, not bare log: log with no argument runs "tee /ffmpeg_build.log",
    # which truncates the build log; -a appends instead.
    tail -n 40 "${ts_check_log}" | log -a
else
    log "  ✓ configure resolves the dependency and enables trailingsilence"
fi

rm -f "${ts_check_log}"

exit 0
