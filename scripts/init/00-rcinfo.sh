if [[ ${TARGET_OS} != "windows" ]]; then
    exit 255
fi

FILEVERSION=$(echo "${ffmpeg_version}" | sed 's/\./,/g'),0,0

cp "/scripts/resources/fftools.ico" "/build/ffmpeg/fftools/fftools.ico" || exit 1

cat <<EOF >"/build/ffmpeg/fftools/fftoolsres.rc"
#include <windows.h>

1 ICON              fftools.ico
1 VERSIONINFO
FILEVERSION         ${FILEVERSION}
PRODUCTVERSION      ${FILEVERSION}
{
    BLOCK "StringFileInfo"
    {
        BLOCK "040904B0"
        {
            VALUE "CompanyName",      "FFmpeg Project"
            VALUE "FileDescription",  "FFmpeg command-line tools"
            VALUE "FileVersion",      "${ffmpeg_version}-NoMercyMediaServer"
            VALUE "InternalName",     "ffmpeg.exe"
            VALUE "LegalCopyright",   "Copyright (C) 2000-$(date +%Y) FFmpeg Project"
            VALUE "ProductName",      "FFmpeg"
            VALUE "ProductVersion",   "${ffmpeg_version}-NoMercyMediaServer"
        }
    }

    BLOCK "VarFileInfo"
    {
        VALUE "Translation", 0x0409, 0x04B0
    }
}
EOF

chmod +x "/build/ffmpeg/fftools/fftoolsres.rc" || exit 1

exit 0