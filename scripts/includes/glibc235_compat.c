/*
 * glibc 2.35 link compatibility for the Linux x86_64 hardware build.
 *
 * The hardware build compiles and links against a glibc 2.35 sysroot (Ubuntu
 * 22.04, /opt/glibc235) so its executables start on any host with glibc 2.35
 * or newer. Our own code and every dependency are compiled against those
 * headers and never name a newer symbol. The toolchain's prebuilt static
 * runtimes do: gcc 13's libstdc++.a (eh_alloc.o, debug.o, random.o) and
 * libgomp.a were compiled on Ubuntu 24.04 against glibc 2.39 headers, which
 * redirect strtol/strtoul/strtoull to their C23 variants __isoc23_* (new in
 * glibc 2.38) and use arc4random (new in glibc 2.36). None of those names
 * exist in libc.so.6 2.35, so without this object every C++ or OpenMP link
 * against the sysroot fails with undefined references.
 *
 * This object is appended to the sysroot's libc_nonshared.a, the archive glibc
 * itself links into every program through the libc.so linker script. Each link
 * then resolves the four names statically from here, and nothing changes at
 * run time: a program that runs on glibc 2.38+ simply carries its own copy.
 *
 * Semantics are glibc's. __isoc23_strto* are strto* plus the C23 "0b"/"0B"
 * prefix for base 0 and 2. arc4random is getrandom(2), which glibc has had
 * since 2.25 and which, like glibc's own arc4random, cannot fail once the
 * kernel pool is initialised; a failure is aborted rather than returned.
 *
 * Compile this file with the sysroot (gcc --sysroot=/opt/glibc235): compiled
 * against 2.38+ headers the strto* calls below would themselves become
 * __isoc23_* calls and the functions would recurse.
 */
#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/random.h>
#include <sys/types.h>

#if defined(__GLIBC__) && (__GLIBC__ > 2 || __GLIBC_MINOR__ >= 38)
#error "compile glibc235_compat.c against the glibc 2.35 sysroot, not the host headers"
#endif

long __isoc23_strtol(const char *s, char **end, int base);
long long __isoc23_strtoll(const char *s, char **end, int base);
unsigned long __isoc23_strtoul(const char *s, char **end, int base);
unsigned long long __isoc23_strtoull(const char *s, char **end, int base);
uint32_t arc4random(void);
void arc4random_buf(void *buf, size_t n);
uint32_t arc4random_uniform(uint32_t upper_bound);

/* C23 lets base 0 and base 2 take a "0b"/"0B" prefix, which glibc < 2.38
 * does not know. Returns 1 when s, after whitespace and an optional sign,
 * starts with that prefix followed by a binary digit; *digits then points at
 * the first digit and *negative says whether a '-' preceded the prefix. */
static int binary_prefix(const char *s, int base, const char **digits, int *negative)
{
    const char *p = s;

    if (base != 0 && base != 2)
        return 0;
    while (isspace((unsigned char)*p))
        p++;
    *negative = 0;
    if (*p == '+' || *p == '-') {
        *negative = (*p == '-');
        p++;
    }
    if (p[0] == '0' && (p[1] == 'b' || p[1] == 'B') && (p[2] == '0' || p[2] == '1')) {
        *digits = p + 2;
        return 1;
    }
    return 0;
}

long __isoc23_strtol(const char *s, char **end, int base)
{
    const char *digits;
    int negative;
    unsigned long magnitude;

    if (!binary_prefix(s, base, &digits, &negative))
        return strtol(s, end, base);
    magnitude = strtoul(digits, end, 2);
    if (negative) {
        if (magnitude > (unsigned long)LONG_MAX + 1UL) {
            errno = ERANGE;
            return LONG_MIN;
        }
        return (long)(0UL - magnitude);
    }
    if (magnitude > (unsigned long)LONG_MAX) {
        errno = ERANGE;
        return LONG_MAX;
    }
    return (long)magnitude;
}

long long __isoc23_strtoll(const char *s, char **end, int base)
{
    const char *digits;
    int negative;
    unsigned long long magnitude;

    if (!binary_prefix(s, base, &digits, &negative))
        return strtoll(s, end, base);
    magnitude = strtoull(digits, end, 2);
    if (negative) {
        if (magnitude > (unsigned long long)LLONG_MAX + 1ULL) {
            errno = ERANGE;
            return LLONG_MIN;
        }
        return (long long)(0ULL - magnitude);
    }
    if (magnitude > (unsigned long long)LLONG_MAX) {
        errno = ERANGE;
        return LLONG_MAX;
    }
    return (long long)magnitude;
}

unsigned long __isoc23_strtoul(const char *s, char **end, int base)
{
    const char *digits;
    int negative;
    unsigned long magnitude;

    if (!binary_prefix(s, base, &digits, &negative))
        return strtoul(s, end, base);
    errno = 0;
    magnitude = strtoul(digits, end, 2);
    if (negative && errno != ERANGE)
        return 0UL - magnitude;
    return magnitude;
}

unsigned long long __isoc23_strtoull(const char *s, char **end, int base)
{
    const char *digits;
    int negative;
    unsigned long long magnitude;

    if (!binary_prefix(s, base, &digits, &negative))
        return strtoull(s, end, base);
    errno = 0;
    magnitude = strtoull(digits, end, 2);
    if (negative && errno != ERANGE)
        return 0ULL - magnitude;
    return magnitude;
}

void arc4random_buf(void *buf, size_t n)
{
    unsigned char *p = buf;

    while (n > 0) {
        ssize_t got = getrandom(p, n, 0);

        if (got < 0) {
            if (errno == EINTR)
                continue;
            abort();
        }
        p += got;
        n -= (size_t)got;
    }
}

uint32_t arc4random(void)
{
    uint32_t value;

    arc4random_buf(&value, sizeof value);
    return value;
}

uint32_t arc4random_uniform(uint32_t upper_bound)
{
    uint32_t minimum, value;

    if (upper_bound < 2)
        return 0;
    /* Reject the low values that would bias r % upper_bound, as glibc does. */
    minimum = (uint32_t)(-upper_bound) % upper_bound;
    do {
        value = arc4random();
    } while (value < minimum);
    return value % upper_bound;
}
