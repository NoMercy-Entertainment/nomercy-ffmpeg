/*
 * Unit tests for scripts/includes/nm_whisper_words.h: JSON escaping with
 * UTF-8 repair, and the token-to-word builder behind word_timestamps=1.
 *
 * Plain C, no FFmpeg and no whisper.cpp, so it runs anywhere in a second:
 *
 *   cc -std=c11 -Wall -Wextra -Werror -I scripts/includes \
 *      tests/unit/test_nm_whisper_words.c -o test_nm_whisper_words
 *   ./test_nm_whisper_words
 *
 * tests/unit/run.sh does exactly that. Exit code 0 means every check passed.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "nm_whisper_words.h"

static int failures;
static int checks;

#define CHECK(cond) do {                                                    \
        checks++;                                                           \
        if (!(cond)) {                                                      \
            failures++;                                                     \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
        }                                                                   \
    } while (0)

static void check_escape(const char *in, const char *want, int line)
{
    char *got = nm_json_escape(in);
    checks++;
    if (!got || strcmp(got, want)) {
        failures++;
        fprintf(stderr, "FAIL %s:%d: escape: got \"%s\", want \"%s\"\n",
                __FILE__, line, got ? got : "(null)", want);
    }
    free(got);
}
#define ESC(in, want) check_escape(in, want, __LINE__)

/* U+FFFD as UTF-8. */
#define R "\xEF\xBF\xBD"

static void test_escape_unchanged_for_valid_input(void)
{
    /* Everything json_escape() did before must come out byte for byte. */
    ESC("", "");
    ESC("hello", "hello");
    ESC("say \"hi\"", "say \\\"hi\\\"");
    ESC("a\\b", "a\\\\b");
    ESC("\b\f\n\r\t", "\\b\\f\\n\\r\\t");
    ESC("\x01\x1f", "\\u0001\\u001f");
    ESC("\x7f", "\x7f");
    /* Valid multi-byte UTF-8 passes through untouched. */
    ESC("caf\xC3\xA9", "caf\xC3\xA9");                   /* U+00E9 */
    ESC("\xE6\x97\xA5\xE6\x9C\xAC", "\xE6\x97\xA5\xE6\x9C\xAC"); /* 日本 */
    ESC("\xF0\x9F\x8E\xB5", "\xF0\x9F\x8E\xB5");         /* U+1F3B5 */
    ESC("\xED\x9F\xBF", "\xED\x9F\xBF");                 /* U+D7FF, last before surrogates */
    ESC("\xEE\x80\x80", "\xEE\x80\x80");                 /* U+E000, first after */
    ESC("\xF4\x8F\xBF\xBF", "\xF4\x8F\xBF\xBF");         /* U+10FFFF */
    ESC(R, R);                                           /* U+FFFD itself */
}

static void test_escape_repairs_invalid_utf8(void)
{
    /* A character cut in half by BPE at the end of a segment. */
    ESC("\xE6\x97", R);
    ESC("ab\xE6", "ab" R);
    ESC("\xF0\x9F\x8E", R);
    /* ...and in the middle, followed by ASCII. */
    ESC("\xE6\x97" "x", R "x");
    /* Stray continuation bytes: one replacement each. */
    ESC("\x80", R);
    ESC("\x80\xBF", R R);
    /* Bytes that never occur in UTF-8. */
    ESC("\xC0\xAF", R R);                /* overlong '/' */
    ESC("\xC1\xBF", R R);
    ESC("\xF5\x80\x80\x80", R R R R);
    ESC("\xFF", R);
    /* Overlong three- and four-byte forms. */
    ESC("\xE0\x80\xAF", R R R);
    ESC("\xF0\x80\x80\xAF", R R R R);
    /* UTF-16 surrogates are not characters. */
    ESC("\xED\xA0\x80", R R R);
    /* Beyond U+10FFFF. */
    ESC("\xF4\x90\x80\x80", R R R R);
    /* A lead byte followed by a valid character: the maximal subpart is
     * just the lead, and the next character survives. */
    ESC("\xE6" "\xC3\xA9", R "\xC3\xA9");
    /* Escaping still applies around a repair. */
    ESC("\"\xE6\"", "\\\"" R "\\\"");
}

static NMWhisperToken tok(const char *text, int special, int64_t t0, int64_t t_dtw, float p)
{
    NMWhisperToken t;
    t.text = text;
    t.special = special;
    t.t0 = t0;
    t.t_dtw = t_dtw;
    t.p = p;
    return t;
}

static int build(const NMWhisperToken *t, int n, int64_t offset, int64_t s, int64_t e,
                 int dtw, NMWhisperWord **w, int *nw)
{
    return nm_whisper_build_words(t, n, offset, s, e, dtw, w, nw);
}

static void test_words_split_on_leading_space(void)
{
    /* " And so, my" -> And | so, | my ; "Amer" "icans" re-joined. */
    NMWhisperToken t[] = {
        tok("[_BEG_]", 1, 0, -1, 1.0f),
        tok(" And", 0, 10, -1, 0.9f),
        tok(" so", 0, 30, -1, 0.8f),
        tok(",", 0, 40, -1, 0.6f),
        tok(" Amer", 0, 50, -1, 0.5f),
        tok("icans", 0, 60, -1, 0.7f),
        tok("[_TT_100]", 1, 100, -1, 1.0f),
    };
    NMWhisperWord *w = NULL;
    int n = -1;

    CHECK(build(t, 7, 1000, 1000, 2000, 0, &w, &n) == 0);
    CHECK(n == 3);
    if (n == 3) {
        CHECK(!strcmp(w[0].text, "And"));
        CHECK(!strcmp(w[1].text, "so,"));
        CHECK(!strcmp(w[2].text, "Americans"));
        /* t0 is in centiseconds relative to the window: 1000 + 10*10. */
        CHECK(w[0].start == 1100);
        CHECK(w[1].start == 1300);
        CHECK(w[2].start == 1500);
        /* end = next word's start, last word ends at the segment end. */
        CHECK(w[0].end == 1300);
        CHECK(w[1].end == 1500);
        CHECK(w[2].end == 2000);
        /* p = mean token probability. */
        CHECK(w[1].p > 0.699f && w[1].p < 0.701f);
        CHECK(w[2].p > 0.599f && w[2].p < 0.601f);
    }
    nm_whisper_free_words(w, n);
}

static void test_words_first_token_without_space_starts_a_word(void)
{
    NMWhisperToken t[] = {
        tok("Hello", 0, 0, -1, 1.0f),
        tok(" world", 0, 50, -1, 1.0f),
    };
    NMWhisperWord *w = NULL;
    int n = -1;

    CHECK(build(t, 2, 0, 0, 1000, 0, &w, &n) == 0);
    CHECK(n == 2);
    if (n == 2) {
        CHECK(!strcmp(w[0].text, "Hello"));
        CHECK(!strcmp(w[1].text, "world"));
    }
    nm_whisper_free_words(w, n);
}

static void test_words_rejoin_split_utf8(void)
{
    /* 日 is E6 97 A5; BPE can hand it over in two tokens. */
    NMWhisperToken t[] = {
        tok(" \xE6\x97", 0, 0, -1, 1.0f),
        tok("\xA5", 0, 10, -1, 1.0f),
    };
    NMWhisperWord *w = NULL;
    int n = -1;

    CHECK(build(t, 2, 0, 0, 1000, 0, &w, &n) == 0);
    CHECK(n == 1);
    if (n == 1)
        CHECK(!strcmp(w[0].text, "\xE6\x97\xA5"));
    nm_whisper_free_words(w, n);
}

static void test_words_dtw_versus_t0(void)
{
    NMWhisperToken t[] = {
        tok(" one", 0, 10, 25, 1.0f),
        tok(" two", 0, 50, -1, 1.0f),   /* DTW did not place it: falls back to t0 */
        tok(" three", 0, 80, 70, 1.0f),
    };
    NMWhisperWord *w = NULL;
    int n = -1;

    CHECK(build(t, 3, 0, 0, 1000, 1, &w, &n) == 0);
    CHECK(n == 3);
    if (n == 3) {
        CHECK(w[0].start == 250);
        CHECK(w[1].start == 500);
        CHECK(w[2].start == 700);
    }
    nm_whisper_free_words(w, n);

    /* Same tokens with DTW off: t_dtw is ignored. */
    CHECK(build(t, 3, 0, 0, 1000, 0, &w, &n) == 0);
    CHECK(n == 3);
    if (n == 3) {
        CHECK(w[0].start == 100);
        CHECK(w[1].start == 500);
        CHECK(w[2].start == 800);
    }
    nm_whisper_free_words(w, n);
}

static void test_words_clamped_and_monotonic(void)
{
    /* DTW put the first token before the segment and the last after it, and
     * the middle one earlier than its predecessor. */
    NMWhisperToken t[] = {
        tok(" a", 0, 0, 5, 1.0f),      /* 50 ms, segment starts at 100 */
        tok(" b", 0, 0, 60, 1.0f),     /* 600 ms */
        tok(" c", 0, 0, 40, 1.0f),     /* 400 ms: earlier than b */
        tok(" d", 0, 0, 150, 1.0f),    /* 1500 ms, segment ends at 1000 */
    };
    NMWhisperWord *w = NULL;
    int n = -1;

    CHECK(build(t, 4, 0, 100, 1000, 1, &w, &n) == 0);
    CHECK(n == 4);
    if (n == 4) {
        CHECK(w[0].start == 100);
        CHECK(w[1].start == 600);
        CHECK(w[2].start == 600);
        CHECK(w[3].start == 1000);
        for (int i = 0; i < 4; i++) {
            CHECK(w[i].start >= 100 && w[i].end <= 1000);
            CHECK(w[i].start <= w[i].end);
            if (i)
                CHECK(w[i].start >= w[i - 1].start);
        }
    }
    nm_whisper_free_words(w, n);
}

static void test_words_unknown_times(void)
{
    /* No token timing at all (t0 = -1, no DTW): starts fall back to the
     * segment start and never go backwards. */
    NMWhisperToken t[] = {
        tok(" x", 0, -1, -1, 1.0f),
        tok(" y", 0, -1, -1, 1.0f),
    };
    NMWhisperWord *w = NULL;
    int n = -1;

    CHECK(build(t, 2, 500, 700, 900, 0, &w, &n) == 0);
    CHECK(n == 2);
    if (n == 2) {
        CHECK(w[0].start == 700 && w[1].start == 700);
        CHECK(w[0].end == 700 && w[1].end == 900);
    }
    nm_whisper_free_words(w, n);
}

static void test_words_blank_audio_and_empty(void)
{
    /* [BLANK_AUDIO] arrives as ordinary text tokens; the filter strips it from
     * the segment text, so it must not show up as a word either. A bare
     * space token must not produce an empty word. */
    NMWhisperToken t[] = {
        tok(" hi", 0, 0, -1, 1.0f),
        tok(" [", 0, 20, -1, 1.0f),
        tok("BL", 0, 21, -1, 1.0f),
        tok("ANK", 0, 22, -1, 1.0f),
        tok("_", 0, 23, -1, 1.0f),
        tok("AUDIO", 0, 24, -1, 1.0f),
        tok("]", 0, 25, -1, 1.0f),
        tok(" ", 0, 30, -1, 1.0f),
        tok(" there", 0, 40, -1, 1.0f),
    };
    NMWhisperWord *w = NULL;
    int n = -1;

    CHECK(build(t, 9, 0, 0, 1000, 0, &w, &n) == 0);
    CHECK(n == 2);
    if (n == 2) {
        CHECK(!strcmp(w[0].text, "hi"));
        CHECK(!strcmp(w[1].text, "there"));
        CHECK(w[0].start == 0 && w[1].start == 400);
        /* The dropped words leave no gap: hi runs up to there. */
        CHECK(w[0].end == 400);
    }
    nm_whisper_free_words(w, n);
}

static void test_words_no_text_tokens(void)
{
    NMWhisperToken t[] = { tok("[_BEG_]", 1, 0, -1, 1.0f) };
    NMWhisperWord *w = NULL;
    int n = -1;

    CHECK(build(t, 1, 0, 0, 1000, 0, &w, &n) == 0);
    CHECK(n == 0);
    nm_whisper_free_words(w, n);
    CHECK(build(NULL, 0, 0, 0, 1000, 0, &w, &n) == 0);
    CHECK(n == 0);
    nm_whisper_free_words(w, n);
}

static void test_words_json(void)
{
    NMWhisperToken t[] = {
        tok(" \"hello\"", 0, 0, -1, 0.9314f),
        tok(" w\xE6\x97", 0, 37, -1, 1.5f),    /* truncated character, p > 1 */
    };
    NMWhisperWord *w = NULL;
    int n = -1;
    char *json;

    CHECK(build(t, 2, 12340, 12340, 15020, 0, &w, &n) == 0);
    json = nm_whisper_words_json(w, n);
    CHECK(json != NULL);
    if (json) {
        const char *want =
            "[{\"text\":\"\\\"hello\\\"\",\"start\":12340,\"end\":12710,\"p\":0.931},"
            "{\"text\":\"w" R "\",\"start\":12710,\"end\":15020,\"p\":1.000}]";
        checks++;
        if (strcmp(json, want)) {
            failures++;
            fprintf(stderr, "FAIL %s:%d: words json:\n got  %s\n want %s\n",
                    __FILE__, __LINE__, json, want);
        }
    }
    free(json);
    nm_whisper_free_words(w, n);

    json = nm_whisper_words_json(NULL, 0);
    CHECK(json && !strcmp(json, "[]"));
    free(json);
}

static void test_dtw_presets(void)
{
    static const char *names[] = {
        "tiny", "tiny.en", "base", "base.en", "small", "small.en",
        "medium", "medium.en", "large.v1", "large.v2", "large.v3", "large.v3.turbo",
    };
    const int n = (int) (sizeof(names) / sizeof(names[0]));

    CHECK(nm_whisper_dtw_preset_count() == n);
    for (int i = 0; i < n; i++) {
        const int idx = nm_whisper_dtw_preset_find(names[i]);
        CHECK(idx >= 0);
        CHECK(idx >= 0 && !strcmp(nm_whisper_dtw_preset_name(idx), names[i]));
        CHECK(strstr(nm_whisper_dtw_preset_list(), names[i]) != NULL);
    }
    CHECK(nm_whisper_dtw_preset_find("") < 0);
    CHECK(nm_whisper_dtw_preset_find("large") < 0);
    CHECK(nm_whisper_dtw_preset_find("base.EN") < 0);
    CHECK(nm_whisper_dtw_preset_find("large-v3") < 0);

    /* layers, heads, multilingual, n_mels of the real models */
    CHECK(nm_whisper_dtw_preset_matches(nm_whisper_dtw_preset_find("base.en"), 6, 8, 0, 80));
    CHECK(!nm_whisper_dtw_preset_matches(nm_whisper_dtw_preset_find("base"), 6, 8, 0, 80));
    CHECK(nm_whisper_dtw_preset_matches(nm_whisper_dtw_preset_find("base"), 6, 8, 1, 80));
    CHECK(!nm_whisper_dtw_preset_matches(nm_whisper_dtw_preset_find("tiny.en"), 6, 8, 0, 80));
    CHECK(!nm_whisper_dtw_preset_matches(nm_whisper_dtw_preset_find("large.v3"), 6, 8, 0, 80));
    CHECK(nm_whisper_dtw_preset_matches(nm_whisper_dtw_preset_find("large.v2"), 32, 20, 1, 80));
    CHECK(nm_whisper_dtw_preset_matches(nm_whisper_dtw_preset_find("large.v1"), 32, 20, 1, 80));
    CHECK(!nm_whisper_dtw_preset_matches(nm_whisper_dtw_preset_find("large.v3"), 32, 20, 1, 80));
    CHECK(nm_whisper_dtw_preset_matches(nm_whisper_dtw_preset_find("large.v3"), 32, 20, 1, 128));
    CHECK(nm_whisper_dtw_preset_matches(nm_whisper_dtw_preset_find("large.v3.turbo"), 4, 20, 1, 128));
    CHECK(!nm_whisper_dtw_preset_matches(nm_whisper_dtw_preset_find("tiny"), 4, 20, 1, 128));
    CHECK(nm_whisper_dtw_preset_matches(nm_whisper_dtw_preset_find("medium.en"), 24, 16, 0, 80));
    CHECK(!nm_whisper_dtw_preset_matches(-1, 6, 8, 0, 80));
}

static void test_model_header(void)
{
    /* The first 48 bytes of the real ggml-base.en.bin and ggml-large-v3.bin. */
    static const unsigned char base_en[48] = {
        0x6c, 0x6d, 0x67, 0x67, 0x98, 0xca, 0x00, 0x00, 0xdc, 0x05, 0x00, 0x00,
        0x00, 0x02, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00,
        0xc0, 0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00,
        0x06, 0x00, 0x00, 0x00, 0x50, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
    };
    static const unsigned char large_v3[48] = {
        0x6c, 0x6d, 0x67, 0x67, 0x9a, 0xca, 0x00, 0x00, 0xdc, 0x05, 0x00, 0x00,
        0x00, 0x05, 0x00, 0x00, 0x14, 0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00,
        0xc0, 0x01, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x14, 0x00, 0x00, 0x00,
        0x20, 0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
    };
    unsigned char bad[48];
    NMWhisperModelShape s;

    CHECK(nm_whisper_parse_model_header(base_en, sizeof(base_en), &s) == 0);
    CHECK(s.n_vocab == 51864 && s.n_text_layer == 6 && s.n_text_head == 8 && s.n_mels == 80);
    CHECK(!nm_whisper_model_multilingual(&s));
    CHECK(nm_whisper_dtw_preset_matches(nm_whisper_dtw_preset_find("base.en"), s.n_text_layer,
                                        s.n_text_head, nm_whisper_model_multilingual(&s), s.n_mels));
    CHECK(!nm_whisper_dtw_preset_matches(nm_whisper_dtw_preset_find("large.v3"), s.n_text_layer,
                                         s.n_text_head, nm_whisper_model_multilingual(&s), s.n_mels));

    CHECK(nm_whisper_parse_model_header(large_v3, sizeof(large_v3), &s) == 0);
    CHECK(s.n_vocab == 51866 && s.n_text_layer == 32 && s.n_text_head == 20 && s.n_mels == 128);
    CHECK(nm_whisper_model_multilingual(&s));
    CHECK(nm_whisper_dtw_preset_matches(nm_whisper_dtw_preset_find("large.v3"), s.n_text_layer,
                                        s.n_text_head, nm_whisper_model_multilingual(&s), s.n_mels));

    /* Too short, or not a ggml file: rejected, never guessed at. */
    CHECK(nm_whisper_parse_model_header(base_en, 47, &s) < 0);
    memcpy(bad, base_en, sizeof(bad));
    bad[0] = 'G';
    CHECK(nm_whisper_parse_model_header(bad, sizeof(bad), &s) < 0);
    memcpy(bad, base_en, sizeof(bad));
    bad[23] = 0x80;                  /* n_audio_layer negative */
    CHECK(nm_whisper_parse_model_header(bad, sizeof(bad), &s) < 0);
}

int main(void)
{
    test_escape_unchanged_for_valid_input();
    test_escape_repairs_invalid_utf8();
    test_words_split_on_leading_space();
    test_words_first_token_without_space_starts_a_word();
    test_words_rejoin_split_utf8();
    test_words_dtw_versus_t0();
    test_words_clamped_and_monotonic();
    test_words_unknown_times();
    test_words_blank_audio_and_empty();
    test_words_no_text_tokens();
    test_words_json();
    test_dtw_presets();
    test_model_header();

    if (failures) {
        fprintf(stderr, "%d of %d checks failed\n", failures, checks);
        return 1;
    }
    printf("all %d checks passed\n", checks);
    return 0;
}
