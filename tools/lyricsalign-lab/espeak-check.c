/*
 * espeak-check: print the IPA phones espeak-ng's library gives for a sentence,
 * the way the lyricsalign filter asks for them, so they can be compared with
 * the CLI's `espeak-ng -q --ipa --sep=_ -v <voice>` output the prototype used.
 *
 *   espeak-check <espeak-ng-data dir> <voice> "<sentence>"
 *
 * Exit 1 when the voice is unknown (prints the espeak error code), 2 when the
 * data directory cannot be initialised.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <espeak-ng/speak_lib.h>

int main(int argc, char **argv)
{
    if (argc != 4) {
        fprintf(stderr, "usage: espeak-check <espeak-ng-data> <voice> <sentence>\n");
        return 2;
    }
    if (espeak_Initialize(AUDIO_OUTPUT_SYNCHRONOUS, 0, argv[1], 0) < 0) {
        fprintf(stderr, "espeak_Initialize failed for %s\n", argv[1]);
        return 2;
    }
    espeak_ERROR rc = espeak_SetVoiceByName(argv[2]);
    if (rc != EE_OK) {
        fprintf(stderr, "espeak_SetVoiceByName(%s) = %d\n", argv[2], (int) rc);
        return 1;
    }
    const void *p = argv[3];
    int first = 1;
    while (p) {
        const char *ipa = espeak_TextToPhonemes(&p, espeakCHARS_UTF8, espeakPHONEMES_IPA | ('_' << 8));
        if (!ipa)
            break;
        printf("%s%s", first ? "" : " ", ipa);
        first = 0;
    }
    printf("\n");
    return 0;
}
