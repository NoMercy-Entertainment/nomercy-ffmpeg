/*
 * VOBsub subtitle muxer
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
 * VOBsub subtitle muxer
 * @see https://wiki.multimedia.cx/index.php/VOBsub
 *
 * Produces an .idx + .sub pair. Accepts either extension as output:
 *
 *   ffmpeg -i in.mkv -map 0:s:0 -c:s copy out.idx   (auto-detected)
 *   ffmpeg -i in.mkv -map 0:s:0 -c:s copy out.sub   (needs -f vobsub)
 *
 * The .idx (text index) is the primary output written to s->pb.
 * The .sub (MPEG-2 PS data) is the companion opened separately.
 * When the user specifies .sub, the roles are swapped internally.
 */

#include "avformat.h"
#include "internal.h"
#include "mux.h"
#include "mpeg.h"
#include "libavutil/avstring.h"
#include "libavutil/intreadwrite.h"
#include "libavutil/mem.h"

#define VOBSUB_MUX_RATE 10080 /* DVD standard: 10080 units * 50 bytes = 504 KB/s */

typedef struct VOBSubMuxContext {
    AVIOContext *companion_pb;  /* companion file (.sub or .idx) */
    AVIOContext *idx_pb;        /* points to whichever pb is the .idx */
    AVIOContext *sub_pb;        /* points to whichever pb is the .sub */
} VOBSubMuxContext;

/**
 * Write a 5-byte MPEG-2 PES timestamp.
 */
static void vobsub_put_pts(AVIOContext *pb, int id, int64_t pts)
{
    avio_w8(pb,  (id << 4) | ((pts >> 29) & 0x0E) | 0x01);
    avio_wb16(pb, (uint16_t)((((pts >> 15) & 0x7FFF) << 1) | 1));
    avio_wb16(pb, (uint16_t)((((pts      ) & 0x7FFF) << 1) | 1));
}

/**
 * Write an MPEG-2 PS Pack Header (14 bytes).
 */
static void vobsub_write_pack(AVIOContext *pb, int64_t scr)
{
    avio_wb32(pb, PACK_START_CODE);

    avio_w8(pb, 0x44 | (uint8_t)((scr >> 27) & 0x38) |
                        (uint8_t)((scr >> 28) & 0x03));
    avio_w8(pb, (uint8_t)((scr >> 20) & 0xFF));
    avio_w8(pb, 0x04 | (uint8_t)((scr >> 12) & 0xF8) |
                        (uint8_t)((scr >> 13) & 0x03));
    avio_w8(pb, (uint8_t)((scr >> 5) & 0xFF));
    avio_w8(pb, 0x04 | (uint8_t)((scr << 3) & 0xF8));
    avio_w8(pb, 0x01);

    avio_w8(pb, (VOBSUB_MUX_RATE >> 14) & 0xFF);
    avio_w8(pb, (VOBSUB_MUX_RATE >>  6) & 0xFF);
    avio_w8(pb, ((VOBSUB_MUX_RATE << 2) & 0xFC) | 0x03);
    avio_w8(pb, 0xF8);
}

static av_cold int vobsub_init(AVFormatContext *s)
{
    avpriv_set_pts_info(s->streams[0], 32, 1, 90000);
    return 0;
}

static av_cold int vobsub_write_header(AVFormatContext *s)
{
    VOBSubMuxContext *vs = s->priv_data;
    AVStream *st = s->streams[0];
    AVDictionaryEntry *lang;
    char *companion_filename;
    const char *ext;
    size_t len;
    int ret, primary_is_sub;

    /* Figure out whether the user gave us .idx or .sub */
    len = strlen(s->url);
    if (len < 4) {
        av_log(s, AV_LOG_ERROR, "Output filename must have .idx or .sub extension\n");
        return AVERROR(EINVAL);
    }
    ext = s->url + len - 4;

    if (!av_strcasecmp(ext, ".idx"))
        primary_is_sub = 0;
    else if (!av_strcasecmp(ext, ".sub"))
        primary_is_sub = 1;
    else {
        av_log(s, AV_LOG_ERROR, "Output filename must have .idx or .sub extension\n");
        return AVERROR(EINVAL);
    }

    /* Open the companion file (the other half of the pair) */
    companion_filename = av_strdup(s->url);
    if (!companion_filename)
        return AVERROR(ENOMEM);
    memcpy(companion_filename + len - 3, primary_is_sub ? "idx" : "sub", 3);

    ret = avio_open(&vs->companion_pb, companion_filename, AVIO_FLAG_WRITE);
    av_free(companion_filename);
    if (ret < 0) {
        av_log(s, AV_LOG_ERROR, "Failed to open companion .%s file\n",
               primary_is_sub ? "idx" : "sub");
        return ret;
    }

    /* Assign idx/sub pointers based on which file is primary */
    if (primary_is_sub) {
        vs->sub_pb = s->pb;
        vs->idx_pb = vs->companion_pb;
    } else {
        vs->idx_pb = s->pb;
        vs->sub_pb = vs->companion_pb;
    }

    /* Write .idx preamble */
    avio_printf(vs->idx_pb,
                "# VobSub index file, v7 (do not modify this line!)\n");

    if (st->codecpar->extradata_size > 0) {
        avio_write(vs->idx_pb, st->codecpar->extradata,
                   st->codecpar->extradata_size);
        if (st->codecpar->extradata[st->codecpar->extradata_size - 1] != '\n')
            avio_w8(vs->idx_pb, '\n');
    } else {
        int w = st->codecpar->width  ? st->codecpar->width  : 720;
        int h = st->codecpar->height ? st->codecpar->height : 480;
        avio_printf(vs->idx_pb, "size: %dx%d\n", w, h);
    }

    avio_printf(vs->idx_pb, "langidx: 0\n");

    lang = av_dict_get(st->metadata, "language", NULL, 0);
    avio_printf(vs->idx_pb, "id: %s, index: 0\n",
                (lang && lang->value) ? lang->value : "und");

    return 0;
}

static int vobsub_write_packet(AVFormatContext *s, AVPacket *pkt)
{
    VOBSubMuxContext *vs = s->priv_data;
    int64_t pts, filepos, ts_ms;
    int pes_size, hh, mm, ss, ms;

    if (!pkt->data || pkt->size <= 0)
        return 0;

    pts = pkt->pts;
    if (pts == AV_NOPTS_VALUE)
        pts = 0;

    pes_size = 9 + pkt->size;
    if (pes_size > 0xFFFF) {
        av_log(s, AV_LOG_ERROR,
               "Subtitle packet too large for single PES (%d bytes)\n",
               pkt->size);
        return AVERROR(EINVAL);
    }

    /* Record .sub position before writing (for .idx filepos) */
    filepos = avio_tell(vs->sub_pb);

    /* --- .sub: MPEG-2 PS Pack + PES --- */
    vobsub_write_pack(vs->sub_pb, pts);

    avio_wb32(vs->sub_pb, PRIVATE_STREAM_1);
    avio_wb16(vs->sub_pb, pes_size);
    avio_w8(vs->sub_pb,   0x81);
    avio_w8(vs->sub_pb,   0x80);
    avio_w8(vs->sub_pb,   0x05);
    vobsub_put_pts(vs->sub_pb, 2, pts);
    avio_w8(vs->sub_pb,   SUB_ID);
    avio_write(vs->sub_pb, pkt->data, pkt->size);

    /* --- .idx: timestamp entry --- */
    ts_ms = av_rescale(pts, 1000, 90000);
    hh = (int)(ts_ms / 3600000);
    mm = (int)((ts_ms % 3600000) / 60000);
    ss = (int)((ts_ms % 60000) / 1000);
    ms = (int)(ts_ms % 1000);

    avio_printf(vs->idx_pb,
                "timestamp: %02d:%02d:%02d:%03d, filepos: %09"PRIx64"\n",
                hh, mm, ss, ms, filepos);

    return 0;
}

static av_cold int vobsub_write_trailer(AVFormatContext *s)
{
    VOBSubMuxContext *vs = s->priv_data;

    if (vs->companion_pb) {
        avio_flush(vs->companion_pb);
        avio_closep(&vs->companion_pb);
    }
    vs->idx_pb = NULL;
    vs->sub_pb = NULL;
    return 0;
}

static void vobsub_deinit(AVFormatContext *s)
{
    VOBSubMuxContext *vs = s->priv_data;
    avio_closep(&vs->companion_pb);
    vs->idx_pb = NULL;
    vs->sub_pb = NULL;
}

const FFOutputFormat ff_vobsub_muxer = {
    .p.name           = "vobsub",
    .p.long_name      = NULL_IF_CONFIG_SMALL("VobSub subtitle format"),
    .p.extensions     = "idx,sub",
    .p.mime_type      = "application/x-vobsub",
    .p.video_codec    = AV_CODEC_ID_NONE,
    .p.audio_codec    = AV_CODEC_ID_NONE,
    .p.subtitle_codec = AV_CODEC_ID_DVD_SUBTITLE,
    .p.flags          = AVFMT_VARIABLE_FPS | AVFMT_TS_NONSTRICT,
    .flags_internal   = FF_OFMT_FLAG_MAX_ONE_OF_EACH,
    .priv_data_size   = sizeof(VOBSubMuxContext),
    .init             = vobsub_init,
    .write_header     = vobsub_write_header,
    .write_packet     = vobsub_write_packet,
    .write_trailer    = vobsub_write_trailer,
    .deinit           = vobsub_deinit,
};
