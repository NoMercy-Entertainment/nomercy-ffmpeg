/* Test-only libvulkan.so.1 replacement. Never ship it with FFmpeg. */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

__attribute__((constructor)) static void hostile_loader_init(void)
{
    const char *trace = getenv("NM_FIXTURE_TRACE");
    if (trace) {
        int fd = open(trace, O_WRONLY | O_CREAT | O_APPEND, 0600);
        if (fd >= 0) {
            char line[80];
            int length = snprintf(line, sizeof(line), "loaded pid=%ld mode=%s\n", (long) getpid(),
#ifdef NM_HOSTILE_HANG
                                  "hang"
#else
                                  "abort"
#endif
            );
            if (length > 0 && length < (int) sizeof(line)) {
                ssize_t ignored = write(fd, line, (size_t) length);
                (void) ignored;
            }
            close(fd);
        }
    }
#ifdef NM_HOSTILE_HANG
    for (;;)
        pause();
#else
    abort();
#endif
}
