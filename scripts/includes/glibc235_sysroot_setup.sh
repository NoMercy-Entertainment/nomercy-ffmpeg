#!/bin/bash
# Point the Linux x86_64 hardware build at the glibc 2.35 sysroot.
#
# The hardware variant links the host's glibc dynamically, so the glibc it is
# compiled and linked against is the oldest one it can start on. The base
# image is Ubuntu 24.04 (glibc 2.39); the sysroot in /opt/glibc235 holds
# Ubuntu 22.04's glibc headers and libraries (ffmpeg-linux-x86_64.dockerfile,
# stage glibc235-sysroot), which gives the archive a 2.35 floor: Ubuntu 22.04,
# Debian 12 and everything newer.
#
# Ubuntu's gcc is not built with a sysroot, so --sysroot alone is not enough:
# it moves the headers, but the driver still hands ld its own library
# directory first (/usr/lib/gcc/x86_64-linux-gnu/13/../../../x86_64-linux-gnu),
# so libc.so would still be the host's 2.39. The wrappers written here add
# sysroot-relative -L= directories after the caller's own options, so they
# come after the build prefix's -L (the prefix's libX11, libxcb and friends
# must keep winning over the sysroot's) and before gcc's own directory; a
# linker script found in a sysrooted directory has its absolute member paths
# prefixed with the sysroot too, so libc.so.6, libm.so.6, libmvec.so.1 and
# ld-linux all resolve inside /opt/glibc235. The start files (crt1.o, crti.o,
# crtn.o) still come from the host: their only import is __libc_start_main,
# GLIBC_2.34 since glibc 2.34, and the probe below plus
# scripts/includes/verify_linux_runtime.sh reject anything newer than 2.35
# in any case.
#
# gcc 13's own static libstdc++.a and libgomp.a were compiled on 24.04 and
# name four symbols glibc 2.35 does not have (__isoc23_strtol/strtoul/strtoull
# and arc4random). glibc235_compat.c supplies them; it is appended to the
# sysroot's libc_nonshared.a, the archive glibc's libc.so linker script pulls
# into every link, so every C++ or OpenMP program in the build links without
# a flag in any script.
#
# The wrappers shadow every name a build system uses (CC's x86_64-linux-gnu-*
# names, and gcc/g++/cpp/cc/c++ for cargo, nvcc and whatever calls `cc`), so
# CMake, Meson, autotools, cargo and nvcc all compile against 2.35 headers
# and link against 2.35 libraries. The CPU variant never runs this script:
# it is fully static and has no glibc version requirement at all.
#
# Usage: glibc235_sysroot_setup.sh [SYSROOT]   (default /opt/glibc235)
set -euo pipefail

sysroot=${1:-/opt/glibc235}
libdir=${sysroot}/usr/lib/x86_64-linux-gnu
here=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
real_gcc=/usr/bin/x86_64-linux-gnu-gcc-13
work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

die() { echo "glibc235 sysroot: $*" >&2; exit 1; }

[[ -x ${real_gcc} ]] || die "${real_gcc} is missing; the base image's toolchain changed"
[[ -f ${sysroot}/usr/include/features.h ]] || die "no glibc headers under ${sysroot}"
[[ -f ${libdir}/libc.so && -f ${libdir}/libc_nonshared.a ]] || die "no glibc libraries under ${libdir}"
minor=$(sed -n 's/^#define[[:space:]]*__GLIBC_MINOR__[[:space:]]*//p' "${sysroot}/usr/include/features.h")
[[ ${minor} == 35 ]] || die "sysroot is glibc 2.${minor}, expected 2.35"

# 1. The four toolchain symbols, into libc_nonshared.a. `ar r` replaces an
#    existing member, so rerunning this script is harmless.
"${real_gcc}" --sysroot="${sysroot}" -O2 -fPIC -Wall -Wextra -Werror \
    -c "${here}/glibc235_compat.c" -o "${work}/glibc235_compat.o"
ar rcs "${libdir}/libc_nonshared.a" "${work}/glibc235_compat.o"

# 2. Every C++ and OpenMP runtime in this build is static (-static-libstdc++
#    and -static-libgcc sit in CFLAGS/LDFLAGS, and the final link wrapper
#    supplies them itself). rustc does not read those flags: when a crate
#    asks for the C++ runtime (librsvg's rsvg-convert does, through a C++
#    dependency) it passes a plain -lstdc++, which finds gcc 13's shared
#    libstdc++.so. That library was built on 24.04 and needs arc4random and
#    __isoc23_strtoul from libc, which the 2.35 libc.so.6 cannot supply, so
#    lld refuses the link ("disallowed by --no-allow-shlib-undefined"). These
#    linker scripts sit in the sysroot's library directory, which the wrappers
#    search before gcc's own, and turn a shared request for libstdc++ or
#    libgomp into the static archive, whose four missing names step 1 supplies.
for runtime in libstdc++ libgomp; do
    {
        echo "/* glibc 2.35 sysroot: the C++ and OpenMP runtimes are static in this build; see glibc235_sysroot_setup.sh */"
        echo "INPUT(-l:${runtime}.a)"
    } > "${libdir}/${runtime}.so"
done

# 3. Compiler wrappers, in /usr/local/bin which precedes /usr/bin on PATH.
for tool in gcc g++ cpp; do
    wrapper=/usr/local/bin/x86_64-linux-gnu-${tool}
    cat > "${wrapper}" <<EOF
#!/bin/sh
# glibc 2.35 sysroot wrapper, written by scripts/includes/glibc235_sysroot_setup.sh
exec /usr/bin/x86_64-linux-gnu-${tool}-13 --sysroot=${sysroot} "\$@" -L=/usr/lib/x86_64-linux-gnu -L=/lib/x86_64-linux-gnu
EOF
    chmod +x "${wrapper}"
    ln -sf "x86_64-linux-gnu-${tool}" "/usr/local/bin/${tool}"
done
ln -sf x86_64-linux-gnu-gcc /usr/local/bin/cc
ln -sf x86_64-linux-gnu-g++ /usr/local/bin/c++
hash -r 2>/dev/null || true

# 4. Prove it, before the first dependency builds. The probe exercises what
#    the real link exercises: C++ exceptions and strings (libstdc++.a's
#    eh_alloc.o and the strtoul it parses GLIBCXX_TUNABLES with),
#    std::random_device (arc4random), OpenMP (libgomp.a's env parsing),
#    threads, and libm's fmod, whose symbol version changed in glibc 2.38.
cat > "${work}/probe.cpp" <<'EOF'
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <random>
#include <string>
#include <thread>
extern "C" int omp_get_max_threads(void);
int main(int, char **argv)
{
    std::thread t([] { std::puts("thread ok"); });
    t.join();
    std::random_device rd;
    unsigned r = rd();
    try {
        throw std::stoi(std::string("7"));
    } catch (int v) {
        std::printf("probe ok %d %ld %d %.1f %u\n", v, std::strtol(argv[0], nullptr, 10),
                    omp_get_max_threads(), std::fmod(7.5, 2.0), r & 0u);
    }
    return 0;
}
EOF
# The same shape as the final link: static C++, gcc and OpenMP runtimes,
# dynamic glibc base only. -Wl,-t prints every file the linker opened.
x86_64-linux-gnu-g++ -O2 -fopenmp -static-libgcc -static-libstdc++ "${work}/probe.cpp" -o "${work}/probe" \
    -Wl,-Bstatic -lgomp -Wl,-Bdynamic -lm -Wl,-t > "${work}/probe.trace" 2>&1 \
    || { cat "${work}/probe.trace"; die "the probe does not link"; }
"${work}/probe" || die "the probe does not run"

# The shape rustc uses for a host tool: plain -lstdc++ and -lgomp with the
# shared runtime requested, linked by lld, which refuses a shared library
# whose own glibc needs the host cannot meet. Must resolve to the archives.
rust_lld=$(ls -d /opt/rustup/toolchains/*/lib/rustlib/x86_64-unknown-linux-gnu/bin/gcc-ld 2>/dev/null | head -1 || true)
cat > "${work}/dyn.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv)
{
    printf("dyn ok %ld\n", strtol(argv[0], NULL, 10) + argc);
    return 0;
}
EOF
x86_64-linux-gnu-gcc -O2 -c "${work}/dyn.c" -o "${work}/dyn.o"
for linker in bfd ${rust_lld:+lld}; do
    extra=()
    [[ ${linker} == lld ]] && extra=(-fuse-ld=lld "-B${rust_lld}")
    x86_64-linux-gnu-gcc "${extra[@]}" "${work}/dyn.o" -o "${work}/dyn-${linker}" \
        -Wl,--as-needed -Wl,-Bdynamic -lstdc++ -lgomp -lgcc_s -lc -Wl,--no-allow-shlib-undefined \
        || die "a shared -lstdc++/-lgomp request does not link with ${linker}"
    "${work}/dyn-${linker}" >/dev/null || die "the ${linker}-linked program does not run"
    if readelf -d "${work}/dyn-${linker}" | grep -qE 'libstdc|libgomp'; then
        die "the ${linker} link still took the shared C++/OpenMP runtime"
    fi
done

# Headers: the wrapper must resolve <features.h> inside the sysroot.
features=$(echo '#include <features.h>' | x86_64-linux-gnu-gcc -E -M -x c - | tr ' ' '\n' | grep -m1 'features\.h$')
[[ ${features} == "${sysroot}"/* ]] || die "headers come from ${features}, not the sysroot"

# Libraries: every glibc file the linker opened must be the sysroot's.
for name in libc.so.6 libm.so.6 libc_nonshared.a; do
    opened=$(grep -oE "[^ ()]*${name}" "${work}/probe.trace" | sort -u | tr '\n' ' ')
    [[ -n ${opened} ]] || die "the linker never opened ${name}"
    for f in ${opened}; do
        [[ ${f} == "${sysroot}"/* ]] || { cat "${work}/probe.trace"; die "${name} was taken from ${f}, not the sysroot"; }
    done
done

# Result: nothing above GLIBC_2.35, none of the four names left dynamic.
versions=$(readelf -V "${work}/probe" | grep -oE 'GLIBC_[0-9.]+' | sort -u | tr '\n' ' ')
echo "glibc235 sysroot: probe imports ${versions}"
if echo "${versions}" | grep -qE 'GLIBC_2\.(3[6-9]|[4-9][0-9])|GLIBC_[3-9]'; then
    die "the probe imports glibc above 2.35"
fi
if nm -D --undefined-only "${work}/probe" | grep -qE '__isoc23_|arc4random'; then
    die "the probe still names a post-2.35 symbol dynamically"
fi
needed=$(readelf -d "${work}/probe" | awk '/\(NEEDED\)/ { sub(/^.*\[/, ""); sub(/\].*$/, ""); print }' | tr '\n' ' ')
echo "glibc235 sysroot: probe needs ${needed}"
echo "glibc235 sysroot: ready at ${sysroot} (glibc 2.${minor}); wrappers in /usr/local/bin"
