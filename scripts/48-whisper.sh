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

# --- Vulkan GPU backend ----------------------------------------------------
#
# ggml's Vulkan backend needs three symbols from the Vulkan loader. Linking the
# real loader would make these static binaries depend on a shared library most
# machines do not have, so scripts/includes/vk_loader_shim.c supplies those three
# and opens the system loader at first use instead. The binary stays static and
# Vulkan stays optional: no driver simply means the CPU backend is used.
#
# find_package(Vulkan) still has to be satisfied at configure time. ggml-vulkan is
# built as a static archive, so Vulkan_LIBRARY is never linked - it only has to
# exist as a path, hence the empty stub archive.
#
# This has to run here, before the cmake invocations below, not down in the
# "CPU backend variants" section further down: WHISPER_CMAKE_COMMON_ARG here
# feeds the ONE cmake configure (windows branch or the else branch, whichever
# runs) that produces libggml-vulkan.a via `cmake --install`. The variant loop
# below only ever rebuilds the `ggml-cpu` target at different instruction
# levels into throwaway prefixes and never touches Vulkan at all, so setting
# these flags there instead would silently build nothing Vulkan-related.
#
# freebsd-x86_64 is excluded too, alongside darwin, because vk_loader_shim.c
# could never open a real Vulkan loader there: these binaries are linked
# statically, and FreeBSD's libc.a supplies dlopen() as a stub that sets
# "Service unavailable" and returns NULL, unconditionally. Not a guess and not
# a property of FreeBSD in general -- FreeBSD's DYNAMIC libc has a working
# dlopen, and an earlier version of this comment wrongly said the base system
# libc was static-only. Verified for Task 5 on the same FreeBSD 14.3 sysroot
# this target builds against: libc.a's dlfcn.o carries the string, and the
# disassembly of dlopen in a statically linked FreeBSD binary is four
# instructions -- load that string, call _rtld_error, return 0.
#
# So building Vulkan in here would cost ~59 MB of dead weight that can never do
# anything but return the shim's own stub failures.
NM_VULKAN=0
if [[ ${TARGET_OS} != darwin && ${TARGET_OS} != freebsd ]]; then
    NM_VULKAN=1
fi

# Told to ggml_cpu_dispatch.c so its fork-based Vulkan guard compiles out where
# there is no Vulkan to guard: darwin and freebsd would otherwise fork a child
# per process to probe a backend that is not linked.
#
# The polarity is deliberate. A build that says NOTHING gets the guard - one
# wasted fork. The other way round, a forgotten flag would be a segfault on any
# machine with software Vulkan installed, so the fail-safe direction is "guard
# on unless the build explicitly says there is no Vulkan".
NM_DISPATCH_VK_FLAG=""
if [[ ${NM_VULKAN} == 0 ]]; then
    NM_DISPATCH_VK_FLAG="-DNM_NO_VULKAN=1"
fi

if [[ ${NM_VULKAN} == 1 ]]; then
    # Vulkan_INCLUDE_DIR points at this platform's own Vulkan-Headers install
    # (scripts/45-vulkan.sh, which runs before this script on every platform
    # that reaches here) rather than copying headers out of /usr/include.
    # Ubuntu 24.04's apt package (libvulkan-dev, Vulkan-Headers 1.3.275) is
    # older than the project-pinned checkout 45-vulkan.sh already installed
    # into ${PREFIX}/include (ffmpeg-base.dockerfile's vulkan_headers_version,
    # 1.4.x) -- the same headers libplacebo and ffmpeg's own --enable-vulkan
    # hwaccel already compile against. Building ggml-vulkan against the older
    # apt headers while everything else in this binary uses the newer ones is
    # exactly the kind of split that produces a hard-to-diagnose struct-layout
    # mismatch later, not now. This also removes the glibc-header-ordering
    # hazard a prior version of this comment warned about: ${PREFIX}/include
    # is this project's own isolated prefix, never mixed with /usr/include, on
    # every platform including mingw, so there is no ordering hazard to avoid
    # by copying anything out of it.
    nm_vk_dir=/build/vulkan-stub
    mkdir -p ${nm_vk_dir}
    : > ${nm_vk_dir}/empty.c
    gcc -c ${nm_vk_dir}/empty.c -o ${nm_vk_dir}/empty.o \
        || { log "Error: vulkan stub object build failed"; exit 1; }
    ar rcs ${nm_vk_dir}/libvulkan-stub.a ${nm_vk_dir}/empty.o \
        || { log "Error: vulkan stub archive build failed"; exit 1; }

    # glslc is a BUILD-HOST tool: ggml's vulkan-shaders-gen executes it once per
    # shader at build time. So the question is not "is there a glslc on PATH"
    # but "is there a glslc this machine can run", and on a cross target those
    # are different questions. ${PREFIX}/bin comes first on PATH (see the
    # platform dockerfiles) and 45-vulkan.sh installs shaderc's own glslc
    # there, cross compiled for the TARGET: on linux-aarch64 that is an ARM
    # binary and every invocation of it on the x86_64 builder fails with
    # "Exec format error". vulkan-shaders-gen does not stop on that - it logs
    # and carries on - so ggml-vulkan compiles and installs with most of its
    # shader blob symbols never defined, and the first thing that notices is
    # ffmpeg's configure link test an hour later, which reports only
    # "whisper >= 1.7.5 not found using pkg-config".
    #
    # Probing with --version leaves every platform that already worked on the
    # binary it was already using and only moves the one that could not run its
    # own: linux-x86_64's ${PREFIX}/bin/glslc is a native x86_64 build, so it
    # still wins the probe, and any target whose ${PREFIX}/bin holds no runnable
    # "glslc" simply falls through to /usr/bin/glslc, which is where its shaders
    # were already being compiled. /usr/bin/glslc is the apt glslc that
    # ffmpeg-base.dockerfile installs - the fallback, not the first choice,
    # deliberately: hardcoding it would drag linux-x86_64 off the shaderc
    # 45-vulkan.sh just built for it and onto apt's 2023.8 on every platform,
    # to fix the one platform that could not run its own.
    nm_glslc=""
    for nm_glslc_cand in "$(command -v glslc 2>/dev/null)" /usr/bin/glslc; do
        [[ -n ${nm_glslc_cand} && -x ${nm_glslc_cand} ]] || continue
        "${nm_glslc_cand}" --version >/dev/null 2>&1 || continue
        nm_glslc=${nm_glslc_cand}
        break
    done
    [[ -n ${nm_glslc} ]] \
        || { log "Error: NM_VULKAN=1 but no glslc that runs on this build host was found (checked PATH and /usr/bin/glslc)"; exit 1; }
    log "Using glslc: ${nm_glslc}"

    # SPIR-V headers, staged into ${PREFIX}/include.
    #
    # Why they are not already there: ggml-vulkan's own CMakeLists does
    # find_package(SPIRV-Headers CONFIG REQUIRED) at line 14 but never links
    # SPIRV-Headers::SPIRV-Headers -- its only target_link_libraries is
    # Vulkan::Vulkan (line 100). So configure succeeds off the apt package's
    # cmake config while the headers themselves only ever reach the compiler
    # through Vulkan_INCLUDE_DIR, which is exactly what this staging provides.
    # The apt package puts them in /usr/include, which a native compiler
    # searches and a cross compiler does not -- which is why linux-x86_64 built
    # clean and windows-x86_64 did not, the moment NM_VULKAN reached it.
    #
    # And the failure is silent where it hurts. ggml-vulkan.cpp:40-49 tries
    # three layouts with __has_include and has an #else that re-includes
    # <spirv/unified1/spirv.hpp> "to let the compiler throw a standard file not
    # found error". With x86_64-w64-mingw32-g++ on Ubuntu 24.04 it does not:
    # reproduced with a 14-line file, the #else branch is taken, the include
    # produces NO diagnostic at all, and the only error is a wall of "'spv' has
    # not been declared" two thousand lines further down. Hence the explicit
    # check below -- it is what turns that into a one-line failure at the top
    # of this script. 3.5 MB of headers, build-time only.
    if [[ ! -f ${PREFIX}/include/spirv/unified1/spirv.hpp && -d /usr/include/spirv ]]; then
        cp -r /usr/include/spirv ${PREFIX}/include/spirv \
            || { log "Error: staging SPIR-V headers into ${PREFIX}/include failed"; exit 1; }
    fi
    [[ -f ${PREFIX}/include/spirv/unified1/spirv.hpp ]] \
        || { log "Error: NM_VULKAN=1 but no spirv/unified1/spirv.hpp under ${PREFIX}/include (is spirv-headers installed?)"; exit 1; }

    WHISPER_CMAKE_COMMON_ARG="${WHISPER_CMAKE_COMMON_ARG} -DGGML_VULKAN=ON"
    WHISPER_CMAKE_COMMON_ARG="${WHISPER_CMAKE_COMMON_ARG} -DVulkan_INCLUDE_DIR=${PREFIX}/include"
    WHISPER_CMAKE_COMMON_ARG="${WHISPER_CMAKE_COMMON_ARG} -DVulkan_LIBRARY=${nm_vk_dir}/libvulkan-stub.a"
    WHISPER_CMAKE_COMMON_ARG="${WHISPER_CMAKE_COMMON_ARG} -DVulkan_GLSLC_EXECUTABLE=${nm_glslc}"
    log "Vulkan backend enabled for ${TARGET_OS}-${ARCH}"
fi

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
    NM_VARIANT_EXT=o
    if [[ ${TARGET_OS} == windows ]]; then
        if [[ ${ARCH} == aarch64 ]]; then
            # llvm-mingw's ld.lld has no -r and its objcopy refuses
            # --rename-section on COFF, so this platform packs whole
            # archives instead of merged objects. See ggml_cpu_pack.sh.
            NM_OBJ_FORMAT=coff-archive
            NM_VARIANT_EXT=a
        else
            NM_OBJ_FORMAT=coff
        fi
    fi
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
            ${nm_variant_dir}/variant-${nm_tag}.${NM_VARIANT_EXT} \
            || { log "Error: packing ${nm_tag} failed"; exit 1; }
        nm_objects="${nm_objects} ${nm_variant_dir}/variant-${nm_tag}.${NM_VARIANT_EXT}"
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

    ${CC:-cc} ${CFLAGS} ${NM_DISPATCH_VK_FLAG} -I${nm_variant_dir} -I/scripts/includes -I${PREFIX}/include \
        -c /scripts/includes/ggml_cpu_dispatch.c -o ${nm_variant_dir}/dispatch.o 2>&1 | log -a
    if [ ${PIPESTATUS[0]} -ne 0 ]; then log "Error: dispatcher build failed"; exit 1; fi

    # The Vulkan loader shim rides along in this same archive (see
    # scripts/includes/vk_loader_shim.c's header comment): ggml-vulkan is a
    # separate, unmodified archive named directly in whisper.pc's Libs: line
    # (below), but its three undefined loader symbols need to resolve against
    # something, and this is that something.
    nm_vk_shim_obj=""
    if [[ ${NM_VULKAN} == 1 ]]; then
        ${CC:-cc} ${CFLAGS} -I${PREFIX}/include -c /scripts/includes/vk_loader_shim.c \
            -o ${nm_variant_dir}/vk_loader_shim.o 2>&1 | log -a
        if [ ${PIPESTATUS[0]} -ne 0 ]; then log "Error: vulkan shim build failed"; exit 1; fi
        nm_vk_archive=$(find ${PREFIX}/lib -name 'libggml-vulkan.a' -o -name 'ggml-vulkan.a' | head -1)
        if [[ -z ${nm_vk_archive} ]]; then log "Error: GGML_VULKAN=ON but no ggml-vulkan archive was produced"; exit 1; fi
        # ...and that it is a COMPLETE one. ggml-vulkan's compiled shaders are
        # emitted by vulkan-shaders-gen, which shells out to glslc once per
        # shader and only logs the failures, so a glslc that cannot run on this
        # host (see the glslc probe at the top of this script) still produces an
        # archive that builds, installs and passes every existing check here -
        # it is just missing the <shader>_data / <shader>_len blobs its own
        # objects reference. Nothing downstream of this script can attribute
        # that: it surfaces as ffmpeg's configure reporting "whisper >= 1.7.5
        # not found using pkg-config" an hour later, with the thousands of
        # undefined references only in ffbuild/config.log. Every blob referenced
        # inside this archive must be defined inside it (measured: 0 missing on
        # a good build, 3710 missing on the broken linux-aarch64 one).
        nm_vk_blobs() {
            ${NM_NM} "$1" "${nm_vk_archive}" 2>/dev/null | awk '{print $NF}' |
                grep -E '_(data|len)$' | sort -u
        }
        # An empty DEFINED set means nm told us nothing, not that the archive is
        # clean: with a broken or mis-set NM_NM both sets come back empty, the
        # set difference is empty, and this guard would report success on any
        # archive at all. That is the same fail-open shape as the glslc bug
        # above - a check that asserts the tool was called rather than that it
        # worked - so establish that nm produced a symbol table first (a good
        # ggml-vulkan archive defines ~5000 of these) before trusting the
        # comparison.
        nm_vk_defined=$(nm_vk_blobs --defined-only | wc -l)
        if [[ ${nm_vk_defined} -eq 0 ]]; then
            log "Error: ${NM_NM} listed no defined shader blob symbols in ${nm_vk_archive}; the shader completeness check cannot run (is NM_NM=${NM_NM} a working nm?)"
            exit 1
        fi
        nm_vk_missing=$(comm -23 <(nm_vk_blobs --undefined-only) <(nm_vk_blobs --defined-only) | wc -l)
        if [[ ${nm_vk_missing} -ne 0 ]]; then
            log "Error: ${nm_vk_archive} references ${nm_vk_missing} shader blob symbols it does not define; the Vulkan shader compilation (glslc ${nm_glslc}) did not produce them"
            exit 1
        fi
        nm_vk_shim_obj=${nm_variant_dir}/vk_loader_shim.o
    fi

    rm -f ${PREFIX}/lib/libggml-cpu-variants.a
    if [[ ${NM_OBJ_FORMAT} == coff-archive ]]; then
        # The variants are archives here, not objects, so they are merged with
        # an MRI script (ADDLIB splices in every member of another archive)
        # rather than appended with `ar rcs`. Member basenames collide both
        # inside one variant (two quants.c.obj, two repack.cpp.obj) and across
        # variants; that is fine in an ar archive -- duplicate member names are
        # legal and lookup goes through the symbol index -- as long as nothing
        # ever extracts them to a directory, which this path does not.
        {
            echo "CREATE ${PREFIX}/lib/libggml-cpu-variants.a"
            echo "ADDMOD ${nm_variant_dir}/dispatch.o"
            # vk_loader_shim.o is a plain object, not an archive. ADDLIB (used
            # below for the per-variant archives) expects an ar archive and
            # silently does the wrong thing given a bare .o, so the shim gets
            # its own ADDMOD line, same as dispatch.o just above.
            [[ -n ${nm_vk_shim_obj} ]] && echo "ADDMOD ${nm_vk_shim_obj}"
            for nm_obj in ${nm_objects}; do
                echo "ADDLIB ${nm_obj}"
            done
            echo "SAVE"
            echo "END"
        } | ${AR:-ar} -M || { log "Error: MRI merge of libggml-cpu-variants.a failed"; exit 1; }
        ${RANLIB:-ranlib} ${PREFIX}/lib/libggml-cpu-variants.a \
            || { log "Error: indexing libggml-cpu-variants.a failed"; exit 1; }
    else
        ${AR:-ar} rcs ${PREFIX}/lib/libggml-cpu-variants.a ${nm_variant_dir}/dispatch.o ${nm_objects} ${nm_vk_shim_obj} \
            || { log "Error: archiving libggml-cpu-variants.a failed"; exit 1; }
    fi
    # `ar -M` reports a failed script on stdout and still exits 0 in some
    # binutils versions, and COMDAT folding at a later link is this design's
    # named silent-failure mode, so both archiving paths -- not just
    # coff-archive -- get the same check: confirm the archive really exists
    # and really carries every variant's entry point, not just windows-aarch64.
    nm_reg_count=$(${NM_NM} --defined-only ${PREFIX}/lib/libggml-cpu-variants.a 2>/dev/null \
        | grep -c "nm_v[0-9]*_ggml_backend_cpu_reg$")
    if [[ ${nm_reg_count} -ne ${nm_index} ]]; then
        log "Error: libggml-cpu-variants.a has ${nm_reg_count} prefixed ggml_backend_cpu_reg symbols, expected ${nm_index}"
        exit 1
    fi
    # Symmetric check for the Vulkan shim: the coff-archive/MRI path above is
    # exactly the path this task's own verification never exercises
    # (linux-x86_64 packs via plain `ar rcs`), and the comment right above
    # this one already warns that `ar -M` can report a failed script on
    # stdout and still exit 0. Confirm the shim's own loader entry point
    # actually made it into the archive, not just that packing "succeeded".
    if [[ ${NM_VULKAN} == 1 ]]; then
        nm_vk_shim_count=$(${NM_NM} --defined-only ${PREFIX}/lib/libggml-cpu-variants.a 2>/dev/null \
            | grep -c " T vkGetInstanceProcAddr$")
        if [[ ${nm_vk_shim_count} -ne 1 ]]; then
            log "Error: libggml-cpu-variants.a has ${nm_vk_shim_count} defined vkGetInstanceProcAddr symbols (the Vulkan loader shim), expected 1"
            exit 1
        fi
    fi
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

    ${CC:-cc} ${CFLAGS} "-DNM_GGML_CPU_FIXED=\"${NM_GGML_CPU_FIXED_NAME}\"" ${NM_DISPATCH_VK_FLAG} \
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

if [[ ${TARGET_OS} == "windows" ]]; then
    # Every rename here is guarded with -f: the CPU-variant step above already
    # removes/replaces ggml-cpu.a (or, for NM_SKIP_VARIANTS platforms, never
    # touches it), so an unguarded mv on a file that step already disposed of
    # would fail. This whole block has to run before whisper.pc is written
    # below: that file's Libs: line names these archives by their renamed,
    # "lib"-prefixed forms (-lggml, -lggml-base, ... -lggml-vulkan), and a
    # linker resolving -l<name> only ever looks for lib<name>.a.
    [[ -f ${PREFIX}/lib/ggml.a ]] && mv ${PREFIX}/lib/ggml.a ${PREFIX}/lib/libggml.a
    [[ -f ${PREFIX}/lib/ggml-base.a ]] && mv ${PREFIX}/lib/ggml-base.a ${PREFIX}/lib/libggml-base.a
    # ggml-blas.a only exists when BLAS was enabled; windows-aarch64 skips
    # OpenBLAS, so ggml never builds that backend.
    if [[ -f ${PREFIX}/lib/ggml-blas.a ]]; then
        mv ${PREFIX}/lib/ggml-blas.a ${PREFIX}/lib/libggml-blas.a
    fi
    [[ -f ${PREFIX}/lib/ggml-cpu.a ]] && mv ${PREFIX}/lib/ggml-cpu.a ${PREFIX}/lib/libggml-cpu.a
    # ggml's cmake install drops the "lib" prefix on a COFF cross build for
    # every archive it produces, ggml-vulkan included -- confirmed against
    # real Task 1 builds, not assumed: tools/ggml-variants/vulkan-shim-test.sh
    # cross-compiles this same whisper.cpp/ggml checkout for mingw and its
    # libpath() helper exists specifically because "ggml's CMake install step
    # names these archives with a lib prefix on the native (elf) build but
    # without one when cross-compiling for Windows (coff) - verified against
    # both actual builds, not assumed" (that script's own comment). Neither
    # GNU ld nor ld.lld will find a bare "ggml-vulkan.a" given a "-lggml-vulkan"
    # flag, so without this rename both windows targets would fail to link
    # with an undefined-reference error the moment NM_VULKAN=1 reaches them.
    [[ -f ${PREFIX}/lib/ggml-vulkan.a ]] && mv ${PREFIX}/lib/ggml-vulkan.a ${PREFIX}/lib/libggml-vulkan.a
fi

rm -rf ${PREFIX}/lib/pkgconfig/whisper.pc
nm_cpu_lib="ggml-cpu-variants"
[[ ${NM_SKIP_VARIANTS} == "1" ]] && nm_cpu_lib="ggml-cpu"
# ggml-vulkan's three undefined loader symbols (see vk_loader_shim.c) are only
# resolved by the shim packed into libggml-cpu-variants.a. A static linker
# resolves left to right, so -lggml-vulkan MUST come before -l${nm_cpu_lib} in
# this Libs: line, or those symbols are still undefined when ffmpeg links.
nm_vk_lib=""
nm_vk_trailer=""
if [[ ${NM_VULKAN} == 1 ]]; then
    nm_vk_lib="-lggml-vulkan "
    # Cheap insurance: -lggml-vulkan sits after both -lggml-base occurrences
    # already on this line, so any ggml-base symbol that only ggml-vulkan (or
    # the shim riding in ggml-cpu-variants right after it) needs would
    # otherwise depend on a linker willing to look backwards, which is not
    # guaranteed across every platform this line is used on. One more pass.
    nm_vk_trailer=" -lggml-base"
fi
lib_flags="Libs: -L\${libdir} -lggml -lggml-base -lwhisper -lggml -lggml-base ${nm_vk_lib}-l${nm_cpu_lib}${nm_vk_trailer}"
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
    # OpenMP is off on both windows targets, so consumers must not be told to
    # compile with -fopenmp either -- same Cflags line on every platform.
    echo "Cflags: -I\${includedir}"
    echo "Requires: "
    echo "Requires.private: "
} >${PREFIX}/lib/pkgconfig/whisper.pc

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