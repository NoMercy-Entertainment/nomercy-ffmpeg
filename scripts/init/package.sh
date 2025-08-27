#!/bin/bash

. /scripts/init/helpers.sh
export -f hr text_with_padding

hr
text_with_padding "🔧 Copying FFmpeg binaries" ""

mkdir -p /ffmpeg/${TARGET_OS}/${ARCH}

if [[ ${TARGET_OS} == "windows" ]]; then
    if [ -f ${PREFIX}/bin/ffplay.exe ]; then
        cp ${PREFIX}/bin/ffplay.exe /ffmpeg/${TARGET_OS}/${ARCH}/
    fi

    cp ${PREFIX}/bin/ffmpeg.exe /ffmpeg/${TARGET_OS}/${ARCH}
    cp ${PREFIX}/bin/ffprobe.exe /ffmpeg/${TARGET_OS}/${ARCH}
else
    if [ -f ${PREFIX}/bin/ffplay ]; then
        cp ${PREFIX}/bin/ffplay /ffmpeg/${TARGET_OS}/${ARCH}/
    fi

    cp ${PREFIX}/bin/ffmpeg /ffmpeg/${TARGET_OS}/${ARCH}
    cp ${PREFIX}/bin/ffprobe /ffmpeg/${TARGET_OS}/${ARCH}
fi

find ${PREFIX} -name '*.jar' -exec cp {} /ffmpeg/${TARGET_OS}/${ARCH}/ \;

text_with_padding "✅ FFmpeg binaries copied successfully" ""
hr

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
if [[ ${TARGET_OS} == "windows" ]]; then
    zip -r /build/ffmpeg-8.0-${TARGET_OS}-${ARCH}.zip . >/dev/null 2>&1
else
    tar -czf /build/ffmpeg-8.0-${TARGET_OS}-${ARCH}.tar.gz . >/dev/null 2>&1
fi
cp /build/ffmpeg-8.0-${TARGET_OS}-${ARCH}.* /output

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

cp /ffmpeg/${TARGET_OS}/${ARCH} /build/${TARGET_OS} -r

text_with_padding "📦 FFmpeg build completed" ""
hr

exit 0
