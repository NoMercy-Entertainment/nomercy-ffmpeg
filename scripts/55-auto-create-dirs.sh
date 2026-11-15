#!/bin/bash

#/**************************************/#
#/*  NoMercy Entertainment — Auto      */#
#/*  create output directories         */#
#/**************************************/#

# Create the missing parent folders of any local file FFmpeg writes, so an
# output can go into a folder that does not exist yet (issue #134).
#
# One helper, nm_ensure_parent_dirs(), lives in a new header
# libavutil/nm_mkdirs.h and is called right before each place that creates a
# local file:
#   1. file_open() in libavformat/file.c: the open callback of the "file"
#      protocol. Every write through the protocol reaches it: the ffmpeg
#      tool's main output (avio_open2 -> ffio_open_whitelist ->
#      ffurl_open_whitelist -> file_open), the files a muxer opens itself
#      (image2, hls, dash, segment, spritevtt, tee), and direct
#      ffurl_open_whitelist callers. pipe:, http:// and every other protocol
#      never get here, and file_open() strips a leading "file:" before the
#      hook runs, so "file:out/o.mp4" creates "out", not "file:out".
#   2. avpriv_fopen_utf8() in libavutil/file_open.c, for "w" and "a": the
#      stats files of filters (psnr, ssim, xpsnr, ssim360, vmafmotion,
#      loudnorm, signature, deshake, vidstabdetect, paletteuse, curves,
#      firequalizer).
#   3. fopen_utf8() in fftools/fopen_utf8.h, for "w" and "a": the two-pass
#      log of native encoders and the -report file.
#   4. the -vstats_file fopen() in fftools/ffmpeg_enc.c.
#   5. the pass-1 log name in fftools/ffmpeg_mux_init.c, before it is handed
#      to libx264, libx265 or libvvenc, which write that file themselves.
#   6. libx264.c and libx265.c, right before the encoder opens: the files the
#      encoder library writes itself (x264: stats, dump-yuv, opencl-clbin;
#      x265: stats, csv, analysis-save), however they were set.
#   7. the log_path of vf_libvmaf.c, which libvmaf writes itself.
# Files opened for reading never create a folder. SVT-AV1 needs no hook: the
# library writes no file on a path given to it (stat-file is a setting of
# the SVT command-line tool only).
#
# Best effort: a failed mkdir never fails the open, and errno is left as it
# was, so the open that follows reports the real error. On Windows the
# helper converts the UTF-8 path with get_extended_win32_path() (long paths
# included) and calls _wmkdir, like os_support.h does for libavformat; on
# Linux, darwin and FreeBSD it uses the POSIX mkdir() and stat().
#
# Patched by text match only. Each anchor must match exactly once, and every
# anchor is checked before anything is written: line-number patches silently
# patch the wrong place when the FFmpeg source moves.

FF="/build/ffmpeg"
HEADER="$FF/libavutil/nm_mkdirs.h"
OPTIONS_FILE="$FF/libavformat/options.c"
TAG='/* NoMercy #134 */'

# Count whole lines that equal the given text exactly.
count_lines() {  # file, text
    grep -cxF -- "$2" "$1"
}

# --- The patches -------------------------------------------------------------
# One per entry: file | before/after | anchor | the lines to insert (\n
# separated). The last inserted line carries ${TAG} and is the patch's mark.
P_FILE=() P_WHERE=() P_ANCHOR=() P_TEXT=()
add_patch() {  # file, where, anchor, text
    P_FILE+=("$1") P_WHERE+=("$2") P_ANCHOR+=("$3") P_TEXT+=("$4")
}
add_patch "$FF/libavformat/file.c" after '#include "url.h"' \
"#include \"libavutil/nm_mkdirs.h\" ${TAG}"
add_patch "$FF/libavformat/file.c" before '    fd = avpriv_open(filename, access, 0666);' \
"    if (flags & AVIO_FLAG_WRITE)
        nm_ensure_parent_dirs(filename); ${TAG}"
add_patch "$FF/libavutil/file_open.c" after '#include "file_open.h"' \
"#include \"nm_mkdirs.h\" ${TAG}"
add_patch "$FF/libavutil/file_open.c" before '    fd = avpriv_open(path, access, 0666);' \
"    if (access & O_CREAT)
        nm_ensure_parent_dirs(path); ${TAG}"
add_patch "$FF/fftools/fopen_utf8.h" after '#include <stdio.h>' \
"#include \"libavutil/nm_mkdirs.h\" ${TAG}"
add_patch "$FF/fftools/fopen_utf8.h" before '    if (get_extended_win32_path(path_utf8, &path_w)) /* This sets errno on error. */' \
"    if (mode[0] == 'w' || mode[0] == 'a')
        nm_ensure_parent_dirs(path_utf8); ${TAG}"
add_patch "$FF/fftools/fopen_utf8.h" before '    return fopen(path, mode);' \
"    if (mode[0] == 'w' || mode[0] == 'a')
        nm_ensure_parent_dirs(path); ${TAG}"
add_patch "$FF/fftools/ffmpeg_enc.c" after '#include "libavutil/mem.h"' \
"#include \"libavutil/nm_mkdirs.h\" ${TAG}"
add_patch "$FF/fftools/ffmpeg_enc.c" before '        vstats_file = fopen(vstats_filename, "w");' \
"        nm_ensure_parent_dirs(vstats_filename); ${TAG}"
add_patch "$FF/fftools/ffmpeg_mux_init.c" before '            if (!strcmp(video_enc->codec->name, "libx264") || !strcmp(video_enc->codec->name, "libvvenc")) {' \
"            if (video_enc->flags & AV_CODEC_FLAG_PASS1)
                nm_ensure_parent_dirs(logfilename); ${TAG}"
# The encoder libraries write these files themselves. The hook sits right
# before the encoder opens, on the final settings, so it covers every way to
# set them: -stats, -x264opts, -x264-params, -x265-params, -passlogfile.
add_patch "$FF/libavcodec/libx264.c" after '#include "libavutil/mem.h"' \
"#include \"libavutil/nm_mkdirs.h\" ${TAG}"
add_patch "$FF/libavcodec/libx264.c" before '    x4->enc = x264_encoder_open(&x4->params);' \
"    if (x4->params.rc.b_stat_write)
        nm_ensure_parent_dirs(x4->params.rc.psz_stat_out);
    nm_ensure_parent_dirs(x4->params.psz_dump_yuv);
    nm_ensure_parent_dirs(x4->params.psz_clbin_file); ${TAG}"
add_patch "$FF/libavcodec/libx265.c" after '#include "libavutil/mem.h"' \
"#include \"libavutil/nm_mkdirs.h\" ${TAG}"
add_patch "$FF/libavcodec/libx265.c" before '    ctx->encoder = ctx->api->encoder_open(ctx->params);' \
"    if (ctx->params->rc.bStatWrite)
        nm_ensure_parent_dirs(ctx->params->rc.statFileName);
    nm_ensure_parent_dirs(ctx->params->csvfn);
    nm_ensure_parent_dirs(ctx->params->analysisSave); ${TAG}"
# libvmaf writes log_path itself. The write is the brace-less body of an if,
# so the hook goes before that if, under the same condition.
add_patch "$FF/libavfilter/vf_libvmaf.c" after '#include "libavutil/mem.h"' \
"#include \"libavutil/nm_mkdirs.h\" ${TAG}"
add_patch "$FF/libavfilter/vf_libvmaf.c" before '        if (s->log_path && !err)' \
"        if (s->log_path && !err)
            nm_ensure_parent_dirs(s->log_path); ${TAG}"

mark_of() {  # index -> the last inserted line
    printf '%s\n' "${P_TEXT[$1]}" | tail -n 1
}

# --- The helper header ---------------------------------------------------------
HEADER_TMP=$(mktemp)
cat > "$HEADER_TMP" << 'NMHEADER'
/*
 * NoMercy: create the missing parent folders of a local file that is about
 * to be written (issue #134). Header only, so every library and fftools get
 * their own static copy and no symbol crosses a library boundary.
 */

#ifndef AVUTIL_NM_MKDIRS_H
#define AVUTIL_NM_MKDIRS_H

#include <errno.h>
#include "attributes.h"
#include "mem.h"

#ifdef _WIN32
#include <direct.h>
#include <windows.h>
#include "wchar_filename.h"
#  define NM_IS_DIR_SEP(c) ((c) == '/' || (c) == '\\')
#else
#include <sys/types.h>
#include <sys/stat.h>
#  define NM_IS_DIR_SEP(c) ((c) == '/')
#endif

static av_unused int nm_is_dir(const char *dir)
{
#ifdef _WIN32
    wchar_t *dir_w = NULL;
    DWORD attr;
    if (get_extended_win32_path(dir, &dir_w))
        return 0;
    attr = dir_w ? GetFileAttributesW(dir_w) : GetFileAttributesA(dir);
    av_free(dir_w);
    return attr != INVALID_FILE_ATTRIBUTES && (attr & FILE_ATTRIBUTE_DIRECTORY);
#else
    struct stat st;
    return !stat(dir, &st) && S_ISDIR(st.st_mode);
#endif
}

static av_unused void nm_make_dir(const char *dir)
{
#ifdef _WIN32
    wchar_t *dir_w = NULL;
    if (get_extended_win32_path(dir, &dir_w))
        return;
    if (dir_w)
        (void)_wmkdir(dir_w);
    else
        (void)_mkdir(dir);  /* the path may be in the ANSI code page */
    av_free(dir_w);
#else
    (void)mkdir(dir, 0755);
#endif
}

/**
 * Create the missing parent folders of path. Best effort: every failure is
 * ignored and errno is left as it was, so the open that follows reports the
 * real error.
 */
static av_unused void nm_ensure_parent_dirs(const char *path)
{
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
    if (!dir) {
        errno = saved_errno;  /* a failed allocation may have set ENOMEM */
        return;
    }

    /* The common case: the folder is already there. */
    if (nm_is_dir(dir))
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
            nm_make_dir(dir);
            *p = saved;
        }
    }
    nm_make_dir(dir);

done:
    av_free(dir);
    errno = saved_errno;
}

#endif /* AVUTIL_NM_MKDIRS_H */
NMHEADER

# --- Step 0: refuse a tree patched by an older version of this script ---------
# The first hook (io_open_default in options.c) turned "file:out/o.mp4" into a
# folder named "file:out"; the second kept its own copy of the helper inside
# file.c. A fresh FFmpeg tree has neither.
log "Step 0: Checking for older versions of this patch"
if [ -f "$OPTIONS_FILE" ] && grep -q "ff_ensure_dir_exists" "$OPTIONS_FILE"; then
    rm -f "$HEADER_TMP"
    log "  ERROR: $OPTIONS_FILE still carries the old ff_ensure_dir_exists hook; start from a clean FFmpeg tree"
    exit 1
fi
if grep -q "^static .*void nm_ensure_parent_dirs" "$FF/libavformat/file.c" 2>/dev/null; then
    rm -f "$HEADER_TMP"
    log "  ERROR: file.c carries the helper of the previous version of this patch; start from a clean FFmpeg tree"
    exit 1
fi
log "  No older patch found"

# --- Step 1: decide: fresh, already patched, or partly patched ---------------
marks=0
for i in "${!P_FILE[@]}"; do
    f="${P_FILE[$i]}"
    if [ ! -f "$f" ]; then
        rm -f "$HEADER_TMP"
        log "  ERROR: $f not found"
        exit 1
    fi
    n=$(count_lines "$f" "$(mark_of "$i")")
    if [ "$n" -gt 1 ]; then
        rm -f "$HEADER_TMP"
        log "  ERROR: $(basename "$f") has the line '$(mark_of "$i")' ${n} times; start from a clean FFmpeg tree"
        exit 1
    fi
    marks=$((marks + n))
done
header_ok=0
[ -f "$HEADER" ] && cmp -s "$HEADER" "$HEADER_TMP" && header_ok=1

if [ "$marks" -eq "${#P_FILE[@]}" ] && [ "$header_ok" -eq 1 ]; then
    rm -f "$HEADER_TMP"
    log "  Already patched (${marks} hooks and the header)"
    exit 0
fi
if [ "$marks" -ne 0 ] || [ -f "$HEADER" ]; then
    rm -f "$HEADER_TMP"
    log "  ERROR: the tree is partly patched (${marks} of ${#P_FILE[@]} hooks, header present: $([ -f "$HEADER" ] && echo yes || echo no)); start from a clean FFmpeg tree"
    exit 1
fi

# Every anchor is checked before anything is written, so a moved anchor
# fails the step with the tree left exactly as it was.
for i in "${!P_FILE[@]}"; do
    n=$(count_lines "${P_FILE[$i]}" "${P_ANCHOR[$i]}")
    if [ "$n" -ne 1 ]; then
        rm -f "$HEADER_TMP"
        log "  ERROR: expected exactly 1 line '${P_ANCHOR[$i]}' in $(basename "${P_FILE[$i]}"), found ${n}"
        exit 1
    fi
done

# --- Step 2: write the header and insert the hooks ---------------------------
log "Step 2: Writing libavutil/nm_mkdirs.h"
mv "$HEADER_TMP" "$HEADER"

for i in "${!P_FILE[@]}"; do
    f="${P_FILE[$i]}"
    text_file=$(mktemp)
    printf '%s\n' "${P_TEXT[$i]}" > "$text_file"
    awk -v anchor="${P_ANCHOR[$i]}" -v where="${P_WHERE[$i]}" -v text="$text_file" '
        function emit(   line) {
            while ((getline line < text) > 0)
                print line
            close(text)
        }
        $0 == anchor && where == "before" { emit() }
        { print }
        $0 == anchor && where == "after" { emit() }
    ' "$f" > "${f}.nm_tmp"
    rm -f "$text_file"
    mv "${f}.nm_tmp" "$f"
    log "  Patched $(basename "$f") ${P_WHERE[$i]} '${P_ANCHOR[$i]}'"
done

# --- Verify: every mark exactly once, right next to its anchor ---------------
for i in "${!P_FILE[@]}"; do
    f="${P_FILE[$i]}"
    mark=$(mark_of "$i")
    if [ "$(count_lines "$f" "$mark")" -ne 1 ]; then
        log "  ERROR: $(basename "$f") does not have '${mark}' exactly once after patching"
        exit 1
    fi
    if ! awk -v anchor="${P_ANCHOR[$i]}" -v mark="$mark" -v where="${P_WHERE[$i]}" '
        { line[NR] = $0 }
        END {
            for (n = 1; n <= NR; n++)
                if (line[n] == mark)
                    exit !((where == "before" && line[n + 1] == anchor) ||
                           (where == "after"  && line[n - 1] == anchor))
            exit 1
        }
    ' "$f"; then
        log "  ERROR: in $(basename "$f") the hook '${mark}' is not right ${P_WHERE[$i]} its anchor"
        exit 1
    fi
done
log "  Verified ${#P_FILE[@]} hooks and the header"
