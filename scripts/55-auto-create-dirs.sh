#!/bin/bash

#/**************************************/#
#/*  NoMercy Entertainment — Auto      */#
#/*  create output directories         */#
#/**************************************/#

# Patch avio_open2 in aviobuf.c to auto-create parent directories
# when opening files for writing. This eliminates "No such file or
# directory" errors when output paths include subdirectories.

log "Step 1: Adding mkdir_p helper to aviobuf.c"

# Add the necessary includes and helper function at the top of aviobuf.c,
# after the existing #include block.
#
# The helper:
# - Only acts on local file paths (skips URLs with "://")
# - Only acts when AVIO_FLAG_WRITE is set
# - Creates parent directories recursively
# - Cross-platform: uses _mkdir on Windows, mkdir on Unix
# - Handles both / and \ separators

# Check if already patched
if ! grep -q "ff_ensure_dir_exists" /build/ffmpeg/libavformat/aviobuf.c; then

    # First, add the includes and helper function after the last #include
    cat > /tmp/mkdir_patch.c << 'MKDIRPATCH'

/* --- NoMercy: auto-create output directories --- */
#include <sys/stat.h>
#ifdef _WIN32
#include <direct.h>
#define ff_local_mkdir(p) _mkdir(p)
#else
#define ff_local_mkdir(p) mkdir(p, 0755)
#endif

/**
 * Recursively create parent directories for a file path.
 * Only operates on local file paths (no protocol prefix).
 */
static void ff_ensure_dir_exists(const char *path, int flags)
{
    char *tmp, *sep;

    /* Only create dirs for output files */
    if (!(flags & AVIO_FLAG_WRITE))
        return;

    /* Skip non-local paths (URLs with protocol) */
    if (!path || strstr(path, "://"))
        return;

    /* Find the last directory separator */
    sep = NULL;
    for (char *p = (char *)path; *p; p++) {
        if (*p == '/' || *p == '\\')
            sep = p;
    }

    /* No directory component — file is in current dir */
    if (!sep || sep == path)
        return;

    tmp = av_strndup(path, sep - path);
    if (!tmp)
        return;

    /* Recursively create directories */
    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/' || *p == '\\') {
            char saved = *p;
            *p = '\0';
            ff_local_mkdir(tmp);
            *p = saved;
        }
    }
    ff_local_mkdir(tmp);
    av_free(tmp);
}
/* --- End NoMercy patch --- */
MKDIRPATCH

    # Find the last #include line in aviobuf.c and insert after it
    last_include_line=$(grep -n '^#include' /build/ffmpeg/libavformat/aviobuf.c | tail -1 | cut -d: -f1)

    if [ -z "$last_include_line" ]; then
        log "  ERROR: Could not find #include lines in aviobuf.c"
        exit 1
    fi

    # Insert the helper function after the last #include
    sed -i "${last_include_line}r /tmp/mkdir_patch.c" /build/ffmpeg/libavformat/aviobuf.c

    rm -f /tmp/mkdir_patch.c
    log "  Added mkdir_p helper function"
else
    log "  Helper function already exists"
fi

# Verify helper was added
if grep -q "ff_ensure_dir_exists" /build/ffmpeg/libavformat/aviobuf.c; then
    log "  Verified helper function in aviobuf.c"
else
    log "  ERROR: Helper function verification failed!"
    exit 1
fi

# Step 2: Patch avio_open2 to call the helper
log "Step 2: Patching avio_open2 to auto-create directories"

if ! grep -q "ff_ensure_dir_exists(filename, flags)" /build/ffmpeg/libavformat/aviobuf.c; then
    # We need to find the avio_open2 function body and add the call
    # at the very beginning of the function, after the opening brace.
    # The function signature is:
    #   int avio_open2(AVIOContext **s, const char *filename, int flags,
    #                  const AVIOInterruptCB *int_cb, AVDictionary **options)

    # Add the call right after the opening brace of avio_open2
    # Use awk to find the function and insert after {
    awk '
    /^int avio_open2\(/ { in_func=1 }
    in_func && /\{/ {
        print
        print "    ff_ensure_dir_exists(filename, flags);"
        in_func=0
        next
    }
    { print }
    ' /build/ffmpeg/libavformat/aviobuf.c > /tmp/aviobuf_patched.c \
        && mv /tmp/aviobuf_patched.c /build/ffmpeg/libavformat/aviobuf.c

    log "  Patched avio_open2"
else
    log "  avio_open2 already patched"
fi

# Verify the patch
if grep -A5 "avio_open2" /build/ffmpeg/libavformat/aviobuf.c | grep -q "ff_ensure_dir_exists"; then
    log "  Verified avio_open2 patch"
else
    log "  ERROR: avio_open2 patch verification failed!"
    exit 1
fi

exit 0
