#!/bin/bash

if [[ ${TARGET_OS} != "windows" ]]; then
    exit 255
fi

add_enable "--enable-dxva2 --enable-d3d11va"

# D3D12VA: decoding (H.264, HEVC, AV1, VP9, MPEG-2, VC-1, WMV3), the H.264,
# HEVC and AV1 encoders and the scale/deinterlace/mestimate filters, on
# Direct3D 12.
#
# FFmpeg needs d3d12video.h for it. The ARM64 toolchain (llvm-mingw) ships a
# current one, so that build has always carried D3D12VA. The x86_64 toolchain
# is Ubuntu 24.04's mingw-w64 11.0.1, which has d3d12.h but no d3d12video.h:
# configure left D3D12VA out of every x86_64 build without a word, and stopped
# when the flag was forced, which is why it used to be commented out here.
#
# Where the header is missing, FFmpeg alone is handed d3d12.h and d3d12video.h
# of mingw-w64 14.0.0, from a directory of their own that only FFmpeg's
# configure is told about (--extra-cflags). The toolchain's own headers and
# every other component stay as they are. Not add_cflag: it writes one line
# per caller into /build/cflags.txt, twolame already owns the first, and the
# dockerfiles paste that file into CFLAGS newline and all, which leaves a
# broken line in ffbuild/config.mak ("missing separator").
#
# With 13.0.0 the decoders and two encoders build but the AV1 encoder and the
# three filters do not; 14.0.0 gives x86_64 everything the ARM64 build has.
# The two files are used only if they are the exact files pinned below, so
# either source is safe.
d3d12_video_header_found() { # [extra compiler flag]
    printf '#include <windows.h>\n#include <d3d12video.h>\n' | ${CC} ${1:+"$1"} -E -x c - >/dev/null 2>&1
}

if ! d3d12_video_header_found; then
    d3d12_dir=${PREFIX}/include/d3d12va-mingw-w64-14.0.0
    mkdir -p "${d3d12_dir}" || exit 1

    d3d12_fetch() { # <file> <sha256>
        local file="$1" sum="$2" url
        for url in \
            "https://raw.githubusercontent.com/mingw-w64/mingw-w64/v14.0.0/mingw-w64-headers/include/${file}" \
            "https://sourceforge.net/p/mingw-w64/mingw-w64/ci/v14.0.0/tree/mingw-w64-headers/include/${file}?format=raw"; do
            rm -f "${d3d12_dir}/${file}"
            if wget -q -T 60 -t 3 -O "${d3d12_dir}/${file}" "${url}" \
                && echo "${sum}  ${d3d12_dir}/${file}" | sha256sum -c - >/dev/null 2>&1; then
                log "d3d12va: ${file} fetched and verified from ${url}"
                return 0
            fi
            log "d3d12va: ${url} failed, or did not match the pinned SHA-256"
        done
        log "d3d12va: no source served the pinned ${file}"
        return 1
    }

    d3d12_fetch d3d12.h b61aa7cad7c32ac5daec56d0e82286dcd6f8d7ecdac85665a98b1c8684b22253 || exit 1
    d3d12_fetch d3d12video.h 59083942d46ec52397cc27ce2d5b199fc847f947a4c340fbae4b641f2da58621 || exit 1

    if ! d3d12_video_header_found "-I${d3d12_dir}"; then
        log "d3d12va: ${CC} cannot use d3d12video.h from ${d3d12_dir}"
        exit 1
    fi
    add_enable "--extra-cflags=-I${d3d12_dir}"
fi

add_enable "--enable-d3d12va"

exit 0
