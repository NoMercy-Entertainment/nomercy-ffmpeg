if [[ ${TARGET_OS} != "windows" ]]; then
    exit 255
fi

# Windows VERSIONINFO requires exactly 4 comma-separated 16-bit ints.
# Parse ffmpeg_version (e.g. "8.1.1") and pad/truncate to 4 components.
IFS=. read -r _maj _min _pat _extra <<<"${ffmpeg_version}"
FILEVERSION="${_maj:-0},${_min:-0},${_pat:-0},${_extra:-0}"

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