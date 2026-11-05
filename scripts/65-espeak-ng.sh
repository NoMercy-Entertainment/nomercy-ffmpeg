#!/bin/bash

#/******************************/#
#/*  Made by Phillippe Pelzer  */#
#/*  https://github.com/Fill84 */#
#/******************************/#

# espeak-ng 1.52.0 as a static library, for the lyricsalign filter (#126): the
# filter turns each lyric line into IPA phones with espeak_TextToPhonemes().
# GPL-3.0-or-later; the ffmpeg configure line already carries --enable-gpl
# --enable-version3, and the README's licence table has the row.
#
# Two cmake builds, on purpose:
#
#   native  the host compiler, only for `--target data`: espeak-ng compiles its
#           phoneme tables and dictionaries by RUNNING the espeak-ng binary it
#           just built (cmake/data.cmake), which a cross-compiled binary cannot
#           do on this builder. The data files are architecture-independent
#           (every platform here is little-endian), so one native build serves
#           all seven targets.
#   target  ${CMAKE_COMMON_ARG}, only `--target espeak-ng ucd`: the library and
#           the Unicode helper it links privately. Never the binary (its mingw
#           link flags and the data step do not cross), never the tests.
#
# Everything audio-related is off: no async (pthread worker), no MBROLA, no
# sonic, no pcaudio, no Klatt, no speechPlayer. The filter never synthesises.
#
# What lands in ${PREFIX}: lib/libespeak-ng.a, lib/libucd.a, include/espeak-ng/,
# include/espeak/, lib/pkgconfig/espeak-ng.pc, share/espeak-ng-data/ (phontab,
# phonindex, phondata, intonations, every *_dict, lang/, voices/!v; no mbrola).
# scripts/init/package.sh copies share/espeak-ng-data next to the binary in
# every platform tarball, where the filter looks by default.

espeak_version=1.52.0
# The tag's commit, asserted after the clone: a tag can be moved, a commit
# cannot, and the release has no source tarball asset to pin a digest on.
espeak_commit=4870adfa25b1a32b4361592f1be8a40337c58d6c

rm -f /ffmpeg_build.log
touch /ffmpeg_build.log

rm -rf /build/espeak-ng
mkdir -p /build/espeak-ng
cd /build/espeak-ng

log "Step 0: clone espeak-ng ${espeak_version}"
if ! git clone --quiet --depth 1 --branch "${espeak_version}" https://github.com/espeak-ng/espeak-ng.git src 2>&1 | log -a; then
    log "  ✗ ERROR: clone of espeak-ng ${espeak_version} failed"
    exit 1
fi
espeak_got=$(git -C src rev-parse HEAD)
if [[ "${espeak_got}" != "${espeak_commit}" ]]; then
    log "  ✗ ERROR: tag ${espeak_version} is at ${espeak_got}, expected ${espeak_commit}"
    exit 1
fi
log "  ✓ ${espeak_version} is ${espeak_commit}"

ESPEAK_OFF="-DBUILD_SHARED_LIBS=OFF -DUSE_ASYNC=OFF -DUSE_MBROLA=OFF -DUSE_LIBSONIC=OFF -DUSE_LIBPCAUDIO=OFF -DUSE_KLATT=OFF -DUSE_SPEECHPLAYER=OFF -DESPEAK_COMPAT=OFF -DBUILD_TESTING=OFF"

# --- native: the data ------------------------------------------------------
# env -i: the platform images export the cross CC/CFLAGS/LDFLAGS (and the
# hardware variant puts compiler wrappers in /usr/local/bin); the native build
# must see none of that.
log "Step 1: native build for espeak-ng-data"
if ! env -i PATH=/usr/bin:/bin HOME=/root \
    cmake -S src -B native -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=/usr/bin/gcc -DCMAKE_CXX_COMPILER=/usr/bin/g++ ${ESPEAK_OFF} 2>&1 | log -a; then
    log "  ✗ ERROR: native configure failed"
    exit 1
fi
if ! env -i PATH=/usr/bin:/bin HOME=/root \
    cmake --build native --target data -j"$(nproc)" 2>&1 | log -a; then
    log "  ✗ ERROR: native data build failed"
    exit 1
fi
data_dir=/build/espeak-ng/native/espeak-ng-data
for f in phontab phonindex phondata intonations en_dict nl_dict de_dict fr_dict ja_dict lang/gmw/en-US; do
    if [[ ! -e "${data_dir}/${f}" ]]; then
        log "  ✗ ERROR: the native build did not produce espeak-ng-data/${f}"
        exit 1
    fi
done
log "  ✓ espeak-ng-data built ($(ls "${data_dir}" | grep -c '_dict$') dictionaries)"

# --- target: the library ---------------------------------------------------
log "Step 2: target build of libespeak-ng.a"
if ! cmake -S src -B target ${CMAKE_COMMON_ARG} ${ESPEAK_OFF} 2>&1 | log -a; then
    log "  ✗ ERROR: target configure failed"
    exit 1
fi
if ! cmake --build target --target espeak-ng ucd -j"$(nproc)" 2>&1 | log -a; then
    log "  ✗ ERROR: target library build failed"
    exit 1
fi
lib_a=$(find target -name 'libespeak-ng.a' | head -1)
ucd_a=$(find target -name 'libucd.a' | head -1)
if [[ -z "${lib_a}" || -z "${ucd_a}" ]]; then
    log "  ✗ ERROR: libespeak-ng.a (${lib_a:-none}) or libucd.a (${ucd_a:-none}) not produced"
    exit 1
fi
# The one symbol the filter needs must be in the archive, for this target.
# Plain nm output only: the osxcross (cctools) nm has no --defined-only, and
# a flag it rejects must not read as a missing symbol. A defined function is
# a T/t line; darwin prefixes an underscore.
if ! nm_out=$(${NM_NM:-${NM:-nm}} "${lib_a}" 2>&1); then
    log "  ✗ ERROR: ${NM_NM:-${NM:-nm}} cannot read ${lib_a}: $(tail -n 2 <<<"${nm_out}" | tr '
' ' ')"
    exit 1
fi
if ! grep -Eq ' [Tt] _?espeak_TextToPhonemes$' <<<"${nm_out}"; then
    log "  ✗ ERROR: libespeak-ng.a does not define espeak_TextToPhonemes"
    exit 1
fi
log "  ✓ ${lib_a} ($(wc -c < "${lib_a}") bytes), ${ucd_a}"

# --- install ---------------------------------------------------------------
log "Step 3: install"
mkdir -p "${PREFIX}/lib" "${PREFIX}/include" "${PREFIX}/lib/pkgconfig" "${PREFIX}/share"
cp "${lib_a}" "${PREFIX}/lib/libespeak-ng.a" || exit 1
cp "${ucd_a}" "${PREFIX}/lib/libucd.a" || exit 1
rm -rf "${PREFIX}/include/espeak-ng" "${PREFIX}/include/espeak"
cp -r src/src/include/espeak-ng "${PREFIX}/include/espeak-ng" || exit 1
cp -r src/src/include/espeak "${PREFIX}/include/espeak" || exit 1
rm -rf "${PREFIX}/share/espeak-ng-data"
cp -r "${data_dir}" "${PREFIX}/share/espeak-ng-data" || exit 1
rm -rf "${PREFIX}/share/espeak-ng-data/mbrola_ph"
data_kb=$(du -sk "${PREFIX}/share/espeak-ng-data" | cut -f1)
if [[ ${data_kb} -gt 20480 ]]; then
    log "  ✗ ERROR: espeak-ng-data is ${data_kb} kB, more than the 20 MB this step allows in a tarball"
    exit 1
fi
cat > "${PREFIX}/lib/pkgconfig/espeak-ng.pc" <<EOF
prefix=${PREFIX}
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: espeak-ng
Description: eSpeak NG text-to-speech (static, phonemes only)
Version: ${espeak_version}
Libs: -L\${libdir} -lespeak-ng -lucd
Libs.private: -lm
Cflags: -I\${includedir}
EOF
log "  ✓ installed, espeak-ng-data ${data_kb} kB"

# The filter is linked by scripts/66-lyricsalign.sh through configure's
# lyricsalign_filter_deps; the archives themselves ride on --extra-libs, with
# -lm after them because a static link resolves left to right.
add_extralib "-lespeak-ng -lucd -lm"

espeak_line="espeak-ng ${espeak_version} commit ${espeak_commit}, libespeak-ng.a sha256 $(sha256sum "${PREFIX}/lib/libespeak-ng.a" | cut -d' ' -f1), espeak-ng-data ${data_kb} kB"
echo "${espeak_line}" >> /ffmpeg_build_pins.log

rm -rf /build/espeak-ng
exit 0
