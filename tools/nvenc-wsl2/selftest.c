/* Exercises every symbol nmcompat.c defines (plan Task 1, symbol table).
 * Linking is not evidence: a shim built with _GNU_SOURCE links cleanly and
 * then calls itself forever the first time the symbol is reached. This
 * program must actually RUN, which is why build-selftest.sh executes it
 * rather than stopping at a successful link.
 *
 * The C++ exception test (what _dl_find_object exists for) lives in the
 * companion translation unit selftest_cxx.cpp, built and run separately.
 */
#include <errno.h>
#include <locale.h>
#include <math.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#include <wchar.h>

int fails = 0;
/* cond is evaluated exactly once into _ok: several checks call functions
 * with side effects (the scanf family consumes stream state, pidfd_spawnp
 * spawns a process, strlcat mutates its buffer), so evaluating cond twice
 * — once for the printed branch, once for the fails++ branch — lets the
 * two evaluations disagree and prints "ok" while still counting a FAIL,
 * or the reverse. That is exactly the kind of check that lies. */
#define CHECK(label, cond) do { \
    int _ok = !!(cond); \
    printf("%-24s %s\n", (label), _ok ? "ok" : "FAIL"); \
    if (!_ok) fails++; \
} while (0)

/* ---- BSD string (nmcompat.c) ---- */
extern size_t strlcpy(char *dst, const char *src, size_t size);
extern size_t strlcat(char *dst, const char *src, size_t size);

/* ---- wide-char BSD string (nmcompat.c); GLIBC_2.38 additions, the exact
 * gap that let ffplay ship needing a floor above 2.34 (libXext references
 * both -- see the Task 3b report). ---- */
extern size_t wcslcpy(wchar_t *dst, const wchar_t *src, size_t size);
extern size_t wcslcat(wchar_t *dst, const wchar_t *src, size_t size);

/* ---- randomness (nmcompat.c) ---- */
extern unsigned int arc4random(void);
extern void arc4random_buf(void *buf, size_t n);

/* ---- unwinder (nmcompat.c); local copy of the ABI struct glibc >= 2.35
 * defines in <bits/dl_find_object.h> (x86_64: no eh_dbase, no eh_count). */
struct nm_dl_find_object {
    unsigned long long flags;
    void *map_start;
    void *map_end;
    void *link_map;
    void *eh_frame;
    unsigned long long reserved[7];
};
extern int _dl_find_object(void *address, struct nm_dl_find_object *result);

/* ---- libmvec (nmcompat.c) ---- */
typedef double v2df __attribute__((vector_size(16)));
extern v2df _ZGVbN2v_log2(v2df x);
extern v2df _ZGVbN2vv_atan2(v2df y, v2df x);

/* ---- pidfd (nmcompat.c) ---- */
extern int pidfd_spawnp(int *pidfd, const char *file,
                         const posix_spawn_file_actions_t *file_actions,
                         const posix_spawnattr_t *attrp,
                         char *const argv[], char *const envp[]);
extern pid_t pidfd_getpid(int pidfd);

/* ---- C23 renames (nmcompat.c); called by their exact shimmed names so the
 * test exercises the real symbols regardless of what this build image's own
 * headers happen to rewrite plain names to. ---- */
extern long int __isoc23_strtol(const char *, char **, int);
extern unsigned long int __isoc23_strtoul(const char *, char **, int);
extern long long int __isoc23_strtoll(const char *, char **, int);
extern unsigned long long int __isoc23_strtoull(const char *, char **, int);
extern long long int __isoc23_strtoll_l(const char *, char **, int, locale_t);
extern unsigned long long int __isoc23_strtoull_l(const char *, char **, int, locale_t);
extern int __isoc23_sscanf(const char *, const char *, ...);
extern int __isoc23_fscanf(FILE *, const char *, ...);
extern int __isoc23_scanf(const char *, ...);
extern int __isoc23_vsscanf(const char *, const char *, va_list);
extern int __isoc23_vfscanf(FILE *, const char *, va_list);
extern int __isoc23_vscanf(const char *, va_list);

static int v_vsscanf(const char *s, const char *fmt, ...)
{
    va_list ap;
    int r;
    va_start(ap, fmt);
    r = __isoc23_vsscanf(s, fmt, ap);
    va_end(ap);
    return r;
}

static int v_vfscanf(FILE *fp, const char *fmt, ...)
{
    va_list ap;
    int r;
    va_start(ap, fmt);
    r = __isoc23_vfscanf(fp, fmt, ap);
    va_end(ap);
    return r;
}

static int v_vscanf(const char *fmt, ...)
{
    va_list ap;
    int r;
    va_start(ap, fmt);
    r = __isoc23_vscanf(fmt, ap);
    va_end(ap);
    return r;
}

/* Feed data on stdin without blocking: write it into a pipe, point fd 0 at
 * the read end, restore the original afterwards. */
static int redirect_stdin(const char *data)
{
    int fds[2];
    int saved;
    if (pipe(fds) != 0)
        return -1;
    if (write(fds[1], data, strlen(data)) < 0) { /* best effort */ }
    close(fds[1]);
    saved = dup(STDIN_FILENO);
    dup2(fds[0], STDIN_FILENO);
    close(fds[0]);
    /* stdin's FILE* keeps its own EOF/error flags independent of what fd 0
     * points at; a prior scanf-family call that ran stdin to EOF leaves
     * those flags set, and the next call would fail immediately without
     * even looking at the freshly redirected data. */
    clearerr(stdin);
    return saved;
}

static void restore_stdin(int saved)
{
    dup2(saved, STDIN_FILENO);
    close(saved);
}

int main(void)
{
    char buf[32];
    int saved_stdin;

    /* Unbuffered: if a check crashes the process, the checks that ran
     * before it are still visible in the log instead of lost in a stdio
     * buffer that never got flushed. */
    setvbuf(stdout, NULL, _IONBF, 0);

    /* C23 renames: reached through their exact shimmed names. A hang here
     * IS the recursion trap (see selftest_cxx.cpp for the guarded variant). */
    CHECK("__isoc23_strtol", __isoc23_strtol("-42", NULL, 10) == -42L);
    CHECK("__isoc23_strtoul", __isoc23_strtoul("42", NULL, 10) == 42UL);
    CHECK("__isoc23_strtoll", __isoc23_strtoll("-7", NULL, 10) == -7LL);
    CHECK("__isoc23_strtoull", __isoc23_strtoull("7", NULL, 10) == 7ULL);
    {
        /* _l functions need a real locale_t; the LC_GLOBAL_LOCALE sentinel
         * is only valid for uselocale(), not as an argument here. */
        locale_t loc = newlocale(LC_ALL_MASK, "C", (locale_t)0);
        CHECK("__isoc23_strtoll_l",
              loc && __isoc23_strtoll_l("-99", NULL, 10, loc) == -99LL);
        CHECK("__isoc23_strtoull_l",
              loc && __isoc23_strtoull_l("99", NULL, 10, loc) == 99ULL);
        if (loc) freelocale(loc);
    }

    {
        int a = 0, b = 0;
        CHECK("__isoc23_sscanf",
              __isoc23_sscanf("3 4", "%d %d", &a, &b) == 2 && a == 3 && b == 4);
    }
    {
        int a = 0, b = 0;
        CHECK("__isoc23_vsscanf",
              v_vsscanf("5 6", "%d %d", &a, &b) == 2 && a == 5 && b == 6);
    }
    {
        FILE *fp = fmemopen((void *)"11 12", 5, "r");
        int a = 0, b = 0;
        CHECK("__isoc23_fscanf",
              fp && __isoc23_fscanf(fp, "%d %d", &a, &b) == 2 && a == 11 && b == 12);
        if (fp) fclose(fp);
    }
    {
        FILE *fp = fmemopen((void *)"13 14", 5, "r");
        int a = 0, b = 0;
        CHECK("__isoc23_vfscanf",
              fp && v_vfscanf(fp, "%d %d", &a, &b) == 2 && a == 13 && b == 14);
        if (fp) fclose(fp);
    }
    {
        int a = 0, b = 0;
        saved_stdin = redirect_stdin("9 10");
        CHECK("__isoc23_scanf",
              saved_stdin >= 0 && __isoc23_scanf("%d %d", &a, &b) == 2 && a == 9 && b == 10);
        if (saved_stdin >= 0) restore_stdin(saved_stdin);
    }
    {
        int a = 0, b = 0;
        saved_stdin = redirect_stdin("15 16");
        CHECK("__isoc23_vscanf",
              saved_stdin >= 0 && v_vscanf("%d %d", &a, &b) == 2 && a == 15 && b == 16);
        if (saved_stdin >= 0) restore_stdin(saved_stdin);
    }

    /* BSD string */
    CHECK("strlcpy", strlcpy(buf, "abc", sizeof buf) == 3 && !strcmp(buf, "abc"));
    CHECK("strlcat", strlcat(buf, "de", sizeof buf) == 5 && !strcmp(buf, "abcde"));

    /* wide-char BSD string. Exercises both the ordinary (fits) case and a
     * truncating case, because the return-value contract -- always the
     * length it TRIED to create, not the truncated copied length -- is
     * exactly the kind of thing that is subtly wrong and still "looks
     * like it links and runs". A caller trusting a wrong truncation
     * signal walks past the end of its own buffer on the next call. */
    {
        wchar_t wbuf[8];
        size_t r;

        r = wcslcpy(wbuf, L"abc", 8);
        CHECK("wcslcpy (fits)", r == 3 && wcscmp(wbuf, L"abc") == 0);

        r = wcslcat(wbuf, L"de", 8);
        CHECK("wcslcat (fits)", r == 5 && wcscmp(wbuf, L"abcde") == 0);

        /* Source longer than the buffer: must truncate but still
         * NUL-terminate, and report the untruncated source length (6),
         * not the 3 characters that actually fit. */
        r = wcslcpy(wbuf, L"abcdef", 4);
        CHECK("wcslcpy (truncates)",
              r == 6 && wbuf[3] == L'\0' && wcscmp(wbuf, L"abc") == 0);
    }

    /* randomness */
    {
        unsigned int r1 = arc4random(), r2 = arc4random();
        unsigned char rb[8] = {0};
        CHECK("arc4random", r1 != 0 || r2 != 0);
        arc4random_buf(rb, sizeof rb);
        CHECK("arc4random_buf", memcmp(rb, "\0\0\0\0\0\0\0\0", 8) != 0);
    }

    /* unwinder, called directly */
    {
        struct nm_dl_find_object dlfo;
        memset(&dlfo, 0, sizeof dlfo);
        CHECK("_dl_find_object",
              _dl_find_object((void *)&main, &dlfo) == 0 &&
              dlfo.map_start != NULL && dlfo.map_end > dlfo.map_start);
    }

    /* libmvec */
    {
        v2df x = { 4.0, 16.0 };
        v2df lg = _ZGVbN2v_log2(x);
        CHECK("_ZGVbN2v_log2", lg[0] == 2.0 && lg[1] == 4.0);

        v2df y = { 1.0, 1.0 }, xx = { 1.0, 0.0 };
        v2df at = _ZGVbN2vv_atan2(y, xx);
        CHECK("_ZGVbN2vv_atan2",
              at[0] > 0.78 && at[0] < 0.79 && at[1] > 1.57 && at[1] < 1.58);
    }

    /* pidfd */
    {
        int pidfd = -1;
        char *argv[] = { (char *)"true", NULL };
        extern char **environ;
        int rc = pidfd_spawnp(&pidfd, "true", NULL, NULL, argv, environ);
        int ok = rc == 0 && pidfd >= 0;
        pid_t got = -1;
        if (ok) {
            got = pidfd_getpid(pidfd);
            close(pidfd);
        }
        int status = 0;
        if (got > 0)
            waitpid(got, &status, 0);
        CHECK("pidfd_spawnp/getpid", ok && got > 0);
    }

    /* versioned forwards */
    CHECK("hypot", hypot(3.0, 4.0) == 5.0);
    CHECK("hypotf", hypotf(3.0f, 4.0f) == 5.0f);
    CHECK("fmod", fmod(7.0, 4.0) == 3.0);
    CHECK("fmodf", fmodf(7.0f, 4.0f) == 3.0f);

    printf("%s\n", fails ? "SELFTEST FAILED" : "SELFTEST PASSED");
    return fails != 0;
}
