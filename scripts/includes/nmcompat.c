/*
 * nmcompat.c — glibc symbol compatibility shim for the dynamically linked
 * linux-x86_64 ffmpeg (issue #42 / NVENC under WSL2).
 *
 * Compiled once with: gcc -O2 -fPIC -fvisibility=hidden -fno-builtin -c
 * and appended (as a .o, not a .a) to ffmpeg's --extra-libs, so it
 * contributes every definition unconditionally and link order cannot
 * matter.
 *
 * It exists because dropping -static (required for h264_nvenc to work
 * inside WSL2 — see docs/superpowers/research/2026-09-26-nvenc-wsl2-findings.md)
 * turns every symbol reference above GLIBC_2.34 in the prebuilt archives
 * and in GCC 13's own libstdc++.a / libgcc_eh.a into a hard runtime
 * requirement. This file defines exactly those symbols against the older,
 * always-present base APIs, so the executable's glibc floor stays pinned
 * at GLIBC_2.34 — not lower (impossible on this toolchain) and not higher
 * (which silently drops the entire EL9 family and Amazon Linux 2023).
 *
 * Two rules are mandatory and both measured (see the research doc §4a):
 *
 *   1. NEVER define _GNU_SOURCE (or anything that implies _ISOC2X_SOURCE)
 *      in this file. It rewrites plain names like strtoul() into
 *      __isoc23_strtoul() at the *call site* via the headers — including
 *      inside the definition of __isoc23_strtoul() itself, which would
 *      make it call itself forever. Every forward in this file names its
 *      real target with an asm label instead of calling the plain name.
 *
 *   2. _dl_find_object must be a real dl_iterate_phdr-backed
 *      implementation, not a stub. GCC 13's libgcc_eh.a was built against
 *      glibc >= 2.35 headers, so it already calls _dl_find_object
 *      unconditionally to find the FDE for a PC during unwinding. A null
 *      stub links and even passes `--version`, then aborts on the first
 *      C++ throw.
 *
 * All twelve C23-rename forwards use the same trick: declare a local
 * identifier with __asm__("<real name>") so the compiler binds calls to
 * the *linker* symbol "<real name>" directly, without going through the
 * macro-rewritten C name — which does not exist in this translation unit
 * because _GNU_SOURCE/_ISOC2X_SOURCE is never defined here.
 */

#include <errno.h>
#include <fcntl.h>
#include <locale.h>
#include <math.h>
#include <spawn.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#ifndef SYS_pidfd_open
#define SYS_pidfd_open 434 /* x86_64; not declared on glibc < 5.3 headers */
#endif
#include <sys/syscall.h>

/* This file is always compiled with -fvisibility=hidden (build-selftest.sh
 * and, later, the ffmpeg dockerfile). Every symbol below therefore still
 * resolves at static-link time inside whatever executable links this
 * object, but none of them are exported to that executable's .dynsym —
 * so none can interpose on libcuda / libnvidia-encode / OpenCL / Vulkan,
 * which ffmpeg dlopen()s. Nothing in this file needs to opt into that;
 * it is a compile-flag property, asserted by build-selftest.sh's
 * CHECK_HIDDEN=1 objdump -T check. */

/* ------------------------------------------------------------------ */
/* C23 renames                                                         */
/* ------------------------------------------------------------------ */

extern long int nm_strtol(const char *, char **, int) __asm__("strtol");
extern unsigned long int nm_strtoul(const char *, char **, int) __asm__("strtoul");
extern long long int nm_strtoll(const char *, char **, int) __asm__("strtoll");
extern unsigned long long int nm_strtoull(const char *, char **, int) __asm__("strtoull");
extern long long int nm_strtoll_l(const char *, char **, int, locale_t) __asm__("strtoll_l");
extern unsigned long long int nm_strtoull_l(const char *, char **, int, locale_t) __asm__("strtoull_l");

long int __isoc23_strtol(const char *nptr, char **endptr, int base)
{ return nm_strtol(nptr, endptr, base); }

unsigned long int __isoc23_strtoul(const char *nptr, char **endptr, int base)
{ return nm_strtoul(nptr, endptr, base); }

long long int __isoc23_strtoll(const char *nptr, char **endptr, int base)
{ return nm_strtoll(nptr, endptr, base); }

unsigned long long int __isoc23_strtoull(const char *nptr, char **endptr, int base)
{ return nm_strtoull(nptr, endptr, base); }

long long int __isoc23_strtoll_l(const char *nptr, char **endptr, int base, locale_t loc)
{ return nm_strtoll_l(nptr, endptr, base, loc); }

unsigned long long int __isoc23_strtoull_l(const char *nptr, char **endptr, int base, locale_t loc)
{ return nm_strtoull_l(nptr, endptr, base, loc); }

extern int nm_vsscanf(const char *, const char *, va_list) __asm__("vsscanf");
extern int nm_vfscanf(FILE *, const char *, va_list) __asm__("vfscanf");
extern int nm_vscanf(const char *, va_list) __asm__("vscanf");

int __isoc23_vsscanf(const char *s, const char *fmt, va_list ap)
{ return nm_vsscanf(s, fmt, ap); }

int __isoc23_vfscanf(FILE *fp, const char *fmt, va_list ap)
{ return nm_vfscanf(fp, fmt, ap); }

int __isoc23_vscanf(const char *fmt, va_list ap)
{ return nm_vscanf(fmt, ap); }

int __isoc23_sscanf(const char *s, const char *fmt, ...)
{
    va_list ap;
    int r;
    va_start(ap, fmt);
    r = nm_vsscanf(s, fmt, ap);
    va_end(ap);
    return r;
}

int __isoc23_fscanf(FILE *fp, const char *fmt, ...)
{
    va_list ap;
    int r;
    va_start(ap, fmt);
    r = nm_vfscanf(fp, fmt, ap);
    va_end(ap);
    return r;
}

int __isoc23_scanf(const char *fmt, ...)
{
    va_list ap;
    int r;
    va_start(ap, fmt);
    r = nm_vscanf(fmt, ap);
    va_end(ap);
    return r;
}

/* ------------------------------------------------------------------ */
/* BSD string                                                          */
/* ------------------------------------------------------------------ */

size_t strlcpy(char *dst, const char *src, size_t size)
{
    size_t srclen = strlen(src);
    if (size != 0) {
        size_t n = srclen < size - 1 ? srclen : size - 1;
        memcpy(dst, src, n);
        dst[n] = '\0';
    }
    return srclen;
}

size_t strlcat(char *dst, const char *src, size_t size)
{
    size_t dstlen = strnlen(dst, size);
    size_t srclen = strlen(src);
    if (dstlen == size)
        return size + srclen;
    {
        size_t room = size - dstlen - 1;
        size_t n = srclen < room ? srclen : room;
        memcpy(dst + dstlen, src, n);
        dst[dstlen + n] = '\0';
    }
    return dstlen + srclen;
}

/* ------------------------------------------------------------------ */
/* randomness                                                          */
/* ------------------------------------------------------------------ */

static void nm_rand_fallback(unsigned char *p, size_t n)
{
    static int seeded = 0;
    size_t i;
    if (!seeded) {
        srand((unsigned int)(time(NULL) ^ (long)getpid()));
        seeded = 1;
    }
    for (i = 0; i < n; i++)
        p[i] = (unsigned char)(rand() & 0xFF);
}

void arc4random_buf(void *buf, size_t n)
{
    unsigned char *p = (unsigned char *)buf;
    size_t off = 0;
    int fd = open("/dev/urandom", O_RDONLY);

    if (fd >= 0) {
        while (off < n) {
            ssize_t r = read(fd, p + off, n - off);
            if (r > 0) {
                off += (size_t)r;
            } else if (r < 0 && errno == EINTR) {
                continue;
            } else {
                break;
            }
        }
        close(fd);
    }
    if (off < n)
        nm_rand_fallback(p + off, n - off);
}

unsigned int arc4random(void)
{
    unsigned int v;
    arc4random_buf(&v, sizeof v);
    return v;
}

/* ------------------------------------------------------------------ */
/* unwinder — _dl_find_object                                          */
/*                                                                      */
/* Reimplemented over dl_iterate_phdr: for a given PC, walk every       */
/* loaded object's program headers, find the PT_LOAD span that PC       */
/* falls inside, and report that object's PT_GNU_EH_FRAME segment       */
/* address. This is exactly what libgcc's own unwinder did before       */
/* glibc 2.35 grew _dl_find_object as a faster, lock-free alternative.  */
/*                                                                      */
/* dl_iterate_phdr and the ELF program-header constants are declared    */
/* locally rather than via <link.h>/<elf.h>, so nothing here depends    */
/* on _GNU_SOURCE / __USE_GNU visibility gating (forbidden in this      */
/* file — see the file header).                                        */
/*                                                                      */
/* The struct layout matches glibc's real <bits/dl_find_object.h> ABI   */
/* on x86_64 (DLFO_STRUCT_HAS_EH_DBASE == 0, DLFO_STRUCT_HAS_EH_COUNT   */
/* == 0), verified against glibc 2.36 headers (debian:12,               */
/* /usr/include/x86_64-linux-gnu/bits/dl_find_object.h and              */
/* /usr/include/dlfcn.h). This is the ABI the prebuilt libgcc_eh.a /     */
/* libstdc++.a were compiled to call into, so the layout is load-        */
/* bearing, not cosmetic.                                               */
/* ------------------------------------------------------------------ */

struct dl_find_object
{
    unsigned long long int dlfo_flags;
    void *dlfo_map_start;
    void *dlfo_map_end;
    void *dlfo_link_map;       /* struct link_map *; never dereferenced here */
    void *dlfo_eh_frame;
    unsigned long long int __dlfo_reserved[7];
};

struct nm_dl_phdr_info
{
    unsigned long int dlpi_addr;
    const char *dlpi_name;
    const void *dlpi_phdr;     /* const ElfW(Phdr) *, cast below */
    unsigned short int dlpi_phnum;
    unsigned long long int dlpi_adds;
    unsigned long long int dlpi_subs;
    size_t dlpi_tls_modid;
    void *dlpi_tls_data;
};

extern int dl_iterate_phdr(
    int (*callback)(struct nm_dl_phdr_info *info, size_t size, void *data),
    void *data);

/* Minimal Elf64_Phdr, matching <elf.h> exactly (no feature-macro gating
 * there, but we avoid the dependency entirely to keep this file
 * self-contained and immune to header drift). */
struct nm_elf64_phdr
{
    unsigned int p_type;
    unsigned int p_flags;
    unsigned long int p_offset;
    unsigned long int p_vaddr;
    unsigned long int p_paddr;
    unsigned long int p_filesz;
    unsigned long int p_memsz;
    unsigned long int p_align;
};

#define NM_PT_LOAD          1
#define NM_PT_GNU_EH_FRAME  0x6474e550

struct nm_dlfo_search
{
    const unsigned char *pc;
    int found;
    void *map_start;
    void *map_end;
    void *eh_frame;
};

static int nm_phdr_callback(struct nm_dl_phdr_info *info, size_t size, void *data)
{
    struct nm_dlfo_search *s = (struct nm_dlfo_search *)data;
    const struct nm_elf64_phdr *phdr = (const struct nm_elf64_phdr *)info->dlpi_phdr;
    const unsigned char *base = (const unsigned char *)info->dlpi_addr;
    void *seg_lo = NULL, *seg_hi = NULL, *eh_frame = NULL;
    int in_range = 0;
    unsigned short i;

    (void)size;

    for (i = 0; i < info->dlpi_phnum; i++) {
        const struct nm_elf64_phdr *ph = &phdr[i];
        if (ph->p_type == NM_PT_LOAD) {
            void *lo = (void *)(base + ph->p_vaddr);
            void *hi = (void *)(base + ph->p_vaddr + ph->p_memsz);
            if (s->pc >= (const unsigned char *)lo && s->pc < (const unsigned char *)hi)
                in_range = 1;
            if (seg_lo == NULL || lo < seg_lo)
                seg_lo = lo;
            if (seg_hi == NULL || hi > seg_hi)
                seg_hi = hi;
        } else if (ph->p_type == NM_PT_GNU_EH_FRAME) {
            eh_frame = (void *)(base + ph->p_vaddr);
        }
    }

    if (in_range) {
        s->found = 1;
        s->map_start = seg_lo;
        s->map_end = seg_hi;
        s->eh_frame = eh_frame;
        return 1; /* stop iterating */
    }
    return 0;
}

int _dl_find_object(void *address, struct dl_find_object *result)
{
    struct nm_dlfo_search s;
    int i;

    memset(&s, 0, sizeof s);
    s.pc = (const unsigned char *)address;

    dl_iterate_phdr(nm_phdr_callback, &s);

    if (!s.found)
        return -1;

    result->dlfo_flags = 0;
    result->dlfo_map_start = s.map_start;
    result->dlfo_map_end = s.map_end;
    result->dlfo_link_map = NULL;
    result->dlfo_eh_frame = s.eh_frame;
    for (i = 0; i < 7; i++)
        result->__dlfo_reserved[i] = 0;
    return 0;
}

/* ------------------------------------------------------------------ */
/* libmvec — scalar loops over a vector_size(16) double pair            */
/* ------------------------------------------------------------------ */

typedef double nm_v2df __attribute__((vector_size(16)));

nm_v2df _ZGVbN2v_log2(nm_v2df x)
{
    nm_v2df r;
    r[0] = log2(x[0]);
    r[1] = log2(x[1]);
    return r;
}

nm_v2df _ZGVbN2vv_atan2(nm_v2df y, nm_v2df x)
{
    nm_v2df r;
    r[0] = atan2(y[0], x[0]);
    r[1] = atan2(y[1], x[1]);
    return r;
}

/* ------------------------------------------------------------------ */
/* pidfd                                                                */
/*                                                                      */
/* Not atomic the way glibc's real pidfd_spawnp is — between spawn and  */
/* pidfd_open the child could exit and its pid be reused. Documented    */
/* and accepted as unverified in the research doc (§8); correct enough  */
/* for glib's gspawn (librsvg's path), which is the only consumer.      */
/* ------------------------------------------------------------------ */

extern int posix_spawnp(pid_t *pid, const char *file,
                         const posix_spawn_file_actions_t *file_actions,
                         const posix_spawnattr_t *attrp,
                         char *const argv[], char *const envp[]);

int pidfd_spawnp(int *pidfd, const char *file,
                  const posix_spawn_file_actions_t *file_actions,
                  const posix_spawnattr_t *attrp,
                  char *const argv[], char *const envp[])
{
    pid_t pid;
    int rc = posix_spawnp(&pid, file, file_actions, attrp, argv, envp);
    long fd;

    if (rc != 0)
        return rc;

    fd = syscall(SYS_pidfd_open, pid, 0);
    if (fd < 0)
        return errno;

    *pidfd = (int)fd;
    return 0;
}

pid_t pidfd_getpid(int pidfd)
{
    char path[64];
    char buf[512];
    int fd;
    ssize_t n;
    char *p;

    snprintf(path, sizeof path, "/proc/self/fdinfo/%d", pidfd);
    fd = open(path, O_RDONLY);
    if (fd < 0) {
        errno = EBADF;
        return (pid_t)-1;
    }

    n = 0;
    {
        ssize_t got;
        while (n < (ssize_t)sizeof(buf) - 1 &&
               (got = read(fd, buf + n, sizeof(buf) - 1 - (size_t)n)) > 0)
            n += got;
    }
    close(fd);
    buf[n < 0 ? 0 : n] = '\0';

    p = strstr(buf, "Pid:");
    if (p == NULL) {
        errno = ESRCH;
        return (pid_t)-1;
    }
    p += 4;
    while (*p == '\t' || *p == ' ')
        p++;
    return (pid_t)nm_strtol(p, NULL, 10);
}

/* ------------------------------------------------------------------ */
/* versioned forwards                                                  */
/*                                                                      */
/* The one place .symver earns its keep: a single unversioned           */
/* definition here becomes the strongest symbol in the final link and  */
/* captures every reference to hypot/hypotf/fmod/fmodf regardless of   */
/* which glibc version a prebuilt archive asked for, while internally   */
/* forwarding to the always-present GLIBC_2.2.5 implementation.         */
/* ------------------------------------------------------------------ */

__asm__(".symver __nm_hypot_old, hypot@GLIBC_2.2.5");
extern double __nm_hypot_old(double, double);
double hypot(double x, double y) { return __nm_hypot_old(x, y); }

__asm__(".symver __nm_hypotf_old, hypotf@GLIBC_2.2.5");
extern float __nm_hypotf_old(float, float);
float hypotf(float x, float y) { return __nm_hypotf_old(x, y); }

__asm__(".symver __nm_fmod_old, fmod@GLIBC_2.2.5");
extern double __nm_fmod_old(double, double);
double fmod(double x, double y) { return __nm_fmod_old(x, y); }

__asm__(".symver __nm_fmodf_old, fmodf@GLIBC_2.2.5");
extern float __nm_fmodf_old(float, float);
float fmodf(float x, float y) { return __nm_fmodf_old(x, y); }
