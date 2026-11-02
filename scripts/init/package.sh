#!/bin/bash

. /scripts/init/helpers.sh

# This script ended in `exit 0` whatever happened, so a failed copy or a
# failed tar still passed the Docker RUN step and produced a release with a
# missing or empty archive. The steps that make the artifact are now checked
# one by one: copying ffmpeg/ffprobe, signing, archiving, and the copy to
# /output.
#
# Deliberately NOT `set -euo pipefail`, though that is the usual remedy.
# pipefail turns `file "$bin" | grep -q Mach-O` below into the SIGPIPE trap
# this repository has hit before: grep -q closes the pipe on its first match,
# file can take SIGPIPE, and the condition goes false -- so the binary is
# silently left unsigned, and an unsigned darwin-arm64 binary does not run on
# macOS 11+. set -e would also make the best-effort apt-get cleanup fatal,
# and set -u would apply to helpers.sh, which was not written for it.
export -f hr text_with_padding

hr
text_with_padding "🔧 Copying FFmpeg binaries" ""

mkdir -p /ffmpeg/${TARGET_OS}/${ARCH}

if [[ ${TARGET_OS} == "windows" ]]; then
    if [ -f ${PREFIX}/bin/ffplay.exe ]; then
        cp ${PREFIX}/bin/ffplay.exe /ffmpeg/${TARGET_OS}/${ARCH}/
    fi

    cp ${PREFIX}/bin/ffmpeg.exe /ffmpeg/${TARGET_OS}/${ARCH} || exit 1
    cp ${PREFIX}/bin/ffprobe.exe /ffmpeg/${TARGET_OS}/${ARCH} || exit 1
else
    if [ -f ${PREFIX}/bin/ffplay ]; then
        cp ${PREFIX}/bin/ffplay /ffmpeg/${TARGET_OS}/${ARCH}/
    fi

    cp ${PREFIX}/bin/ffmpeg /ffmpeg/${TARGET_OS}/${ARCH} || exit 1
    cp ${PREFIX}/bin/ffprobe /ffmpeg/${TARGET_OS}/${ARCH} || exit 1
fi

find ${PREFIX} -name '*.jar' -exec cp {} /ffmpeg/${TARGET_OS}/${ARCH}/ \;

text_with_padding "✅ FFmpeg binaries copied successfully" ""
hr

# Ad-hoc sign Darwin (macOS) binaries
# ld64 applies a signature during linking, but strip invalidates it.
# ARM64 binaries MUST have a valid signature to run on macOS 11+.
# rcodesign produces proper code directory signatures that satisfy
# macOS kernel enforcement for ARM64 binaries.
if [[ ${TARGET_OS} == "darwin" ]] && command -v rcodesign &> /dev/null; then
    text_with_padding "🔏 Ad-hoc signing Darwin binaries" ""
    for bin in /ffmpeg/${TARGET_OS}/${ARCH}/*; do
        if [ -f "$bin" ] && file "$bin" | grep -q "Mach-O"; then
            rcodesign sign "$bin" || exit 1
            text_with_padding "  ✅ Signed $(basename $bin)" ""
        fi
    done
    text_with_padding "✅ Darwin binaries signed" ""
    hr
fi

# cleanup
text_with_padding "🧹 Pre Cleaning up" ""
rm -rf ${PREFIX} /build
mkdir -p /build/${TARGET_OS} /output
text_with_padding "✅ Pre Clean up completed" ""
hr

# create zipfile
if [[ ${TARGET_OS} == "windows" ]]; then
    text_with_padding "⚙️ Creating FFmpeg zip file" ""
else
    text_with_padding "⚙️ Creating FFmpeg tar file" ""
fi
cd /ffmpeg/${TARGET_OS}/${ARCH}
# ffmpeg_version is exported by the base image (ffmpeg-base.dockerfile). It is
# the single source of truth for the artifact version — bumping ffmpeg_version
# there flows through to every artifact filename produced here.
: "${ffmpeg_version:?ffmpeg_version env var must be set by the base image}"
if [[ ${TARGET_OS} == "windows" ]]; then
    zip -r /build/ffmpeg-${ffmpeg_version}-${TARGET_OS}-${ARCH}.zip . >/dev/null || exit 1
else
    tar -czf /build/ffmpeg-${ffmpeg_version}-${TARGET_OS}-${ARCH}.tar.gz . >/dev/null || exit 1
fi
cp /build/ffmpeg-${ffmpeg_version}-${TARGET_OS}-${ARCH}.* /output || exit 1

if [[ ${TARGET_OS} == "windows" ]]; then
    text_with_padding "✅ FFmpeg zip file created successfully" ""
else
    text_with_padding "✅ FFmpeg tar file created successfully" ""
fi
hr

# cleanup
text_with_padding "🧹 After Cleaning up" ""
apt-get autoremove -y >/dev/null 2>&1
apt-get autoclean -y >/dev/null 2>&1
apt-get clean -y >/dev/null 2>&1
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
text_with_padding "✅ After Clean up completed" ""
hr

cp /ffmpeg/${TARGET_OS}/${ARCH} /build/${TARGET_OS} -r || exit 1

text_with_padding "📦 FFmpeg build completed" ""
hr

exit 0
