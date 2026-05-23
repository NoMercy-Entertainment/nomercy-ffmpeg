#!/bin/bash

#/**************************************/#
#/*  NoMercy Entertainment — Auto      */#
#/*  create output directories         */#
#/**************************************/#

# Patch io_open_default in libavformat/options.c to auto-create parent
# directories when opening files for writing. This is the actual entry
# point used by muxers (image2, mp4, mkv, etc.) — NOT avio_open2.
#
# Works cross-platform: uses _mkdir on Windows, mkdir on Unix.

OPTIONS_FILE="/build/ffmpeg/libavformat/options.c"

if [ ! -f "$OPTIONS_FILE" ]; then
    log "  ERROR: $OPTIONS_FILE not found"
    exit 1
fi

log "  Patching: $OPTIONS_FILE"

# --- Step 1: Add ff_ensure_dir_exists helper function ---
log "Step 1: Adding ff_ensure_dir_exists helper"

if ! grep -q "ff_ensure_dir_exists" "$OPTIONS_FILE"; then

    cat > /tmp/mkdir_patch.c << 'MKDIRPATCH'

/* --- NoMercy: auto-create output directories --- */
#include <sys/stat.h>
#include <errno.h>
#ifdef _WIN32
#  include <direct.h>
#  define ff_local_mkdir(p) _mkdir(p)
#else
#  define ff_local_mkdir(p) mkdir(p, 0755)
#endif

/**
 * Recursively create parent directories for a file path.
 * Only operates on local file paths (no protocol prefix).
 * Safe to call when directories already exist (ignores EEXIST).
 */
static void ff_ensure_dir_exists(const char *url, int flags)
{
    char *tmp;
    const char *sep;

    /* Only create dirs for output files */
    if (!(flags & AVIO_FLAG_WRITE))
        return;

    /* Skip non-local paths (URLs with protocol) */
    if (!url || strstr(url, "://"))
        return;

    /* Find the last directory separator */
    sep = NULL;
    for (const char *p = url; *p; p++) {
        if (*p == '/' || *p == '\\')
            sep = p;
    }

    /* No directory component — file is in current dir */
    if (!sep || sep == url)
        return;

    tmp = av_strndup(url, sep - url);
    if (!tmp)
        return;

    /* Recursively create directories, ignoring EEXIST.
     * Skip root prefixes so we don't try to mkdir "C:" or "\\server". */
    char *start = tmp + 1;
#ifdef _WIN32
    /* Drive letter prefix: skip past "C:\\" */
    if (((tmp[0] >= 'A' && tmp[0] <= 'Z') || (tmp[0] >= 'a' && tmp[0] <= 'z'))
        && tmp[1] == ':' && (tmp[2] == '/' || tmp[2] == '\\'))
        start = tmp + 3;
    /* UNC prefix: skip past "\\server\share" */
    else if ((tmp[0] == '/' || tmp[0] == '\\') && tmp[0] == tmp[1]) {
        int slashes = 0;
        for (start = tmp + 2; *start && slashes < 2; start++)
            if (*start == '/' || *start == '\\') slashes++;
    }
#endif
    for (char *p = start; *p; p++) {
        if (*p == '/' || *p == '\\') {
            char saved = *p;
            *p = '\0';
            if (ff_local_mkdir(tmp) != 0 && errno != EEXIST) {
                av_free(tmp);
                return;
            }
            *p = saved;
        }
    }
    if (ff_local_mkdir(tmp) != 0 && errno != EEXIST) {
        /* best-effort: don't fail the open */
    }
    av_free(tmp);
}
/* --- End NoMercy patch --- */
MKDIRPATCH

    # Insert after the last #include in options.c
    last_include_line=$(grep -n '^#include' "$OPTIONS_FILE" | tail -1 | cut -d: -f1)

    if [ -z "$last_include_line" ]; then
        log "  ERROR: Could not find #include lines in options.c"
        exit 1
    fi

    sed -i "${last_include_line}r /tmp/mkdir_patch.c" "$OPTIONS_FILE"
    rm -f /tmp/mkdir_patch.c
    log "  Added ff_ensure_dir_exists helper"
else
    log "  Helper already exists"
fi

# Verify helper was added
if ! grep -q "ff_ensure_dir_exists" "$OPTIONS_FILE"; then
    log "  ERROR: Helper function verification failed!"
    exit 1
fi

# --- Step 2: Patch io_open_default to call the helper ---
log "Step 2: Patching io_open_default"

if ! grep -q "ff_ensure_dir_exists(url, flags)" "$OPTIONS_FILE"; then
    awk '
    /static int io_open_default\(/ { in_func=1 }
    in_func && /\{/ {
        print
        print "    ff_ensure_dir_exists(url, flags);"
        in_func=0
        next
    }
    { print }
    ' "$OPTIONS_FILE" > /tmp/options_patched.c

    if [ -s /tmp/options_patched.c ] && grep -q "ff_ensure_dir_exists(url, flags);" /tmp/options_patched.c; then
        mv /tmp/options_patched.c "$OPTIONS_FILE"
        log "  Patched io_open_default"
    else
        rm -f /tmp/options_patched.c
        log "  ERROR: awk failed to patch io_open_default"
        exit 1
    fi
else
    log "  io_open_default already patched"
fi

# Verify the patch
if grep -A5 "io_open_default" "$OPTIONS_FILE" | grep -q "ff_ensure_dir_exists"; then
    log "  Verified io_open_default patch"
else
    log "  ERROR: io_open_default patch verification failed!"
    exit 1
fi

exit 0
