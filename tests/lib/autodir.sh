#!/bin/bash
# Auto-created output folders (#134, scripts/55-auto-create-dirs.sh). Every
# local file opened for writing gets its missing parent folders, whoever
# opens it: the ffmpeg tool (the main output of mp4, mov, webm, mkv, audio,
# spritevtt, chapters_vtt), a muxer (segment, tee, hls, image2), a muxer's
# side file (the spritevtt .vtt, the segment list), or a file outside the file
# protocol (two-pass log, -report, -vstats_file, filter stats files). Each
# check writes into
# its own missing nested folder. No assets: everything is generated.
#
# Each check asserts the written files, never ffmpeg's log: a log line
# naming the output is printed whether or not the file was written. That is
# how the old auto_mkdir check in tests.sh kept passing while the main output
# failed (#134).
#
# Exit codes follow run_custom_test: 0 pass, 1 fail, 2 skip with the reason
# on a line starting "SKIP: " (only when this build lacks an encoder or
# muxer the check needs).

# Every check, in the order smoke.sh runs them.
autodir_checks() {
    echo test_autodir_mp4 test_autodir_mov test_autodir_webm test_autodir_mkv \
        test_autodir_audio test_autodir_segment test_autodir_tee test_autodir_hls \
        test_autodir_image2 test_autodir_spritevtt test_autodir_chapters_vtt \
        test_autodir_file_prefix test_autodir_pipe test_autodir_input \
        test_autodir_passlog test_autodir_x264pass test_autodir_report \
        test_autodir_vstats test_autodir_filterstats test_autodir_readonly \
        test_autodir_x264stats test_autodir_x264dump test_autodir_x265pass \
        test_autodir_x265csv test_autodir_vmaf
}

# kind (encoders|muxers), name. The list is captured before matching: a
# `| grep -q` under pipefail reports a match as a failure (see the note in
# smoke.sh on the Metal check).
_autodir_has() {
    local list
    list=$("${FFMPEG}" -hide_banner "-$1" 2>/dev/null) || return 1
    [[ "${list}" == *" $2 "* ]]
}

# Files that must exist and be non-empty, relative to the work folder.
_autodir_expect() {
    local f missing=0
    for f in "$@"; do
        if [[ ! -s "${f}" ]]; then
            echo "not written: ${f}"
            missing=1
        fi
    done
    return ${missing}
}

_autodir_ffmpeg() {
    "${FFMPEG}" -hide_banner -loglevel error -y "$@"
    local rc=$?
    [[ ${rc} -eq 0 ]] || echo "ffmpeg exited ${rc}"
    return ${rc}
}

_autodir_run() (  # mode
    local mode="$1" work vc
    work=$(mktemp -d) || return 1
    trap 'rm -rf "${work}"' EXIT
    cd "${work}" || return 1
    # A binary that does not start is a failure. Without this, the encoder
    # probes below read it as "not in this build" (a skip), and the two
    # checks that expect ffmpeg to fail (input, readonly) pass.
    if ! "${FFMPEG}" -hide_banner -version >/dev/null 2>&1; then
        echo "ffmpeg does not run from ${work}: ${FFMPEG}"
        return 1
    fi
    # Absolute paths for most checks; tee and the file: check use relative
    # ones on purpose (see there).
    local d="${work}/nm-autodir"
    local video="testsrc=d=0.5:size=128x72:rate=10" audio="sine=d=0.5"
    case "${mode}" in
    mp4|mov)
        vc=mpeg4
        _autodir_has encoders libx264 && vc=libx264
        _autodir_ffmpeg -f lavfi -i "${video}" -f lavfi -i "${audio}" -c:v "${vc}" -c:a aac \
            "${d}/${mode}/a/b/o.${mode}" || return 1
        _autodir_expect "${d}/${mode}/a/b/o.${mode}" || return 1
        echo "${mode} (${vc} + aac) written into a folder that did not exist"
        ;;
    webm)
        local vp=""
        _autodir_has encoders libvpx && vp=libvpx
        _autodir_has encoders libvpx-vp9 && vp=libvpx-vp9
        if [[ -z "${vp}" ]]; then
            echo "SKIP: no VP8/VP9 encoder (libvpx) in this build"
            return 2
        fi
        if _autodir_has encoders libopus; then
            set -- -f lavfi -i "${audio}" -c:a libopus
        else
            set --
        fi
        _autodir_ffmpeg -f lavfi -i "${video}" "$@" -c:v "${vp}" "${d}/webm/a/b/o.webm" || return 1
        _autodir_expect "${d}/webm/a/b/o.webm" || return 1
        echo "webm (${vp}$([[ $# -gt 0 ]] && echo ' + libopus')) written into a folder that did not exist"
        ;;
    mkv)
        _autodir_ffmpeg -f lavfi -i "${video}" -f lavfi -i "${audio}" -c:v ffv1 -c:a flac \
            "${d}/mkv/a/b/o.mkv" || return 1
        _autodir_expect "${d}/mkv/a/b/o.mkv" || return 1
        echo "mkv (ffv1 + flac) written into a folder that did not exist"
        ;;
    audio)
        # Two outputs of one command, each into its own missing folder.
        _autodir_ffmpeg -f lavfi -i "${audio}" -c:a flac "${d}/flac/a/o.flac" \
            -c:a aac "${d}/m4a/a/o.m4a" || return 1
        _autodir_expect "${d}/flac/a/o.flac" "${d}/m4a/a/o.m4a" || return 1
        echo "flac and m4a written into folders that did not exist"
        ;;
    segment)
        _autodir_ffmpeg -f lavfi -i "${video}" -map 0:v -c:v ffv1 -f segment -segment_time 0.2 \
            -segment_format matroska -segment_list "${d}/segment/list/l.csv" \
            "${d}/segment/files/s_%03d.mkv" || return 1
        _autodir_expect "${d}/segment/files/s_000.mkv" "${d}/segment/list/l.csv" || return 1
        echo "segment files and segment list written into two folders that did not exist"
        ;;
    tee)
        # Relative: tee unescapes backslashes in its slave list, so a Windows
        # absolute path would not survive it. The cwd is the work folder.
        _autodir_ffmpeg -f lavfi -i "${video}" -map 0:v -c:v ffv1 -f tee \
            "[f=matroska]nm-autodir/tee/a/o.mkv|[f=matroska]nm-autodir/tee/b/o.mkv" || return 1
        _autodir_expect "${d}/tee/a/o.mkv" "${d}/tee/b/o.mkv" || return 1
        echo "tee wrote both outputs into two folders that did not exist"
        ;;
    hls)
        _autodir_ffmpeg -f lavfi -i "${video}" -c:v mpeg4 -g 2 -f hls -hls_time 0.2 -hls_list_size 0 \
            -hls_segment_filename "${d}/hls/seg/s_%03d.ts" "${d}/hls/pl/index.m3u8" || return 1
        _autodir_expect "${d}/hls/pl/index.m3u8" "${d}/hls/seg/s_000.ts" || return 1
        echo "hls playlist and segments written into two folders that did not exist"
        ;;
    image2)
        _autodir_ffmpeg -f lavfi -i "${video}" -frames:v 2 "${d}/img/x/f_%02d.png" || return 1
        _autodir_expect "${d}/img/x/f_01.png" "${d}/img/x/f_02.png" || return 1
        echo "image2 frames written into a folder that did not exist"
        ;;
    spritevtt)
        if ! _autodir_has muxers spritevtt; then
            echo "SKIP: no spritevtt muxer in this build"
            return 2
        fi
        _autodir_ffmpeg -f lavfi -i "${video}" -vf fps=2,scale=32:18 -f spritevtt \
            "${d}/sprite/x/sheet.png" || return 1
        _autodir_expect "${d}/sprite/x/sheet.png" "${d}/sprite/x/sheet.vtt" || return 1
        echo "spritevtt sheet and its .vtt written into a folder that did not exist"
        ;;
    chapters_vtt)
        if ! _autodir_has muxers chapters_vtt; then
            echo "SKIP: no chapters_vtt muxer in this build"
            return 2
        fi
        printf ';FFMETADATA1\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=500\ntitle=One\n' \
            > "${work}/chapters.txt"
        _autodir_ffmpeg -i "${work}/chapters.txt" -f chapters_vtt "${d}/chapters/x/chapters.vtt" || return 1
        _autodir_expect "${d}/chapters/x/chapters.vtt" || return 1
        echo "chapters_vtt written into a folder that did not exist"
        ;;
    file_prefix)
        # Relative on purpose: the old helper turned "file:nm-autodir/..."
        # into a folder literally named "file:nm-autodir" in the cwd.
        _autodir_ffmpeg -f lavfi -i "${video}" -c:v ffv1 "file:nm-autodir/file/c/o.mkv" || return 1
        _autodir_expect "${d}/file/c/o.mkv" || return 1
        if compgen -G "${work}/file:*" >/dev/null; then
            echo "a folder named after the file: prefix was created: $(echo file:*)"
            return 1
        fi
        echo "file: output written, no folder named file:* created"
        ;;
    pipe)
        _autodir_ffmpeg -f lavfi -i "${video}" -c:v ffv1 -f matroska pipe:1 > "${work}/pipe.out" || return 1
        _autodir_expect "${work}/pipe.out" || return 1
        if [[ "$(ls -A "${work}")" != pipe.out ]]; then
            echo "pipe:1 left something besides its own output: $(ls -A "${work}" | tr '\n' ' ')"
            return 1
        fi
        echo "pipe:1 output written to stdout, no folder created"
        ;;
    input)
        if "${FFMPEG}" -hide_banner -loglevel error -i "${d}/in/x/missing.mkv" -f null - 2>/dev/null; then
            echo "reading a missing input succeeded"
            return 1
        fi
        if [[ -e "${d}" ]]; then
            echo "reading a missing input created ${d}"
            return 1
        fi
        echo "a missing input fails and creates no folder"
        ;;
    passlog)
        # fftools opens the two-pass log itself (native encoder, no x264).
        _autodir_ffmpeg -f lavfi -i "${video}" -c:v mpeg4 -pass 1 \
            -passlogfile "${d}/pass/a/b/log" -f null - || return 1
        _autodir_expect "${d}/pass/a/b/log-0.log" || return 1
        echo "two-pass log (mpeg4) written into a folder that did not exist"
        ;;
    x264pass)
        if ! _autodir_has encoders libx264; then
            echo "SKIP: no libx264 encoder in this build"
            return 2
        fi
        # x264 writes log-0.log.temp and renames it: assert the final name.
        _autodir_ffmpeg -f lavfi -i "${video}" -c:v libx264 -pass 1 \
            -passlogfile "${d}/x264pass/a/log" -f null - || return 1
        _autodir_expect "${d}/x264pass/a/log-0.log" || return 1
        echo "two-pass log (libx264) written into a folder that did not exist"
        ;;
    report)
        # Relative: FFREPORT splits its value at ":", which a Windows drive
        # letter would break. The variable is set for this one call only.
        FFREPORT="file=nm-autodir/report/a/r.log" _autodir_ffmpeg -f lavfi -i "${video}" \
            -c:v mpeg4 -f null - || return 1
        _autodir_expect "${d}/report/a/r.log" || return 1
        echo "-report file written into a folder that did not exist"
        ;;
    vstats)
        _autodir_ffmpeg -f lavfi -i "${video}" -c:v mpeg4 \
            -vstats_file "${d}/vstats/a/v.log" -f null - || return 1
        _autodir_expect "${d}/vstats/a/v.log" || return 1
        echo "-vstats_file written into a folder that did not exist"
        ;;
    filterstats)
        # Relative: a Windows drive letter would need escaping in a filter
        # argument. psnr is a video filter, loudnorm an audio one.
        _autodir_ffmpeg -f lavfi -i "${video}" -f lavfi -i "${video}" -f lavfi -i "${audio}" \
            -filter_complex "[0:v][1:v]psnr=stats_file=nm-autodir/fstats/v/psnr.log[v];[2:a]loudnorm=print_format=summary:stats_file=nm-autodir/fstats/a/ln.log[a]" \
            -map "[v]" -map "[a]" -f null - || return 1
        _autodir_expect "${d}/fstats/v/psnr.log" "${d}/fstats/a/ln.log" || return 1
        echo "psnr and loudnorm stats files written into folders that did not exist"
        ;;
    x264stats)
        if ! _autodir_has encoders libx264; then
            echo "SKIP: no libx264 encoder in this build"
            return 2
        fi
        # x264's own stats file. The global -stats flag swallows a -stats
        # option, so it goes through -x264-params, relative because the
        # params are :-separated and a Windows drive letter would split.
        _autodir_ffmpeg -f lavfi -i "${video}" -c:v libx264 \
            -x264-params "pass=1:stats=nm-autodir/x264stats/a/s.log" -f null - || return 1
        _autodir_expect "${d}/x264stats/a/s.log" || return 1
        echo "x264 stats file written into a folder that did not exist"
        ;;
    x264dump)
        if ! _autodir_has encoders libx264; then
            echo "SKIP: no libx264 encoder in this build"
            return 2
        fi
        _autodir_ffmpeg -f lavfi -i "${video}" -c:v libx264 \
            -x264-params "dump-yuv=nm-autodir/x264dump/a/r.yuv" -f null - || return 1
        _autodir_expect "${d}/x264dump/a/r.yuv" || return 1
        echo "x264 dump-yuv file written into a folder that did not exist"
        ;;
    x265pass)
        if ! _autodir_has encoders libx265; then
            echo "SKIP: no libx265 encoder in this build"
            return 2
        fi
        _autodir_ffmpeg -f lavfi -i "${video}" -c:v libx265 -pass 1 \
            -passlogfile "${d}/x265pass/a/log" -f null - || return 1
        _autodir_expect "${d}/x265pass/a/log-0.log" || return 1
        echo "two-pass log (libx265) written into a folder that did not exist"
        ;;
    x265csv)
        if ! _autodir_has encoders libx265; then
            echo "SKIP: no libx265 encoder in this build"
            return 2
        fi
        _autodir_ffmpeg -f lavfi -i "${video}" -c:v libx265 \
            -x265-params "csv=nm-autodir/x265csv/a/c.csv" -f null - || return 1
        _autodir_expect "${d}/x265csv/a/c.csv" || return 1
        echo "x265 csv file written into a folder that did not exist"
        ;;
    vmaf)
        if ! _autodir_has filters libvmaf; then
            echo "SKIP: no libvmaf filter in this build"
            return 2
        fi
        # model= (empty) and one feature: no model file is needed, so the
        # check does not depend on the built-in models being shipped.
        _autodir_ffmpeg -f lavfi -i "${video}" \
            -lavfi "split[a][b];[a][b]libvmaf=model=:feature=name=psnr:log_path=nm-autodir/vmaf/a/v.json:log_fmt=json" \
            -f null - || return 1
        _autodir_expect "${d}/vmaf/a/v.json" || return 1
        echo "libvmaf log written into a folder that did not exist"
        ;;
    readonly)
        # A read-only open must create nothing: lut3d only reads its file.
        if "${FFMPEG}" -hide_banner -loglevel error -f lavfi -i "${video}" \
            -vf "lut3d=file=nm-autodir/lut/a/x.cube" -f null - 2>/dev/null; then
            echo "lut3d on a missing file succeeded"
            return 1
        fi
        if [[ -e "${d}" ]]; then
            echo "reading a missing filter file created ${d}"
            return 1
        fi
        echo "a missing filter file fails and creates no folder"
        ;;
    *)
        echo "unknown autodir mode ${mode}"
        return 1
        ;;
    esac
)

test_autodir_mp4() { _autodir_run mp4; }
test_autodir_mov() { _autodir_run mov; }
test_autodir_webm() { _autodir_run webm; }
test_autodir_mkv() { _autodir_run mkv; }
test_autodir_audio() { _autodir_run audio; }
test_autodir_segment() { _autodir_run segment; }
test_autodir_tee() { _autodir_run tee; }
test_autodir_hls() { _autodir_run hls; }
test_autodir_image2() { _autodir_run image2; }
test_autodir_spritevtt() { _autodir_run spritevtt; }
test_autodir_chapters_vtt() { _autodir_run chapters_vtt; }
test_autodir_file_prefix() { _autodir_run file_prefix; }
test_autodir_pipe() { _autodir_run pipe; }
test_autodir_input() { _autodir_run input; }
test_autodir_passlog() { _autodir_run passlog; }
test_autodir_x264pass() { _autodir_run x264pass; }
test_autodir_report() { _autodir_run report; }
test_autodir_vstats() { _autodir_run vstats; }
test_autodir_filterstats() { _autodir_run filterstats; }
test_autodir_readonly() { _autodir_run readonly; }
test_autodir_x264stats() { _autodir_run x264stats; }
test_autodir_x264dump() { _autodir_run x264dump; }
test_autodir_x265pass() { _autodir_run x265pass; }
test_autodir_x265csv() { _autodir_run x265csv; }
test_autodir_vmaf() { _autodir_run vmaf; }
