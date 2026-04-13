/*
 * OCR subtitle encoder using Tesseract
 * Converts bitmap subtitles (DVD/Blu-ray) to text for WebVTT/SRT output
 *
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

#include "avcodec.h"
#include "codec_internal.h"
#include "libavutil/mem.h"
#include "libavutil/opt.h"

#include <tesseract/capi.h>

typedef struct OCRSubtitleContext {
    AVClass *class;
    TessBaseAPI *tess;
    char *language;
    char *datapath;
    int fixups;
    int scale;
} OCRSubtitleContext;

static av_cold int ocr_subtitle_init(AVCodecContext *avctx)
{
    OCRSubtitleContext *ctx = avctx->priv_data;
    const char *lang = ctx->language && ctx->language[0] ? ctx->language : "eng";

    ctx->tess = TessBaseAPICreate();
    if (!ctx->tess) {
        av_log(avctx, AV_LOG_ERROR, "Failed to create Tesseract instance\n");
        return AVERROR(ENOMEM);
    }

    if (TessBaseAPIInit3(ctx->tess, ctx->datapath, lang) == -1) {
        av_log(avctx, AV_LOG_ERROR,
               "Tesseract init failed for language '%s'. "
               "Ensure '%s.traineddata' exists in the path specified by "
               "TESSDATA_PREFIX or -datapath.\n",
               lang, lang);
        TessBaseAPIDelete(ctx->tess);
        ctx->tess = NULL;
        return AVERROR_EXTERNAL;
    }

    TessBaseAPISetPageSegMode(ctx->tess, PSM_SINGLE_BLOCK);

    av_log(avctx, AV_LOG_INFO,
           "OCR subtitle encoder initialized (language: %s)\n", lang);

    return 0;
}

/**
 * Convert a palette-indexed bitmap to grayscale for Tesseract OCR.
 *
 * DVD/PGS subtitles typically have bright text (white/yellow) with a dark
 * outline on a transparent background. Using luminance weighted by alpha
 * composites against black and then inverts, which:
 *   - bright opaque text  → dark (Tesseract foreground)
 *   - dark opaque outline → light (merges with background)
 *   - transparent bg      → white (Tesseract background)
 *
 * Palette layout on little-endian (uint32_t 0xAARRGGBB):
 *   byte[0]=B, byte[1]=G, byte[2]=R, byte[3]=A
 */
static void bitmap_to_grayscale(const uint8_t *palette, const uint8_t *src,
                                uint8_t *dst, int w, int h, int linesize,
                                int scale)
{
    int ow = w * scale;

    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            uint8_t idx = src[y * linesize + x];
            uint8_t b = palette[idx * 4];
            uint8_t g = palette[idx * 4 + 1];
            uint8_t r = palette[idx * 4 + 2];
            uint8_t a = palette[idx * 4 + 3];
            int lum  = (54 * r + 183 * g + 19 * b) >> 8;
            uint8_t val = 255 - (uint8_t)((lum * a + 127) / 255);

            for (int sy = 0; sy < scale; sy++)
                for (int sx = 0; sx < scale; sx++)
                    dst[(y * scale + sy) * ow + x * scale + sx] = val;
        }
    }
}

/**
 * Run Tesseract OCR on a single bitmap subtitle rect.
 *
 * Returns 0 on success. On success, *out_text is set to the OCR result
 * (caller must free with TessDeleteText) or NULL if no text was recognized.
 */
static int ocr_bitmap_rect(AVCodecContext *avctx, const AVSubtitleRect *rect,
                           char **out_text)
{
    OCRSubtitleContext *ctx = avctx->priv_data;
    int scale = ctx->scale;
    int sw = rect->w * scale;
    int sh = rect->h * scale;
    uint8_t *gray;
    char *text;

    *out_text = NULL;

    if (rect->w <= 0 || rect->h <= 0 || !rect->data[0] || !rect->data[1])
        return 0;

    gray = av_malloc(sw * sh);
    if (!gray)
        return AVERROR(ENOMEM);

    bitmap_to_grayscale(rect->data[1], rect->data[0], gray,
                        rect->w, rect->h, rect->linesize[0], scale);

    text = TessBaseAPIRect(ctx->tess, gray, 1, sw, 0, 0, sw, sh);
    av_free(gray);

    if (!text || !text[0]) {
        if (text)
            TessDeleteText(text);
        return 0;
    }

    *out_text = text;
    return 0;
}

static int trim_trailing(const char *text, int len)
{
    while (len > 0 && (text[len - 1] == '\n' || text[len - 1] == '\r' ||
                       text[len - 1] == ' '  || text[len - 1] == '\t'))
        len--;
    return len;
}

/**
 * Fix common Tesseract misreads of the ♪ music note symbol.
 *
 * Tesseract reads ♪ as J, &, I, or ' at the start of lines.
 * Patterns matched (per line):
 *   [&JI'][&JI'] (?=[A-Z])  →  ♪   (double misread)
 *   [&JI'] (?=[A-Z])        →  ♪   (single misread)
 * Preserves optional "- " dialog prefix.
 *
 * Operates in-place on buf[0..len-1]. Returns new length.
 */
static int fix_music_notes(uint8_t *buf, int len, int bufsize)
{
    static const uint8_t note_utf8[] = {0xE2, 0x99, 0xAA}; /* ♪ U+266A */
    uint8_t *tmp;
    int src = 0, dst = 0;
    int at_line_start = 1;

    if (len <= 0)
        return len;

    tmp = av_malloc(bufsize);
    if (!tmp)
        return len;

    while (src < len && dst < bufsize - 4) {
        if (at_line_start) {
            int s = src;

            /* skip optional "- " dialog prefix */
            if (s < len - 1 && buf[s] == '-' && buf[s + 1] == ' ') {
                tmp[dst++] = buf[s++];
                tmp[dst++] = buf[s++];
            } else if (s < len - 2 && buf[s] == '-' && buf[s + 1] != ' ') {
                /* "- " with no space variant: "-X" — not a dialog prefix */
            }

            /* check for misread music note: one or two chars from [&JI'] */
            if (s < len - 1 &&
                (buf[s] == '&' || buf[s] == 'J' || buf[s] == 'I' ||
                 buf[s] == '\'' || buf[s] == ';')) {
                int note_chars = 1;

                /* check for double misread */
                if (s + 1 < len &&
                    (buf[s + 1] == '&' || buf[s + 1] == 'J' ||
                     buf[s + 1] == 'I' || buf[s + 1] == '\'' ||
                     buf[s + 1] == ';'))
                    note_chars = 2;

                /* must be followed by space + uppercase letter */
                if (s + note_chars < len - 1 &&
                    buf[s + note_chars] == ' ' &&
                    buf[s + note_chars + 1] >= 'A' &&
                    buf[s + note_chars + 1] <= 'Z') {
                    tmp[dst++] = note_utf8[0];
                    tmp[dst++] = note_utf8[1];
                    tmp[dst++] = note_utf8[2];
                    src = s + note_chars; /* skip misread chars, keep the space */
                    at_line_start = 0;
                    continue;
                }
            }
            at_line_start = 0;
        }

        if (buf[src] == '\n')
            at_line_start = 1;

        tmp[dst++] = buf[src++];
    }

    memcpy(buf, tmp, dst);
    av_free(tmp);
    return dst;
}

static int ocr_subtitle_encode(AVCodecContext *avctx, uint8_t *buf,
                               int bufsize, const AVSubtitle *sub)
{
    OCRSubtitleContext *ctx = avctx->priv_data;
    int total = 0;

    for (unsigned i = 0; i < sub->num_rects; i++) {
        const AVSubtitleRect *rect = sub->rects[i];
        char *text = NULL;
        int len, ret;

        if (rect->type != SUBTITLE_BITMAP)
            continue;

        ret = ocr_bitmap_rect(avctx, rect, &text);
        if (ret < 0)
            return ret;
        if (!text)
            continue;

        len = trim_trailing(text, strlen(text));
        if (len <= 0) {
            TessDeleteText(text);
            continue;
        }

        /* Separate multiple rects with a newline */
        if (total > 0) {
            if (total + 1 > bufsize) {
                TessDeleteText(text);
                return AVERROR_BUFFER_TOO_SMALL;
            }
            buf[total++] = '\n';
        }

        if (total + len > bufsize) {
            TessDeleteText(text);
            return AVERROR_BUFFER_TOO_SMALL;
        }

        memcpy(buf + total, text, len);
        total += len;
        TessDeleteText(text);
    }

    if (ctx->fixups && total > 0)
        total = fix_music_notes(buf, total, bufsize);

    return total;
}

static av_cold int ocr_subtitle_close(AVCodecContext *avctx)
{
    OCRSubtitleContext *ctx = avctx->priv_data;

    if (ctx->tess) {
        TessBaseAPIEnd(ctx->tess);
        TessBaseAPIDelete(ctx->tess);
        ctx->tess = NULL;
    }

    return 0;
}

#define OFFSET(x) offsetof(OCRSubtitleContext, x)
#define E (AV_OPT_FLAG_ENCODING_PARAM | AV_OPT_FLAG_SUBTITLE_PARAM)

static const AVOption ocr_subtitle_options[] = {
    { "ocr_language", "Tesseract OCR language (auto-detected from stream, falls back to eng)",
      OFFSET(language), AV_OPT_TYPE_STRING, { .str = NULL }, 0, 0, E },
    { "datapath", "Path to Tesseract tessdata directory",
      OFFSET(datapath), AV_OPT_TYPE_STRING, { .str = NULL }, 0, 0, E },
    { "ocr_fixups", "Apply post-processing fixes for common OCR misreads (e.g. music notes)",
      OFFSET(fixups), AV_OPT_TYPE_BOOL, { .i64 = 0 }, 0, 1, E },
    { "ocr_scale", "Upscale factor for bitmap before OCR (improves accuracy and line detection)",
      OFFSET(scale), AV_OPT_TYPE_INT, { .i64 = 3 }, 1, 8, E },
    { NULL },
};

static const AVClass ocr_subtitle_class = {
    .class_name = "OCR subtitle encoder",
    .item_name  = av_default_item_name,
    .option     = ocr_subtitle_options,
    .version    = LIBAVUTIL_VERSION_INT,
};

const FFCodec ff_ocr_subtitle_encoder = {
    .p.name         = "ocr_subtitle",
    .p.long_name    = NULL_IF_CONFIG_SMALL("OCR bitmap-to-text subtitle encoder"),
    .p.type         = AVMEDIA_TYPE_SUBTITLE,
    .p.id           = AV_CODEC_ID_WEBVTT,
    .p.priv_class   = &ocr_subtitle_class,
    .priv_data_size = sizeof(OCRSubtitleContext),
    .init           = ocr_subtitle_init,
    FF_CODEC_ENCODE_SUB_CB(ocr_subtitle_encode),
    .close          = ocr_subtitle_close,
};
