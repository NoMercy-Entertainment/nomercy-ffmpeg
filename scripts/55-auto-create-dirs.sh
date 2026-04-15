#!/bin/bash

#/**************************************/#
#/*  NoMercy Entertainment — Auto      */#
#/*  create output directories         */#
#/**************************************/#

# Patch avio_open2 in libavformat to auto-create parent directories
# when opening files for writing. This eliminates "No such file or
# directory" errors when output paths include subdirectories.
#
# Works cross-platform: uses _mkdir on Windows, mkdir on Unix.
# The target file varies by FFmpeg version (avio.c or aviobuf.c),
# so we locate it dynamically.

# --- Locate the file containing avio_open2 ---
AVIO_FILE=""
for candidate in /build/ffmpeg/libavformat/avio.c /build/ffmpeg/libavformat/aviobuf.c; do
    if [ -f "$candidate" ] && grep -q '^int avio_open2' "$candidate"; then
        AVIO_FILE="$candidate"
        break
    fi
done

# Fallback: broader search if the strict anchor didn't match
if [ -z "$AVIO_FILE" ]; then
    for candidate in /build/ffmpeg/libavformat/avio.c /build/ffmpeg/libavformat/aviobuf.c; do
        if [ -f "$candidate" ] && grep -q 'int avio_open2' "$candidate"; then
            AVIO_FILE="$candidate"
            break
        fi
    done
fi

if [ -z "$AVIO_FILE" ]; then
    log "  ERROR: Could not find avio_open2 in any libavformat source file"
    exit 1
fi

log "  Found avio_open2 in: $AVIO_FILE"

# --- Step 1: Add mkdir_p helper function ---
log "Step 1: Adding ff_ensure_dir_exists helper to $(basename "$AVIO_FILE")"

# The helper:
# - Only acts on local file paths (skips URLs with "://")
# - Only acts when AVIO_FLAG_WRITE is set
# - Creates parent directories recursively
# - Cross-platform: uses _mkdir on Windows, mkdir on Unix
# - Handles both / and \ separators

if ! grep -q "ff_ensure_dir_exists" "$AVIO_FILE"; then

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
static void ff_ensure_dir_exists(const char *path, int flags)
{
    char *tmp;
    const char *sep;

    /* Only create dirs for output files */
    if (!(flags & AVIO_FLAG_WRITE))
        return;

    /* Skip non-local paths (URLs with protocol) */
    if (!path || strstr(path, "://"))
        return;

    /* Find the last directory separator */
    sep = NULL;
    for (const char *p = path; *p; p++) {
        if (*p == '/' || *p == '\\')
            sep = p;
    }

    /* No directory component — file is in current dir */
    if (!sep || sep == path)
        return;

    tmp = av_strndup(path, sep - path);
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

    # Find the last #include line and insert after it
    last_include_line=$(grep -n '^#include' "$AVIO_FILE" | tail -1 | cut -d: -f1)

    if [ -z "$last_include_line" ]; then
        log "  ERROR: Could not find #include lines in $(basename "$AVIO_FILE")"
        exit 1
    fi

    sed -i "${last_include_line}r /tmp/mkdir_patch.c" "$AVIO_FILE"
    rm -f /tmp/mkdir_patch.c
    log "  Added ff_ensure_dir_exists helper function"
else
    log "  Helper function already exists"
fi

# Verify helper was added
if grep -q "ff_ensure_dir_exists" "$AVIO_FILE"; then
    log "  Verified helper function in $(basename "$AVIO_FILE")"
else
    log "  ERROR: Helper function verification failed!"
    exit 1
fi

# --- Step 2: Patch avio_open2 to call the helper ---
log "Step 2: Patching avio_open2 to auto-create directories"

if ! grep -q "ff_ensure_dir_exists(filename, flags)" "$AVIO_FILE"; then
    # Find the avio_open2 function and insert the call after the opening brace.
    # Use a flexible pattern that matches regardless of qualifiers or formatting.
    awk '
    /int avio_open2\(/ { in_func=1 }
    in_func && /\{/ {
        print
        print "    ff_ensure_dir_exists(filename, flags);"
        in_func=0
        next
    }
    { print }
    ' "$AVIO_FILE" > /tmp/avio_patched.c

    # Verify the awk output is non-empty and contains the patch
    if [ -s /tmp/avio_patched.c ] && grep -q "ff_ensure_dir_exists(filename, flags);" /tmp/avio_patched.c; then
        mv /tmp/avio_patched.c "$AVIO_FILE"
        log "  Patched avio_open2"
    else
        rm -f /tmp/avio_patched.c
        log "  ERROR: awk failed to patch avio_open2 — function signature may have changed"
        exit 1
    fi
else
    log "  avio_open2 already patched"
fi

# Verify the patch
if grep -A5 "avio_open2" "$AVIO_FILE" | grep -q "ff_ensure_dir_exists"; then
    log "  Verified avio_open2 patch"
else
    log "  ERROR: avio_open2 patch verification failed!"
    exit 1
fi

exit 0
