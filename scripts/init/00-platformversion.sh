#!/bin/bash

if [[ ${TARGET_OS} != "darwin" ]]; then
    exit 255
fi

# Create necessary directory and file
mkdir -p /Library/Preferences/ ${PREFIX}/lib
touch /Library/Preferences/com.apple.dt.Xcode.plist

# Create platformversion.c
cat <<EOF >platformversion.c
#include <stdio.h>
int __isPlatformVersionAtLeast(int major, int minor, int patch) {
    return 1; // Assume the platform version is always compatible
}
EOF

# Compile platformversion.c
${CC} -c platformversion.c -o platformversion.o

# Create static library
${AR} rcs libplatformversion.a platformversion.o

# Copy to target directory
cp libplatformversion.a ${PREFIX}/lib/

add_ldflag "-lplatformversion"

exit 0