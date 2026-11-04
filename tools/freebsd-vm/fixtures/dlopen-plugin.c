/* Test-only DSO. Never include it in an FFmpeg release archive. */
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#define EXPORTED __attribute__((visibility("default")))
static int constructor_ok;
static _Thread_local unsigned thread_value = 17;

__attribute__((constructor)) static void plugin_init(void)
{
    unsigned char *memory = malloc(512);
    if (memory) {
        memset(memory, 0x5a, 512);
        constructor_ok = memory[0] == 0x5a && memory[511] == 0x5a;
        free(memory);
    }
}

EXPORTED int nm_fixture_constructor_ok(void) { return constructor_ok; }

EXPORTED int nm_fixture_tls_step(unsigned expected, unsigned next)
{
    if (thread_value != expected)
        return -1;
    thread_value = next;
    return (int) thread_value;
}

EXPORTED void *nm_fixture_allocate(size_t bytes) { return malloc(bytes); }
EXPORTED void nm_fixture_release(void *memory) { free(memory); }
