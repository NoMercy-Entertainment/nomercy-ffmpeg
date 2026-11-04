#!/bin/bash
# Keep the CPU variant static and hardware startup dependencies in glibc base.
# Usage: verify_linux_runtime.sh cpu|hardware [BUILD-DIRECTORY]
set -euo pipefail
variant=${1:?Linux variant must be cpu or hardware}
case "${variant}" in cpu|hardware) ;; *) echo "Unknown Linux variant: ${variant}" >&2; exit 1 ;; esac
build_dir=${2:-/build/ffmpeg}
readelf="${CROSS_PREFIX:-}readelf"
for program in ffmpeg_g ffprobe_g; do
    [[ -f "${build_dir}/${program}" ]] || { echo "Missing ${program}" >&2; exit 1; }
done
for binary in "${build_dir}/ffmpeg_g" "${build_dir}/ffprobe_g" "${build_dir}/ffplay_g"; do
    [[ -f "${binary}" ]] || continue
    info=$(LC_ALL=C "${readelf}" --program-headers --dynamic --version-info "${binary}")
    needed=$(awk '/\(NEEDED\)/ { sub(/^.*\[/, ""); sub(/\].*$/, ""); print }' <<<"${info}")
    if [[ ${variant} == cpu ]]; then
        if grep -Eq '(^|[[:space:]])INTERP([[:space:]]|$)|Requesting program interpreter:' <<<"${info}"; then
            echo "${binary}: CPU variant has a dynamic interpreter" >&2
            exit 1
        fi
        if [[ -n ${needed} ]]; then
            echo "${binary}: CPU variant has shared startup dependencies: ${needed}" >&2
            exit 1
        fi
        echo "${binary}: CPU variant has no shared startup runtime"
        continue
    fi
    if ! grep -Fq 'Requesting program interpreter: /lib64/ld-linux-x86-64.so.2]' <<<"${info}"; then
        echo "${binary}: missing Linux x86_64 runtime linker" >&2
        exit 1
    fi
    if ! grep -Fxq 'libc.so.6' <<<"${needed}"; then
        echo "${binary}: missing dynamic base libc" >&2
        exit 1
    fi
    while IFS= read -r library; do
        case "${library}" in
            libc.so.6|libm.so.6|libmvec.so.1|ld-linux-x86-64.so.2) ;;
            *) echo "${binary}: unexpected shared dependency ${library}" >&2; exit 1 ;;
        esac
    done <<<"${needed}"
    # Inspect required versions, not symbol-version definitions exported by us.
    # The hardware build compiles and links against the glibc 2.35 sysroot
    # (Ubuntu 22.04, see ffmpeg-linux-x86_64.dockerfile), so 2.35 is the floor
    # it promises; anything newer here means a toolchain archive or a host
    # header leaked into the link.
    versions=$(awk '
        /^Version needs section/ { needs=1 }
        /^Version (symbols|definition) section/ { needs=0 }
        needs && /Name: GLIBC_/ {
            sub(/^.*Name: GLIBC_/, ""); sub(/[[:space:]].*$/, ""); print
        }
    ' <<<"${info}")
    if ! awk '
        NF {
            if ($0 !~ /^[0-9]+([.][0-9]+)+$/) { bad=1; next }
            n=split($0, version, /[.]/)
            major=version[1]+0; minor=version[2]+0
            if (major > 2 || (major == 2 && minor > 35)) bad=1
            if (major == 2 && minor == 35)
                for (i=3; i<=n; i++) if ((version[i]+0) > 0) bad=1
        }
        END { exit bad }
    ' <<<"${versions}"; then
        echo "${binary}: unsupported glibc requirement (maximum GLIBC_2.35): ${versions}" >&2
        exit 1
    fi
    printf '%s: hardware glibc base runtime only: %s\n' "${binary}" "${needed//$'\n'/ }"
done
