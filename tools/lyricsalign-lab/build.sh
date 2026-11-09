#!/bin/bash
# Build a minimal ffmpeg with the whisper and lyricsalign filters inside the
# lab container (tools/lyricsalign-lab/Dockerfile). The repository is mounted
# at /repo; the real build steps scripts/65-espeak-ng.sh and
# scripts/66-lyricsalign.sh are run as they are, against the same /build/ffmpeg
# layout and helper functions the platform builds use, so a step that works
# here is the step that ships.
#
#   build.sh            incremental: espeak-ng is built once and kept in the
#                       /opt/nm volume, ffmpeg's objects in the /build volume
#   build.sh --fresh    rebuild espeak-ng and reconfigure ffmpeg
set -uo pipefail

FRESH=0
[[ "${1:-}" == "--fresh" ]] && FRESH=1

export PREFIX=${PREFIX:-/opt/nm}
export TARGET_OS=linux ARCH=x86_64
export CC=gcc CXX=g++ AR=ar RANLIB=ranlib NM_NM=nm
export CMAKE_COMMON_ARG="-DCMAKE_INSTALL_PREFIX=${PREFIX} -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release"
export PKG_CONFIG_PATH=${PREFIX}/lib/pkgconfig
export CFLAGS="${CFLAGS:-}" LDFLAGS="${LDFLAGS:-}"
export FFMPEG_ENABLES="" FFMPEG_CFLAGS="" FFMPEG_LDFLAGS="" FFMPEG_EXTRA_LIBFLAGS=""

REPO=/repo
FF=/build/ffmpeg
mkdir -p /build /scripts
# The step scripts read their siblings from /scripts/includes, as in the
# platform images. A copy, not a bind: the scripts sed files in place.
rm -rf /scripts/includes /scripts/init
cp -r "${REPO}/scripts/includes" "${REPO}/scripts/init" /scripts/
find /scripts -type f -name '*.sh' -exec sed -i 's/\r$//' {} +
: >/build/enable.txt; : >/build/cflags.txt; : >/build/ldflags.txt; : >/build/extra_libflags.txt
rm -f /ffmpeg_build.log /ffmpeg_build_pins.log

. /scripts/init/helpers.sh
export -f hr text_with_padding add_enable add_cflag add_ldflag add_extralib join_lines split_lines clean_whitespace apply_sed check_enabled log

say() { printf '\n== %s\n' "$*"; }
fail() { printf '✗ %s\n' "$*" >&2; [[ -f /ffmpeg_build.log ]] && tail -n 60 /ffmpeg_build.log >&2; exit 1; }
run_step() {  # run_step <script>: a platform step, with its log shown on failure
	local s="$1"
	chmod +x "${s}"
	if "${s}" >/dev/null 2>&1; then
		[[ -f /ffmpeg_build_pins.log ]] && sed 's/^/📌 /' /ffmpeg_build_pins.log && rm -f /ffmpeg_build_pins.log
		echo "✓ $(basename "${s}")"
	else
		fail "$(basename "${s}") failed (exit $?)"
	fi
}

# 1. ggml: the fixed-mode dispatcher plus a whisper.pc, the darwin shape of
#    48-whisper.sh (stock libggml-cpu.a + ggml_cpu_dispatch.c in
#    NM_GGML_CPU_FIXED mode). Rebuilt every run: it is cheap and it is
#    repository code.
say "ggml dispatcher (fixed level haswell) and whisper.pc"
mkdir -p /build/lab-ggml
${CC} -O2 -DNM_GGML_CPU_FIXED='"haswell"' -DNM_NO_VULKAN=1 -I/scripts/includes -I${PREFIX}/include \
	-c /scripts/includes/ggml_cpu_dispatch.c -o /build/lab-ggml/dispatch.o || fail "ggml_cpu_dispatch.c (fixed mode) does not compile"
rm -f ${PREFIX}/lib/libggml-cpu-variants.a
${AR} rcs ${PREFIX}/lib/libggml-cpu-variants.a /build/lab-ggml/dispatch.o || fail "archiving libggml-cpu-variants.a"
cp /scripts/includes/nm_ggml_cpu.h ${PREFIX}/include/nm_ggml_cpu.h
mkdir -p ${PREFIX}/lib/pkgconfig
cat >${PREFIX}/lib/pkgconfig/whisper.pc <<EOF
prefix=${PREFIX}
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: whisper
Description: Port of OpenAI's Whisper model in C/C++ (lab build, CPU only)
Version: 1.9.1
Libs: -L\${libdir} -lggml -lggml-base -lwhisper -lggml -lggml-base -lggml-cpu -lggml-cpu-variants -lggml-base
Libs.private: -lstdc++ -lm -lpthread
Cflags: -I\${includedir}
Requires:
Requires.private:
EOF
pkg-config --exists 'whisper >= 1.7.5' || fail "whisper.pc not usable"
echo "✓ whisper.pc"

# 2. espeak-ng, through the real step, once.
if [[ -f ${REPO}/scripts/65-espeak-ng.sh ]]; then
	if [[ ${FRESH} == 1 || ! -f ${PREFIX}/lib/libespeak-ng.a ]]; then
		say "scripts/65-espeak-ng.sh"
		rm -f ${PREFIX}/lib/libespeak-ng.a ${PREFIX}/lib/libucd.a
		rm -rf ${PREFIX}/share/espeak-ng-data
		cp "${REPO}/scripts/65-espeak-ng.sh" /scripts/65-espeak-ng.sh && sed -i 's/\r$//' /scripts/65-espeak-ng.sh
		run_step /scripts/65-espeak-ng.sh
	else
		echo "✓ espeak-ng already built (${PREFIX}/lib/libespeak-ng.a); --fresh rebuilds it"
		# The step adds its link flags on every platform build; replay them.
		add_extralib "-lespeak-ng -lucd" >/dev/null
	fi
else
	echo "– scripts/65-espeak-ng.sh not present yet"
fi

# 3. The whisper filter patch 48-whisper.sh applies, and the lyricsalign step.
say "filters"
cp /scripts/includes/af_whisper.c ${FF}/libavfilter/af_whisper.c
cp /scripts/includes/nm_whisper_words.h ${FF}/libavfilter/nm_whisper_words.h
[[ -f /scripts/includes/nm_ggml_threads.h ]] && cp /scripts/includes/nm_ggml_threads.h ${FF}/libavfilter/nm_ggml_threads.h
echo "✓ af_whisper.c"
FILTERS="whisper,anullsrc,aresample,aformat,atrim,asetnsamples,sine,aevalsrc,amix,volume,asplit,apad,ametadata,anull"
if [[ -f ${REPO}/scripts/66-lyricsalign.sh ]]; then
	cp "${REPO}/scripts/66-lyricsalign.sh" /scripts/66-lyricsalign.sh && sed -i 's/\r$//' /scripts/66-lyricsalign.sh
	run_step /scripts/66-lyricsalign.sh
	FILTERS="lyricsalign,${FILTERS}"
else
	echo "– scripts/66-lyricsalign.sh not present yet"
fi

# 4. ffmpeg, minimal. Always reconfigured: 66-lyricsalign.sh's throwaway
#    configure (its Step 4) runs in-tree and leaves ITS minimal config behind,
#    which the platform builds never see (their real configure runs later)
#    but which made the lab's make link an ffmpeg without the helper filters.
#    To keep make incremental, generated files that configure rewrote with
#    the same content get their old copy (and mtime) back.
say "ffmpeg configure + make"
cd ${FF}
# One --enable-<kind>=<name> per name: configure matches the value as a
# shell pattern against the component list, so a comma-separated value
# enables nothing but a component literally named that way (measured: only
# the first name landed).
expand() { local opt="$1" v; for v in ${2//,/ }; do printf -- '--enable-%s=%s\n' "${opt}" "${v}"; done; }
mapfile -t enable_args < <(expand filter "${FILTERS}"; expand demuxer wav,pcm_f32le; expand decoder pcm_s16le,pcm_f32le; expand muxer null,wav,pcm_f32le; expand encoder pcm_s16le,pcm_f32le; expand protocol file,pipe)
saved=/build/lab-config-save
gen="config.h config_components.h ffbuild/config.mak ffbuild/config.sh libavutil/avconfig.h libavutil/ffversion.h"
rm -rf ${saved}; mkdir -p ${saved}/ffbuild ${saved}/libavutil
for f in ${gen}; do [[ -f ${f} ]] && cp -p ${f} ${saved}/${f}; done
[[ ${FRESH} == 1 ]] && { make distclean >/dev/null 2>&1 || true; rm -rf ${saved}; mkdir -p ${saved}/ffbuild ${saved}/libavutil; }
extra_cflags="-I${PREFIX}/include $(cat /build/cflags.txt | tr '\n' ' ')"
extra_ldflags="-L${PREFIX}/lib $(cat /build/ldflags.txt | tr '\n' ' ')"
extra_libs="$(cat /build/extra_libflags.txt | tr '\n' ' ') -lpthread -lm -lstdc++"
./configure --pkg-config-flags=--static \
	--disable-everything --disable-doc --disable-ffplay --disable-ffprobe \
	--enable-gpl --enable-version3 --enable-static --disable-shared \
	--enable-avfilter --enable-swresample --enable-whisper \
	"${enable_args[@]}" \
	--extra-cflags="${extra_cflags}" --extra-ldflags="${extra_ldflags}" --extra-libs="${extra_libs}" \
	>/build/lab-configure.log 2>&1 || { tail -n 40 /build/lab-configure.log; tail -n 30 ${FF}/ffbuild/config.log; fail "configure"; }
for f in ${gen}; do
	if [[ -f ${saved}/${f} ]] && cmp -s ${f} ${saved}/${f}; then cp -p ${saved}/${f} ${f}; fi
done
echo "✓ configured"
make -j"$(nproc)" ffmpeg >/build/lab-make.log 2>&1 || { grep -n "error\|Error" /build/lab-make.log | head -40; tail -n 30 /build/lab-make.log; fail "make"; }
echo "✓ ${FF}/ffmpeg"
${FF}/ffmpeg -hide_banner -filters 2>/dev/null | grep -E ' (whisper|lyricsalign) '
# The filter finds espeak-ng-data next to the binary.
if [[ -d ${PREFIX}/share/espeak-ng-data ]]; then
	ln -sfn ${PREFIX}/share/espeak-ng-data ${FF}/espeak-ng-data
fi
exit 0
