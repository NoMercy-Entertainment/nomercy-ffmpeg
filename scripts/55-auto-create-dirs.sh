#!/bin/bash

#/**************************************/#
#/*  NoMercy Entertainment — Auto      */#
#/*  create output directories         */#
#/**************************************/#

# Create the missing parent folders of any local file FFmpeg opens for
# writing, so an output can go into a folder that does not exist yet.
#
# The hook sits in file_open() in libavformat/file.c: the open callback of
# the "file" protocol. Every local write reaches it, whoever starts it:
#   - the ffmpeg tool's main output: avio_open2() -> ffio_open_whitelist()
#     -> ffurl_open_whitelist() -> file_open()  (issue #134: this path never
#     reached the old hook in io_open_default())
#   - files a muxer opens itself (image2, hls, dash, segment, spritevtt):
#     io_open_default() -> ffio_open_whitelist() -> ... -> file_open()
#   - direct ffurl_open_whitelist() callers (smoothstreaming, tee:, md5:)
# Because the protocol is already resolved there, pipe:, http:// and every
# other protocol never get here, and file_open() strips a leading "file:"
# itself before the hook runs, so "file:out/o.mp4" creates "out", not
# "file:out".
#
# mkdir() and stat() come from os_support.h, which file.c already includes:
# on Windows it maps them to the UTF-8 aware _wmkdir/stat calls and pulls in
# direct.h; on Linux, darwin and FreeBSD they are the POSIX calls from
# sys/stat.h. Best effort: a failed mkdir never fails the open, the open
# itself reports the real error.
#
# Patched by text match only. Each anchor must match exactly once, or the
# step fails: line-number patches silently patch the wrong place when the
# FFmpeg source moves.

FILE_C="/build/ffmpeg/libavformat/file.c"
OPTIONS_FILE="/build/ffmpeg/libavformat/options.c"

HELPER_ANCHOR='#include "url.h"'
CALL_ANCHOR='    fd = avpriv_open(filename, access, 0666);'
HELPER_MARK='static void nm_ensure_parent_dirs(const char *path)'
CALL_MARK='        nm_ensure_parent_dirs(filename);'

if [ ! -f "$FILE_C" ]; then
    log "  ERROR: $FILE_C not found"
    exit 1
fi

# Count whole lines that equal the given text exactly.
count_lines() {  # file, text
    grep -cxF -- "$2" "$1"
}

log "  Patching: $FILE_C"

# --- Step 0: refuse a tree patched by the old io_open_default hook ---
# The old hook ran before file_open() and turned "file:out/o.mp4" into a
# folder named "file:out". A fresh FFmpeg tree never has it; finding it
# means this tree was patched by the previous version of this script.
log "Step 0: Checking options.c for the old io_open_default hook"
if [ -f "$OPTIONS_FILE" ] && grep -q "ff_ensure_dir_exists" "$OPTIONS_FILE"; then
    log "  ERROR: $OPTIONS_FILE still carries the old ff_ensure_dir_exists hook; start from a clean FFmpeg tree"
    exit 1
fi
log "  No old hook in options.c"

helper_count=$(count_lines "$FILE_C" "$HELPER_MARK")
call_count=$(count_lines "$FILE_C" "$CALL_MARK")

if [ "$helper_count" -eq 1 ] && [ "$call_count" -eq 1 ]; then
    log "  file.c already patched"
    exit 0
fi
if [ "$helper_count" -ne 0 ] || [ "$call_count" -ne 0 ]; then
    log "  ERROR: file.c is partly patched (helper=${helper_count}, call=${call_count}); start from a clean FFmpeg tree"
    exit 1
fi

# Both anchors are checked before anything is written, so a moved anchor
# fails the step with file.c left exactly as it was.
for anchor in "$HELPER_ANCHOR" "$CALL_ANCHOR"; do
    anchor_count=$(count_lines "$FILE_C" "$anchor")
    if [ "$anchor_count" -ne 1 ]; then
        log "  ERROR: expected exactly 1 line '${anchor}' in file.c, found ${anchor_count}"
        exit 1
    fi
done

# --- Step 1: Add the nm_ensure_parent_dirs helper ---
log "Step 1: Adding nm_ensure_parent_dirs helper"

HELPER_FILE=$(mktemp)
cat > "$HELPER_FILE" << 'MKDIRPATCH'

/* --- NoMercy: auto-create output directories (issue #134) --- */
#include <errno.h>

#ifdef _WIN32
#  define NM_IS_DIR_SEP(c) ((c) == '/' || (c) == '\\')
#else
#  define NM_IS_DIR_SEP(c) ((c) == '/')
#endif

/**
 * Create the missing parent directories of a local file that is about to be
 * opened for writing. Best effort: every failure is ignored and errno is left
 * as it was, so the open that follows reports the real error.
 */
static void nm_ensure_parent_dirs(const char *path)
{
    struct stat st;
    const char *sep = NULL;
    char *dir, *start, *p;
    int saved_errno = errno;

    if (!path || !*path)
        return;

    for (const char *q = path; *q; q++)
        if (NM_IS_DIR_SEP(*q))
            sep = q;

    /* No folder part, or the file sits in the root folder. */
    if (!sep || sep == path)
        return;

    dir = av_strndup(path, sep - path);
    if (!dir)
        return;

    /* The common case: the folder is already there. */
    if (!stat(dir, &st) && S_ISDIR(st.st_mode))
        goto done;

    /* Never try to create a root: skip "/" here, and on Windows "C:\" and
     * "\\server\share\" (which also covers "\\?\C:\"). */
    start = dir + 1;
#ifdef _WIN32
    if (((dir[0] >= 'A' && dir[0] <= 'Z') || (dir[0] >= 'a' && dir[0] <= 'z')) &&
        dir[1] == ':' && NM_IS_DIR_SEP(dir[2])) {
        start = dir + 3;
    } else if (NM_IS_DIR_SEP(dir[0]) && NM_IS_DIR_SEP(dir[1])) {
        int seps = 0;
        for (start = dir + 2; *start && seps < 2; start++)
            if (NM_IS_DIR_SEP(*start))
                seps++;
    }
#endif

    for (p = start; *p; p++) {
        if (NM_IS_DIR_SEP(*p)) {
            char saved = *p;
            *p = '\0';
            (void)mkdir(dir, 0755);
            *p = saved;
        }
    }
    (void)mkdir(dir, 0755);

done:
    av_free(dir);
    errno = saved_errno;
}
/* --- End NoMercy patch --- */
MKDIRPATCH

awk -v anchor="$HELPER_ANCHOR" -v helper="$HELPER_FILE" '
    { print }
    $0 == anchor {
        while ((getline line < helper) > 0)
            print line
        close(helper)
    }
' "$FILE_C" > "${FILE_C}.nm_tmp"
rm -f "$HELPER_FILE"

if [ "$(count_lines "${FILE_C}.nm_tmp" "$HELPER_MARK")" -ne 1 ]; then
    rm -f "${FILE_C}.nm_tmp"
    log "  ERROR: inserting the helper did not produce exactly one definition"
    exit 1
fi
mv "${FILE_C}.nm_tmp" "$FILE_C"
log "  Added nm_ensure_parent_dirs helper"

# --- Step 2: Call the helper from file_open() before the file is opened ---
log "Step 2: Patching file_open"

awk -v anchor="$CALL_ANCHOR" -v call="$CALL_MARK" '
    $0 == anchor {
        print "    if (flags & AVIO_FLAG_WRITE)"
        print call
    }
    { print }
' "$FILE_C" > "${FILE_C}.nm_tmp"

if [ "$(count_lines "${FILE_C}.nm_tmp" "$CALL_MARK")" -ne 1 ]; then
    rm -f "${FILE_C}.nm_tmp"
    log "  ERROR: inserting the call did not produce exactly one call"
    exit 1
fi
mv "${FILE_C}.nm_tmp" "$FILE_C"
log "  Patched file_open"

# --- Verify: the call sits inside file_open(), right before the open ---
if awk -v call="$CALL_MARK" -v anchor="$CALL_ANCHOR" '
    /^static int file_open\(URLContext \*h, const char \*filename, int flags\)$/ { in_func = 1; next }
    in_func && /^}/ { in_func = 0 }
    in_func && $0 == call { seen = 1; next }
    in_func && seen && $0 == anchor { ok = 1 }
    in_func && seen && $0 != anchor { seen = 0 }
    END { exit ok ? 0 : 1 }
' "$FILE_C"; then
    log "  Verified file_open patch"
else
    log "  ERROR: file_open patch verification failed!"
    exit 1
fi

exit 0
