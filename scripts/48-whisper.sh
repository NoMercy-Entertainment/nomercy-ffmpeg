#!/bin/bash

whisper_version=1.9.1

rm -f /ffmpeg_build.log
touch /ffmpeg_build.log

mkdir -p /build/whisper
cd /build/whisper

git clone --branch v${whisper_version} https://github.com/ggml-org/whisper.cpp.git .

rm -rf build

# chmod +x ./models/download-ggml-model.sh
# ./models/download-ggml-model.sh base

NPROC=$(nproc)

WHISPER_CMAKE_COMMON_ARG=${CMAKE_COMMON_ARG}

if check_enabled "sdl2"; then
    WHISPER_CMAKE_COMMON_ARG="${WHISPER_CMAKE_COMMON_ARG} -DWHISPER_SDL2=ON"
fi

# if check_enabled "cuda"; then
#     WHISPER_CMAKE_COMMON_ARG="${WHISPER_CMAKE_COMMON_ARG} -DGGML_CUDA=ON -DCUDA_TOOLKIT_ROOT_DIR=${PREFIX}/lib -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc"
# fi

# if check_enabled "vulkan"; then
#     WHISPER_CMAKE_COMMON_ARG="${WHISPER_CMAKE_COMMON_ARG} -DGGML_VULKAN=ON -DVulkan_LIBRARY=${PREFIX}/lib/libvulkan.a -DVulkan_INCLUDE_DIR=${PREFIX}/include"
# fi

if [[ ${TARGET_OS} == "windows" ]]; then
    OLD_CFLAGS=${CFLAGS}
    OLD_CXXFLAGS=${CXXFLAGS}

    CFLAGS="${CFLAGS} -lws2_32 -lwinpthread -lkernel32"
    CXXFLAGS="${CXXFLAGS} -lws2_32 -lwinpthread -lkernel32"

    find . -name '*.cpp' -exec sed -i 's|%ld|%llu|g' {} +
    find . -name '*.cpp' -exec sed -i 's|%lld|%llu|g' {} +

    # mingw-w64's headers don't declare THREAD_POWER_THROTTLING_STATE, so ggml's
    # thread power-throttling block in ggml_thread_apply_priority() fails to build.
    # Disable just that block by flipping its preprocessor guard. Anchor on the
    # guard itself instead of line numbers: the numbers move on every whisper bump,
    # and a stale range silently comments out unrelated code.
    if ! grep -q '#if _WIN32_WINNT >= 0x0602' ggml/src/ggml-cpu/ggml-cpu.c; then
        echo "Error: whisper ${whisper_version} ggml-cpu.c power-throttling guard not found" >> /ffmpeg_build.log
        exit 1
    fi
    sed -i 's|#if _WIN32_WINNT >= 0x0602|#if 0 // disabled: mingw-w64 lacks THREAD_POWER_THROTTLING_STATE|' ggml/src/ggml-cpu/ggml-cpu.c

    # windows-aarch64 (llvm-mingw) never linked libgomp: that toolchain ships
    # LLVM's libomp instead, so -lgomp does not resolve there. windows-x64
    # (GCC mingw) used to build ggml against GCC's libgomp, but that
    # runtime's worker-pool teardown deadlocks intermittently at process
    # exit on this MinGW build -- main thread stuck in doexit -> exit
    # handler -> WaitForMultipleObjects, workers idle at 0% CPU -- so ffmpeg
    # hangs after finishing its output until the caller's timeout kills it
    # (reproduced on the owner's server 2026-09-16: ~9/14 baseline runs
    # hung). Disable OpenMP on both windows targets and let ggml use its own
    # threadpool instead, same as freebsd already does.
    WHISPER_CMAKE_COMMON_ARG="${WHISPER_CMAKE_COMMON_ARG} -DGGML_OPENMP=OFF"

    if [[ -f ${PREFIX}/lib/libopenblas.a ]]; then
        WHISPER_CMAKE_COMMON_ARG="${WHISPER_CMAKE_COMMON_ARG} -DGGML_BLAS=ON -DBLAS_VENDOR=OpenBLAS -DBLAS_LIBRARIES=${PREFIX}/lib/libopenblas.a -DBLAS_INCLUDE_DIRS=${PREFIX}/include/openblas"
    fi

    cmake -G Ninja -B build  \
        ${WHISPER_CMAKE_COMMON_ARG} \
        -DCMAKE_POSITION_INDEPENDENT_CODE=OFF \
        -DWHISPER_STATIC=ON \
        -DWHISPER_BUILD_TOOLS=OFF \
        -DWHISPER_BUILD_SERVER=OFF \
        -DWHISPER_BUILD_TESTS=OFF \
        -DWHISPER_BUILD_EXAMPLES=OFF \
        -DVERBOSE=ON 2>&1 | log -a
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        CFLAGS=${OLD_CFLAGS}
        CXXFLAGS=${OLD_CXXFLAGS}
        echo "Error: Whisper configure failed" >> /ffmpeg_build.log
        exit 1
    fi

    ninja -j${NPROC} -C build 2>&1 | log -a
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        CFLAGS=${OLD_CFLAGS}
        CXXFLAGS=${OLD_CXXFLAGS}
        echo "Error: Whisper build failed" >> /ffmpeg_build.log
        exit 1
    fi

    ninja -C build install 2>&1 | log -a
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        CFLAGS=${OLD_CFLAGS}
        CXXFLAGS=${OLD_CXXFLAGS}
        echo "Error: Whisper install failed" >> /ffmpeg_build.log
        exit 1
    fi
    
    CFLAGS=${OLD_CFLAGS}
    CXXFLAGS=${OLD_CXXFLAGS}
else
    if [[ ${TARGET_OS} == "darwin" ]]; then
        # Fixed instruction level, not runtime dispatch: Apple controls the
        # hardware population, so the floor is known exactly. The oldest Mac
        # that runs our 10.15 deployment target is Ivy Bridge (AVX + F16C, no
        # AVX2/FMA); every Apple Silicon chip has dotprod and fp16.
        # NM_GGML_CPU_FIXED_NAME is picked up below to build the
        # nm_ggml_cpu_variant_name() shim in NM_GGML_CPU_FIXED mode.
        WHISPER_CMAKE_COMMON_ARG="${WHISPER_CMAKE_COMMON_ARG} -DGGML_METAL=OFF -DGGML_ACCELERATE=OFF"
        if [[ ${ARCH} == "x86_64" ]]; then
            WHISPER_CMAKE_COMMON_ARG="${WHISPER_CMAKE_COMMON_ARG} -DGGML_SSE42=ON -DGGML_AVX=ON -DGGML_F16C=ON -DGGML_AVX2=OFF -DGGML_FMA=OFF -DGGML_BMI2=OFF"
            WHISPER_CMAKE_COMMON_ARG="${WHISPER_CMAKE_COMMON_ARG} -DCMAKE_OSX_DEPLOYMENT_TARGET=10.15.0"
            NM_GGML_CPU_FIXED_NAME="ivybridge"
        else
            WHISPER_CMAKE_COMMON_ARG="${WHISPER_CMAKE_COMMON_ARG} -DGGML_CPU_ARM_ARCH=armv8.4-a+dotprod+fp16"
            NM_GGML_CPU_FIXED_NAME="armv8.4+dotprod+fp16"
        fi
    elif [[ ${TARGET_OS} == "freebsd" ]]; then
        # FreeBSD base ships libomp.so but no libomp.a, so clang's -fopenmp
        # cannot survive the fully static ffmpeg link; use ggml's own threadpool
        WHISPER_CMAKE_COMMON_ARG="${WHISPER_CMAKE_COMMON_ARG} -DGGML_OPENMP=OFF"
    fi
    mkdir build && cd build

    cmake -S .. -B . \
        ${WHISPER_CMAKE_COMMON_ARG} \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DBUILD_SHARED_LIBS=OFF \
        -DWHISPER_BUILD_TOOLS=OFF \
        -DWHISPER_BUILD_SERVER=OFF \
        -DWHISPER_BUILD_EXAMPLES=OFF \
        -DWHISPER_BUILD_TESTS=OFF -DVERBOSE=ON 2>&1 | log -a
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        echo "Error: Whisper configure failed" >> /ffmpeg_build.log
        exit 1
    fi

    cmake --build . -j${NPROC} --config Release --verbose 2>&1 | log -a
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        echo "Error: Whisper build failed" >> /ffmpeg_build.log
        exit 1
    fi

    cmake --install . --config Release 2>&1 | log -a
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        echo "Error: Whisper install failed" >> /ffmpeg_build.log
        exit 1
    fi
fi

if [[ ! -f "${PREFIX}/lib/pkgconfig/whisper.pc" ]]; then
    log "Error: whisper.pc not found"
    exit 1
fi

echo "Whisper installed successfully" > /ffmpeg_build.log

# --- CPU backend variants -------------------------------------------------
#
# ggml compiles for one instruction-set level, and cross-compiling makes that
# level the bare x86-64 / ARMv8.0 baseline: measured 8-14x slower on whisper
# and 2.4x on stemsplit. Raising the level instead would break Raspberry Pi 4,
# Ivy Bridge Macs and pre-AVX Atom boxes. So build the backend several times
# and let ggml_cpu_dispatch.c pick one at runtime.
#
# NM_SKIP_VARIANTS opts a platform out of all of this and keeps linking the
# stock single-level libggml-cpu.a instead: the two darwin targets set it
# because they know their hardware floor exactly and build ggml once at a
# fixed level (see includes/ggml_cpu_dispatch.c's NM_GGML_CPU_FIXED mode).
NM_SKIP_VARIANTS="${NM_SKIP_VARIANTS:-0}"

# darwin must opt out NOW, not in a later task: nm_pack_variant's ELF/COFF
# recipes both do `${NM_LD} -r --whole-archive`, and Apple's ld64 has no
# such flag, so the variant loop below would die immediately on either
# darwin target. Task 6 gives darwin its own fixed instruction level (one
# ggml build per platform, no dispatch) and switches
# ggml_cpu_dispatch.c to NM_GGML_CPU_FIXED mode; until that lands, darwin
# keeps today's single-level libggml-cpu.a. Do not add darwin instruction
# flags to the matrix below -- that is Task 6's work, not this one's.
if [[ ${TARGET_OS} == darwin ]]; then
    NM_SKIP_VARIANTS=1
fi

# Format: <tag>|<dispatcher feature>|<cmake flags>
nm_variant_matrix() {
    # Explicit about which ARCH values map to which matrix, rather than
    # "x86_64 vs. everything else": darwin-arm64 reports ARCH=arm64 (not
    # aarch64, unlike linux-aarch64/windows-aarch64), and it used to land in
    # the ARM branch by that accident rather than by a real test for it. A
    # platform with a value this function does not recognise gets zero rows
    # instead of silently borrowing whichever branch happens to be `else`;
    # the caller (48-whisper.sh, after the build loop) aborts if that leaves
    # nm_index at zero.
    case ${ARCH} in
    x86_64)
        cat <<'MATRIX'
x64|NM_CPU_FEAT_BASELINE|-DGGML_SSE42=OFF -DGGML_AVX=OFF -DGGML_AVX2=OFF -DGGML_FMA=OFF -DGGML_F16C=OFF -DGGML_BMI2=OFF
sse42|NM_CPU_FEAT_SSE42|-DGGML_SSE42=ON -DGGML_AVX=OFF -DGGML_AVX2=OFF -DGGML_FMA=OFF -DGGML_F16C=OFF -DGGML_BMI2=OFF
ivybridge|NM_CPU_FEAT_AVX_F16C|-DGGML_SSE42=ON -DGGML_AVX=ON -DGGML_AVX2=OFF -DGGML_FMA=OFF -DGGML_F16C=ON -DGGML_BMI2=OFF
haswell|NM_CPU_FEAT_AVX2_FMA|-DGGML_SSE42=ON -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON -DGGML_BMI2=ON
MATRIX
        ;;
    aarch64|arm64)
        cat <<'MATRIX'
armv8.0|NM_CPU_FEAT_ARM_BASE|-DGGML_CPU_ARM_ARCH=armv8-a
armv8.2+dotprod+fp16|NM_CPU_FEAT_ARM_DOTPROD_FP16|-DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod+fp16
MATRIX
        # i8mm is not reliably detectable on Windows-on-ARM, so it is a
        # linux-aarch64 variant only.
        if [[ ${TARGET_OS} == linux ]]; then
            echo 'armv8.2+dotprod+fp16+i8mm|NM_CPU_FEAT_ARM_I8MM|-DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod+fp16+i8mm'
        fi
        ;;
    *)
        log "Error: nm_variant_matrix: unrecognised ARCH '${ARCH}'"
        ;;
    esac
}

if [[ ${NM_SKIP_VARIANTS} != "1" ]]; then
    # The whisper.cpp checkout is still needed as a cmake source tree for
    # every variant build below, so this whole block must run before the
    # "rm -rf /build/whisper" further down.
    source /scripts/includes/ggml_cpu_pack.sh

    NM_OBJ_FORMAT=elf
    [[ ${TARGET_OS} == windows ]] && NM_OBJ_FORMAT=coff
    # Not every platform image exports NM/LD/CROSS_PREFIX (only the cross
    # dockerfiles do), so fall back to the plain binutils names rather than
    # requiring them.
    export NM_NM="${NM:-nm}" NM_OBJCOPY="${CROSS_PREFIX:-}objcopy" NM_LD="${LD:-ld}"

    nm_variant_dir=/build/whisper-variants
    rm -rf ${nm_variant_dir} && mkdir -p ${nm_variant_dir}
    nm_header=${nm_variant_dir}/nm_ggml_cpu_variants.h
    echo "/* generated by 48-whisper.sh - do not edit */" > ${nm_header}
    echo "#define NM_GGML_CPU_VARIANTS \\" >> ${nm_header}

    nm_index=0
    nm_objects=""
    while IFS='|' read -r nm_tag nm_feat nm_flags; do
        [[ -z ${nm_tag} ]] && continue
        log "Building ggml CPU variant ${nm_tag}"
        cmake -G Ninja -B ${nm_variant_dir}/build-${nm_tag} -S /build/whisper \
            ${WHISPER_CMAKE_COMMON_ARG} ${nm_flags} \
            -DCMAKE_INSTALL_PREFIX=${nm_variant_dir}/inst-${nm_tag} \
            -DCMAKE_POSITION_INDEPENDENT_CODE=OFF -DWHISPER_STATIC=ON \
            -DWHISPER_BUILD_TOOLS=OFF -DWHISPER_BUILD_SERVER=OFF \
            -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=OFF 2>&1 | log -a
        if [ ${PIPESTATUS[0]} -ne 0 ]; then log "Error: variant ${nm_tag} configure failed"; exit 1; fi
        ninja -j${NPROC} -C ${nm_variant_dir}/build-${nm_tag} ggml-cpu 2>&1 | log -a
        if [ ${PIPESTATUS[0]} -ne 0 ]; then log "Error: variant ${nm_tag} build failed"; exit 1; fi

        nm_archive=$(find ${nm_variant_dir}/build-${nm_tag} -name 'libggml-cpu.a' -o -name 'ggml-cpu.a' | head -1)
        nm_pack_variant ${NM_OBJ_FORMAT} "${nm_archive}" "nm_v${nm_index}_" \
            ${nm_variant_dir}/variant-${nm_tag}.o || { log "Error: packing ${nm_tag} failed"; exit 1; }
        nm_objects="${nm_objects} ${nm_variant_dir}/variant-${nm_tag}.o"
        printf '    X(nm_v%s_, "%s", %s) \\\n' "${nm_index}" "${nm_tag}" "${nm_feat}" >> ${nm_header}
        nm_index=$((nm_index + 1))
    done < <(nm_variant_matrix)
    echo "" >> ${nm_header}

    # The dispatcher's guaranteed-baseline fallback (nm_variants[0] in
    # ggml_cpu_dispatch.c) is only a real guarantee if at least one variant
    # actually got built -- an empty matrix (unrecognised ARCH above, or
    # every row failing in a way that did not already exit) would otherwise
    # generate an empty NM_GGML_CPU_VARIANTS macro, giving the dispatcher a
    # zero-length array and an out-of-bounds read the first time it falls
    # back. Fail loudly here instead.
    if [ ${nm_index} -eq 0 ]; then
        log "Error: no ggml CPU variants were built for ARCH=${ARCH} TARGET_OS=${TARGET_OS}"
        exit 1
    fi

    log "Built ${nm_index} ggml CPU variants"

    ${CC:-cc} ${CFLAGS} -I${nm_variant_dir} -I/scripts/includes -I${PREFIX}/include \
        -c /scripts/includes/ggml_cpu_dispatch.c -o ${nm_variant_dir}/dispatch.o 2>&1 | log -a
    if [ ${PIPESTATUS[0]} -ne 0 ]; then log "Error: dispatcher build failed"; exit 1; fi

    rm -f ${PREFIX}/lib/libggml-cpu-variants.a
    ${AR:-ar} rcs ${PREFIX}/lib/libggml-cpu-variants.a ${nm_variant_dir}/dispatch.o ${nm_objects} \
        || { log "Error: archiving libggml-cpu-variants.a failed"; exit 1; }
    rm -f ${PREFIX}/lib/libggml-cpu.a ${PREFIX}/lib/ggml-cpu.a
else
    # NM_SKIP_VARIANTS platforms (currently only darwin) still get their
    # filters calling nm_ggml_cpu_variant_name() unconditionally (Task 4),
    # but there is no dispatcher build here to define it, and the stock
    # libggml-cpu.a we keep below doesn't either. Compile
    # ggml_cpu_dispatch.c with -DNM_GGML_CPU_FIXED set: it then defines only
    # that one symbol (returning NM_GGML_CPU_FIXED_NAME) and none of the
    # forwarding functions, so the resulting object coexists with the stock
    # archive instead of colliding with it. Packed into its own
    # libggml-cpu-variants.a so whisper.pc can name the same archive
    # filename in both modes -- only its contents differ.
    : "${NM_GGML_CPU_FIXED_NAME:?NM_SKIP_VARIANTS=1 but NM_GGML_CPU_FIXED_NAME was not set}"

    nm_variant_dir=/build/whisper-variants
    rm -rf ${nm_variant_dir} && mkdir -p ${nm_variant_dir}

    ${CC:-cc} ${CFLAGS} "-DNM_GGML_CPU_FIXED=\"${NM_GGML_CPU_FIXED_NAME}\"" \
        -I/scripts/includes -I${PREFIX}/include \
        -c /scripts/includes/ggml_cpu_dispatch.c -o ${nm_variant_dir}/dispatch.o 2>&1 | log -a
    if [ ${PIPESTATUS[0]} -ne 0 ]; then log "Error: fixed-mode dispatcher build failed"; exit 1; fi

    rm -f ${PREFIX}/lib/libggml-cpu-variants.a
    ${AR:-ar} rcs ${PREFIX}/lib/libggml-cpu-variants.a ${nm_variant_dir}/dispatch.o \
        || { log "Error: archiving fixed-mode libggml-cpu-variants.a failed"; exit 1; }

    log "Built fixed ggml CPU level '${NM_GGML_CPU_FIXED_NAME}' (no dispatch)"
fi

# Installed unconditionally, not just when the variant loop ran above: Task 4
# makes both the whisper and stemsplit filters include this header on every
# platform (including darwin, which skips the variant loop via
# NM_SKIP_VARIANTS but still links a build of ggml_cpu_dispatch.c in
# NM_GGML_CPU_FIXED mode and needs the same public declaration). Missing it
# would fail the filters' compile on whichever platform this cp was gated
# out for.
cp /scripts/includes/nm_ggml_cpu.h ${PREFIX}/include/nm_ggml_cpu.h \
    || { log "Error: installing nm_ggml_cpu.h failed"; exit 1; }

cd /build
rm -rf /build/whisper

rm -rf ${PREFIX}/lib/pkgconfig/whisper.pc
nm_cpu_lib="ggml-cpu-variants"
[[ ${NM_SKIP_VARIANTS} == "1" ]] && nm_cpu_lib="ggml-cpu"
lib_flags="Libs: -L\${libdir} -lggml -lggml-base -lwhisper -lggml -lggml-base -l${nm_cpu_lib}"
# NM_SKIP_VARIANTS platforms link the stock -lggml-cpu above for the real
# backend, plus this second, differently-built libggml-cpu-variants.a (see
# the fixed-mode branch above) purely for its nm_ggml_cpu_variant_name()
# definition -- the filters call it unconditionally regardless of platform.
[[ ${NM_SKIP_VARIANTS} == "1" ]] && lib_flags="${lib_flags} -lggml-cpu-variants"
lib_private_flags="Libs.private: -lstdc++"
{
    echo "prefix=${PREFIX}"
    echo "exec_prefix=\${prefix}"
    echo "libdir=\${exec_prefix}/lib"
    echo "includedir=\${prefix}/include"
    echo ""
    echo "Name: whisper"
    echo "Description: Port of OpenAI's Whisper model in C/C++"
    echo "Version: ${whisper_version}"
    if [[ ${TARGET_OS} == "linux" ]]; then
        lib_private_flags+=" -lm -fopenmp"
    elif [[ ${TARGET_OS} == "darwin" ]]; then
        lib_flags+=" -lggml-blas"
        lib_private_flags+=" -lz"
    elif [[ ${TARGET_OS} == "freebsd" ]]; then
        lib_private_flags+=" -lm -pthread"
    elif [[ ${ARCH} == "aarch64" ]]; then
        # windows-aarch64: no OpenBLAS (skipped, see includes/windows/48-openblas.sh)
        # so no -lggml-blas/-lopenblas, and no libgomp under llvm-mingw.
        lib_flags+=" -lwinpthread -lws2_32"
        lib_private_flags+=" -lm -lwinpthread -lws2_32"
    else
        # windows-x64: ggml no longer links libgomp/OpenMP here either (see
        # the GGML_OPENMP=OFF comment above) -- its worker-pool teardown
        # deadlocked intermittently at process exit on this MinGW build.
        lib_flags+=" -lggml-blas -lwinpthread -lws2_32"
        lib_private_flags+=" -lm -lopenblas -lwinpthread -lws2_32"
    fi
    echo "${lib_flags}"
    echo "${lib_private_flags}"
    if [[ ${TARGET_OS} == "windows" ]]; then
        # OpenMP is off on both windows targets, so consumers must not be
        # told to compile with -fopenmp either.
        echo "Cflags: -I\${includedir}"
    else
        echo "Cflags: -I\${includedir}"
    fi
    echo "Requires: "
    echo "Requires.private: "
} >${PREFIX}/lib/pkgconfig/whisper.pc

if [[ ${TARGET_OS} == "windows" ]]; then
    # Every rename here is guarded with -f: the CPU-variant step above already
    # removes/replaces ggml-cpu.a (or, for NM_SKIP_VARIANTS platforms, never
    # touches it), so an unguarded mv on a file that step already disposed of
    # would fail.
    [[ -f ${PREFIX}/lib/ggml.a ]] && mv ${PREFIX}/lib/ggml.a ${PREFIX}/lib/libggml.a
    [[ -f ${PREFIX}/lib/ggml-base.a ]] && mv ${PREFIX}/lib/ggml-base.a ${PREFIX}/lib/libggml-base.a
    # ggml-blas.a only exists when BLAS was enabled; windows-aarch64 skips
    # OpenBLAS, so ggml never builds that backend.
    if [[ -f ${PREFIX}/lib/ggml-blas.a ]]; then
        mv ${PREFIX}/lib/ggml-blas.a ${PREFIX}/lib/libggml-blas.a
    fi
    [[ -f ${PREFIX}/lib/ggml-cpu.a ]] && mv ${PREFIX}/lib/ggml-cpu.a ${PREFIX}/lib/libggml-cpu.a
fi

# Replace the upstream whisper filter with our patched version that exposes
# the auto-detected language as frame metadata (lavfi.whisper.language +
# lavfi.whisper.language_confidence) and as a leading JSON detection object.
# See: https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/issues/38
if [[ -f /scripts/includes/af_whisper.c ]]; then
    cp /scripts/includes/af_whisper.c /build/ffmpeg/libavfilter/af_whisper.c
    log "Applied af_whisper.c language-detection patch"
fi

add_enable "--enable-whisper"

exit 0