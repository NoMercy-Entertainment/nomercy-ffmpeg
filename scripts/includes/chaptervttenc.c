/*
 * Chapter VTT muxer
 * Copyright (c) 2026 NoMercy Entertainment
 *
 * This file is part of FFmpeg.
 *
 * FFmpeg is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * FFmpeg is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with FFmpeg; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

/**
 * @file
 * Chapter VTT muxer
 *
 * Reads chapter metadata from the input container (MKV, MP4, etc.)
 * and writes a standard WebVTT chapter file.
 *
 *   ffmpeg -i input.mkv -f chapters_vtt chapters.vtt
 *
 * No stream mapping is required (AVFMT_NOSTREAMS).
 */

#include "avformat.h"
#include "internal.h"
#include "mux.h"
#include "libavutil/avstring.h"

/**
 * Format milliseconds into a WebVTT timestamp: HH:MM:SS.mmm
 */
static void format_vtt_time(char *buf, size_t buf_size, int64_t ms)
{
    int h  = (int)(ms / 3600000);
    int m  = (int)((ms % 3600000) / 60000);
    int s  = (int)((ms % 60000) / 1000);
    int ml = (int)(ms % 1000);
    snprintf(buf, buf_size, "%02d:%02d:%02d.%03d", h, m, s, ml);
}

/**
 * Write a chapter title as WebVTT cue text.
 *
 * Cue text is not plain text. "&" and "<" start a character reference and a
 * tag, so a title such as "Rock & Roll" or "A <B> C" produced a cue that a
 * conforming parser misreads or drops. Two sequences end the cue outright: a
 * blank line, and "-->", which a parser takes for the next timing line. The
 * title used to be printed verbatim, so all of these reached the file.
 *
 * Escaping ">" as well is what removes "-->": it becomes "--&gt;". Line
 * breaks become spaces, since a chapter title is one line and a break inside
 * the payload is exactly how a blank line gets in. Every other byte is copied
 * as is, so UTF-8 passes through untouched.
 */
static void write_vtt_cue_text(AVIOContext *pb, const char *text)
{
    const char *p;

    for (p = text; *p; p++) {
        switch (*p) {
        case '&':  avio_write(pb, (const uint8_t *)"&amp;", 5); break;
        case '<':  avio_write(pb, (const uint8_t *)"&lt;", 4);  break;
        case '>':  avio_write(pb, (const uint8_t *)"&gt;", 4);  break;
        case '\r':
        case '\n': avio_w8(pb, ' ');           break;
        default:   avio_w8(pb, *p);            break;
        }
    }
}

static int chapters_vtt_write_header(AVFormatContext *s)
{
    unsigned int i;

    avio_printf(s->pb, "WEBVTT\n\n");

    if (s->nb_chapters == 0) {
        av_log(s, AV_LOG_WARNING,
               "No chapters found in input — writing empty WebVTT file\n");
        return 0;
    }

    for (i = 0; i < s->nb_chapters; i++) {
        AVChapter *chapter = s->chapters[i];
        AVDictionaryEntry *title;
        char start_buf[32], end_buf[32];
        int64_t start_ms, end_ms;

        start_ms = av_rescale_q(chapter->start, chapter->time_base,
                                (AVRational){1, 1000});
        end_ms   = av_rescale_q(chapter->end,   chapter->time_base,
                                (AVRational){1, 1000});

        format_vtt_time(start_buf, sizeof(start_buf), start_ms);
        format_vtt_time(end_buf,   sizeof(end_buf),   end_ms);

        title = av_dict_get(chapter->metadata, "title", NULL, 0);

        if (title && title->value[0] != '\0') {
            avio_printf(s->pb, "%s --> %s\n", start_buf, end_buf);
            write_vtt_cue_text(s->pb, title->value);
            avio_printf(s->pb, "\n\n");
        } else
            avio_printf(s->pb, "%s --> %s\nChapter %u\n\n",
                        start_buf, end_buf, i + 1);
    }

    return 0;
}

static int chapters_vtt_write_packet(AVFormatContext *s, AVPacket *pkt)
{
    return 0;
}

static int chapters_vtt_write_trailer(AVFormatContext *s)
{
    avio_flush(s->pb);
    return 0;
}

const FFOutputFormat ff_chapters_vtt_muxer = {
    .p.name           = "chapters_vtt",
    .p.long_name      = NULL_IF_CONFIG_SMALL("WebVTT chapter file"),
    .p.extensions     = "vtt",
    .p.video_codec    = AV_CODEC_ID_NONE,
    .p.audio_codec    = AV_CODEC_ID_NONE,
    .p.subtitle_codec = AV_CODEC_ID_NONE,
    .p.flags          = AVFMT_NOSTREAMS | AVFMT_NOTIMESTAMPS,
    .write_header     = chapters_vtt_write_header,
    .write_packet     = chapters_vtt_write_packet,
    .write_trailer    = chapters_vtt_write_trailer,
};
