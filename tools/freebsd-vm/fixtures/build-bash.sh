#!/bin/bash
# Test-only FreeBSD Bash. Never add its output to an FFmpeg release archive.
# Usage: build-bash.sh SOURCE-DIRECTORY OUTPUT-DIRECTORY
# SOURCE-DIRECTORY contains the GNU tarball, detached signature and keyring.
set -euo pipefail
source_dir=$(cd "${1:?GNU source directory required}" && pwd)
mkdir -p "${2:?output directory required}"
out=$(cd "$2" && pwd)
: "${CC:?FreeBSD target C compiler required}"
: "${CROSS_PREFIX:?FreeBSD cross-toolchain prefix required}"
bash_release=5.2.37
tarball="bash-${bash_release}.tar.gz"
expected=9599b22ecd1d5787ad7d3b7bf0c59f312b3396d1e281175dd1f8a4014da621ff
printf '%s  %s\n' "$expected" "$source_dir/$tarball" | sha256sum -c -
gpgv --keyring "$source_dir/gnu-keyring.gpg" --status-fd 1 \
    "$source_dir/$tarball.sig" "$source_dir/$tarball" >"$out/bash-signature.log" 2>&1 || {
        cat "$out/bash-signature.log"; exit 1;
    }
grep -q '^\[GNUPG:\] VALIDSIG 7C0135FB088AAF6C66C650B9BB5869F064EA74AB ' "$out/bash-signature.log"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tar -xzf "$source_dir/$tarball" -C "$work"
cd "$work/bash-$bash_release"
# FreeBSD's dynamic base already provides dlopen; avoid configure adding -ldl.
ac_cv_lib_dl_dlopen=no CC_FOR_BUILD=gcc ./configure --build="$(sh support/config.guess)" \
    --host=x86_64-unknown-freebsd14 --disable-readline --disable-history \
    --disable-bang-history --disable-progcomp --disable-nls \
    --without-curses --without-bash-malloc >"$out/bash-configure.log" 2>&1 || {
        cat "$out/bash-configure.log"; tail -80 config.log; exit 1;
    }
make -j2 bash >"$out/bash-build.log" 2>&1 || { tail -100 "$out/bash-build.log"; exit 1; }
cp bash "$out/bash"
"${CROSS_PREFIX}strip" "$out/bash"
"${CROSS_PREFIX}readelf" --program-headers --dynamic "$out/bash" >"$out/bash-elf.txt"
cp config.log "$out/bash-config.log"
printf '%s  %s\n' "$expected" "$tarball" >"$out/bash-source.sha256"
echo 'Built test-only Bash 5.2.37 for FreeBSD 14.3'
