#!/bin/bash

# OCR Subtitle Encoder — converts bitmap subtitles to text using Tesseract OCR
# Registers ff_ocr_subtitle_encoder in libavcodec with AV_CODEC_ID_WEBVTT

# Copy the encoder source to FFmpeg
cp /scripts/includes/ocr_subtitle_enc.c /build/ffmpeg/libavcodec/ocr_subtitle_enc.c

# 1. Register the encoder extern declaration in allcodecs.c
log "Step 1: Adding extern declaration to allcodecs.c"

if ! grep -q "ff_ocr_subtitle_encoder" /build/ffmpeg/libavcodec/allcodecs.c; then
    sed -i '0,/^extern const FFCodec ff_movtext_encoder;$/s//&\nextern const FFCodec ff_ocr_subtitle_encoder;/' /build/ffmpeg/libavcodec/allcodecs.c
    log "  Added extern declaration"
else
    log "  Extern declaration already exists"
fi

if grep -q "ff_ocr_subtitle_encoder" /build/ffmpeg/libavcodec/allcodecs.c; then
    log "  Verified in allcodecs.c"
else
    log "  ERROR: allcodecs.c verification failed!"
    exit 1
fi

# 2. Add the encoder object to the Makefile
log "Step 2: Adding to Makefile"

if ! grep -q "ocr_subtitle_enc.o" /build/ffmpeg/libavcodec/Makefile; then
    sed -i '/^OBJS-\$(CONFIG_TEXT_ENCODER)/a\
OBJS-$(CONFIG_OCR_SUBTITLE_ENCODER)          += ocr_subtitle_enc.o' /build/ffmpeg/libavcodec/Makefile
    log "  Added to Makefile"
else
    log "  Makefile entry already exists"
fi

if grep -q "ocr_subtitle_enc.o" /build/ffmpeg/libavcodec/Makefile; then
    log "  Verified in Makefile"
else
    log "  ERROR: Makefile verification failed!"
    exit 1
fi

# 3. Declare libtesseract dependency in configure
#    Insert next to the existing ocr_filter_deps (also libtesseract)
log "Step 3: Adding encoder dependency to configure"

if ! grep -q "ocr_subtitle_encoder_deps" /build/ffmpeg/configure; then
    sed -i '/^ocr_filter_deps=/a ocr_subtitle_encoder_deps="libtesseract"' /build/ffmpeg/configure
    log "  Added encoder dependency"
else
    log "  Encoder dependency already exists"
fi

if grep -q "ocr_subtitle_encoder_deps" /build/ffmpeg/configure; then
    log "  Verified in configure"
else
    log "  ERROR: configure verification failed!"
    exit 1
fi

# 4. Patch fftools to allow bitmap→text subtitle transcoding for ocr_subtitle
#    FFmpeg blocks cross-type subtitle encoding (bitmap↔text) in ffmpeg_mux_init.c.
#    We relax the check: skip the error when the encoder is ocr_subtitle.
log "Step 4: Patching ffmpeg_mux_init.c for bitmap-to-text transcoding"

if ! grep -q "ocr_subtitle" /build/ffmpeg/fftools/ffmpeg_mux_init.c; then
    sed -i 's/input_props != output_props) {/input_props != output_props \&\&\n            (!subtitle_enc->codec || strcmp(subtitle_enc->codec->name, "ocr_subtitle"))) {/' /build/ffmpeg/fftools/ffmpeg_mux_init.c
    log "  Patched bitmap-to-text check"
else
    log "  Patch already applied"
fi

if grep -q "ocr_subtitle" /build/ffmpeg/fftools/ffmpeg_mux_init.c; then
    log "  Verified in ffmpeg_mux_init.c"
else
    log "  ERROR: ffmpeg_mux_init.c verification failed!"
    exit 1
fi

# 5. Auto-detect OCR language from input stream metadata
#    When the user doesn't specify -ocr_language, read the language tag from
#    the input subtitle stream and pass it to the encoder before init.
#    Priority: user -ocr_language > stream metadata > "eng" fallback (in encoder init)
log "Step 5: Patching language auto-detection from stream metadata"

if ! grep -q "ocr_language" /build/ffmpeg/fftools/ffmpeg_mux_init.c; then
    cat > /tmp/ocr_lang_patch.c << 'LANGPATCH'

        /* Auto-detect OCR language from input stream metadata */
        if (subtitle_enc->codec &&
            !strcmp(subtitle_enc->codec->name, "ocr_subtitle")) {
            uint8_t *lang = NULL;
            av_opt_get(subtitle_enc, "ocr_language", AV_OPT_SEARCH_CHILDREN, &lang);
            if (!lang || !lang[0]) {
                AVDictionaryEntry *e = av_dict_get(ost->ist->st->metadata, "language", NULL, 0);
                if (e && e->value[0])
                    av_opt_set(subtitle_enc, "ocr_language", e->value, AV_OPT_SEARCH_CHILDREN);
            }
            av_free(lang);
        }
LANGPATCH

    # Insert after the closing brace of the bitmap-text check (first } after "bitmap to bitmap")
    awk '
    /or bitmap to bitmap/ { found=1 }
    found && /^        \}/ {
        print
        while ((getline line < "/tmp/ocr_lang_patch.c") > 0) print line
        found=0
        next
    }
    { print }' /build/ffmpeg/fftools/ffmpeg_mux_init.c > /tmp/mux_init_patched.c \
        && mv /tmp/mux_init_patched.c /build/ffmpeg/fftools/ffmpeg_mux_init.c

    rm -f /tmp/ocr_lang_patch.c
    log "  Patched language auto-detection"
else
    log "  Language patch already applied"
fi

if grep -q "ocr_language" /build/ffmpeg/fftools/ffmpeg_mux_init.c; then
    log "  Verified language detection in ffmpeg_mux_init.c"
else
    log "  ERROR: language detection verification failed!"
    exit 1
fi

exit 0
